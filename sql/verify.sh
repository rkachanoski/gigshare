#!/usr/bin/env bash
# ============================================================================
# GigShare — Sprint 1 verification harness
# Loads the schema + seed, runs the analytics queries, and checks that every
# integrity rule REJECTS an offending insert. Prints a captured, reproducible
# log; the committed output lives in docs/sprint-1-verification.md.
#
# Usage:  sql/verify.sh            (defaults to: mysql -u root)
#         MYSQL="mysql -u me -p"   sql/verify.sh
# ============================================================================
set -uo pipefail

MYSQL="${MYSQL:-mysql -u root}"
DB=gigshare
HERE="$(cd "$(dirname "$0")" && pwd)"

hr() { printf '=%.0s' {1..76}; echo; }
section() { echo; hr; echo "# $1"; hr; }

echo "GigShare Sprint 1 verification — $(date '+%Y-%m-%d %H:%M:%S %Z')"
$MYSQL -e "SELECT VERSION() AS mysql_version;" 2>/dev/null

section "1. Load schema + seed"
$MYSQL < "$HERE/schema.sql"      && echo "schema.sql loaded OK"
$MYSQL "$DB" < "$HERE/seed.sql"  && echo "seed.sql loaded OK"

section "2. Row counts after seed"
$MYSQL "$DB" -t -e "
  SELECT 'musician' AS table_name, COUNT(*) AS n_rows FROM musician
  UNION ALL SELECT 'party', COUNT(*) FROM party
  UNION ALL SELECT 'act', COUNT(*) FROM act
  UNION ALL SELECT 'promoter', COUNT(*) FROM promoter
  UNION ALL SELECT 'venue', COUNT(*) FROM venue
  UNION ALL SELECT 'gig', COUNT(*) FROM gig
  UNION ALL SELECT 'member_of', COUNT(*) FROM member_of
  UNION ALL SELECT 'earnings_report', COUNT(*) FROM earnings_report;"

section "3. Q1 — benchmark: avg payout per head by venue capacity band"
$MYSQL "$DB" -t -e "
  SELECT CASE WHEN v.capacity<150 THEN 'small (<150)'
              WHEN v.capacity<=400 THEN 'mid (150-400)'
              ELSE 'large (>400)' END AS capacity_band,
         COUNT(*) AS n_reports,
         ROUND(AVG(r.net_payout/r.attendance),2) AS avg_payout_per_head,
         ROUND(AVG(r.net_payout),2) AS avg_net_payout
  FROM earnings_report r
  JOIN gig g ON g.gig_id=r.gig_id
  JOIN venue v ON v.venue_id=g.venue_id
  WHERE r.reporter_role IN ('headliner','support')
    AND r.attendance>0 AND r.net_payout IS NOT NULL
  GROUP BY capacity_band ORDER BY MIN(v.capacity);"

section "4. Q2 — reconciliation: reports for one gig that disagree on attendance"
$MYSQL "$DB" -t -e "
  SELECT g.gig_id, v.venue_name, g.gig_date,
         p1.party_name AS party_a, r1.attendance AS att_a,
         p2.party_name AS party_b, r2.attendance AS att_b,
         ABS(r1.attendance-r2.attendance) AS gap
  FROM earnings_report r1
  JOIN earnings_report r2
        ON r2.gig_id=r1.gig_id AND r1.report_id<r2.report_id
       AND r1.attendance<>r2.attendance
  JOIN party p1 ON p1.party_id=r1.party_id
  JOIN party p2 ON p2.party_id=r2.party_id
  JOIN gig g ON g.gig_id=r1.gig_id
  JOIN venue v ON v.venue_id=g.venue_id
  ORDER BY gap DESC;"

section "5. Q5 — multi-party shows (>1 reporting party)"
$MYSQL "$DB" -t -e "
  SELECT g.gig_id, v.venue_name, g.gig_date, COUNT(*) AS n_reports,
         GROUP_CONCAT(p.party_name ORDER BY p.party_name SEPARATOR ', ') AS reporting_parties
  FROM earnings_report r
  JOIN party p ON p.party_id=r.party_id
  JOIN gig g ON g.gig_id=r.gig_id
  JOIN venue v ON v.venue_id=g.venue_id
  GROUP BY g.gig_id, v.venue_name, g.gig_date
  HAVING COUNT(*)>1 ORDER BY n_reports DESC, g.gig_date;"

section "6. Constraint checks — each offending insert MUST be rejected"
pass=0; fail=0
expect_fail() { # <label> <sql>
  local label="$1" sql="$2" err
  err="$($MYSQL "$DB" -e "$sql" 2>&1)"
  if [[ $? -ne 0 ]]; then
    printf 'PASS  %-34s rejected: %s\n' "$label" "$(echo "$err" | head -1)"
    pass=$((pass+1))
  else
    printf 'FAIL  %-34s was ACCEPTED (should have been rejected)\n' "$label"
    fail=$((fail+1))
  fi
}
expect_fail "UNIQUE(party_id,gig_id)" \
  "INSERT INTO earnings_report (party_id,gig_id,reporter_role,net_payout) VALUES (1,1,'headliner',999);"
expect_fail "UNIQUE(venue_id,gig_date)" \
  "INSERT INTO gig (venue_id,gig_date,door_price) VALUES (1,'2026-06-14',10);"
expect_fail "FK FiledBy (party must exist)" \
  "INSERT INTO earnings_report (party_id,gig_id,reporter_role) VALUES (999,1,'support');"
expect_fail "trigger: role<->party kind" \
  "INSERT INTO earnings_report (party_id,gig_id,reporter_role) VALUES (5,4,'headliner');"

section "Result"
echo "constraint checks: $pass passed, $fail failed"
[[ $fail -eq 0 ]] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }

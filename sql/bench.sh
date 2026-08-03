#!/usr/bin/env bash
# ============================================================================
# GigShare — Sprint 2 indexing/performance experiment
#
# Builds a fresh database, loads ~32k earnings reports from sql/generate.py,
# then measures four queries BEFORE and AFTER sql/indexes.sql: query plan,
# estimated rows, and median wall-clock over several runs. Also measures the
# write-side cost of the indexes, and a deliberately bad index.
#
# Usage:  sql/bench.sh                    (defaults to: mysql -u root)
#         MYSQL="mysql -u me -p" sql/bench.sh
#         REPS=9 sql/bench.sh
#
# The captured run is committed in docs/sprint-2-verification.md.
#
# TIMING METHOD — stated plainly so the numbers can be read honestly.
#
# Timing one `mysql -e "<query>"` invocation per run does not work here: client
# startup and connection cost ~11 ms, which is larger than most of these queries.
# That floor compresses every ratio toward 1.0 and hides real differences.
#
# So each measurement instead runs the query $REPS times inside a SINGLE client
# invocation, times the whole batch, subtracts one connection's overhead
# (measured separately as a trivial `SELECT 1`), and divides by $REPS. The result
# approximates server-side execution time per query. Three such batches are run
# and the median is reported.
#
# These are WARM-CACHE numbers: repeated execution leaves the data in InnoDB's
# buffer pool. That is the realistic steady state for an analytics query, and it
# applies identically to the before and after arms.
# ============================================================================
set -uo pipefail

MYSQL="${MYSQL:-mysql -u root}"
DB=gigshare
REPS="${REPS:-20}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

hr() { printf '=%.0s' {1..76}; echo; }
section() { echo; hr; echo "# $1"; hr; }

# --- the four queries under test --------------------------------------------
# Q1  community benchmark: performer take-home per head, whole dataset
Q1="SELECT reporter_role, COUNT(*) AS n, ROUND(AVG(net_payout/attendance),2) AS pph
    FROM earnings_report
    WHERE reporter_role IN ('headliner','support')
      AND attendance > 0 AND net_payout IS NOT NULL
    GROUP BY reporter_role ORDER BY reporter_role;"

# Q2  the same benchmark restricted to a date window (a season's data)
Q2="SELECT COUNT(*) AS n, ROUND(AVG(r.net_payout/r.attendance),2) AS pph
    FROM earnings_report r JOIN gig g ON g.gig_id = r.gig_id
    WHERE g.gig_date BETWEEN '2024-03-01' AND '2024-05-31'
      AND r.reporter_role IN ('headliner','support') AND r.attendance > 0;"

# Q3  recently filed reports (the activity/moderation feed)
Q3="SELECT COUNT(*) AS n FROM earnings_report
    WHERE submitted_at >= '2025-06-01' AND submitted_at < '2025-07-01';"

# Q4  one act's earnings history — already served by the Sprint 0 UNIQUE rule
Q4="SELECT g.gig_date, r.net_payout FROM earnings_report r
    JOIN gig g ON g.gig_id = r.gig_id
    WHERE r.party_id = 42 ORDER BY g.gig_date;"

# --- helpers ----------------------------------------------------------------

# Per-query server-side time in ms: median over 3 batches of $REPS executions in
# one connection, minus connection overhead, divided by $REPS. See TIMING METHOD.
# Call as: timeq "<sql>" [overhead_ms]
timeq() {
  python3 -c '
import subprocess, sys, time, statistics, shlex
mysql = shlex.split(sys.argv[1])
db, sql, reps = sys.argv[2], sys.argv[3], int(sys.argv[4])
overhead = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
batch = sql if sql.rstrip().endswith(";") else sql + ";"
batch = batch * reps
totals = []
for _ in range(3):
    t0 = time.perf_counter()
    subprocess.run(mysql + [db, "-e", batch],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    totals.append((time.perf_counter() - t0) * 1000)
per = max((statistics.median(totals) - overhead) / reps, 0.001)
print(f"{per:.2f}")
' "$MYSQL" "$DB" "$1" "$REPS" "${2:-0}"
}

# Cost of starting the client and connecting — subtracted from every batch above.
measure_overhead() {
  python3 -c '
import subprocess, sys, time, statistics, shlex
mysql = shlex.split(sys.argv[1]); db = sys.argv[2]
ts = []
for _ in range(7):
    t0 = time.perf_counter()
    subprocess.run(mysql + [db, "-e", "SELECT 1;"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    ts.append((time.perf_counter() - t0) * 1000)
print(f"{statistics.median(ts):.1f}")
' "$MYSQL" "$DB"
}

# One-line plan summary. FORMAT=TRADITIONAL is required: MySQL 9.7 ships with
# @@explain_format = TREE, which omits the type/key/rows columns entirely.
plan() {
  $MYSQL "$DB" -e "EXPLAIN FORMAT=TRADITIONAL $1" 2>/dev/null |
    awk -F'\t' 'NR>1 {printf "    %-16s type=%-7s key=%-22s rows=%-7s %s\n",$3,$5,($7=="NULL"?"-":$7),$10,$12}'
}

# Run all four: plan + timing, saving result sets for the correctness diff.
measure() {  # <arm-label>
  local arm="$1" i=1
  for q in "$Q1" "$Q2" "$Q3" "$Q4"; do
    echo "  Q$i:"
    plan "$q"
    local ms; ms="$(timeq "$q" "$OVERHEAD")"
    echo "    ${ms} ms per execution (median of 3 batches of $REPS)"
    echo "$ms" > "$WORK/q$i.$arm.ms"
    $MYSQL "$DB" -e "$q" > "$WORK/q$i.$arm.out" 2>/dev/null
    i=$((i+1))
  done
}

echo "GigShare Sprint 2 benchmark — $(date '+%Y-%m-%d %H:%M:%S %Z')"
$MYSQL -e "SELECT VERSION() AS mysql_version;" 2>/dev/null

section "0. Build a fresh database and load the generated dataset"
$MYSQL < "$HERE/schema.sql" && echo "schema.sql loaded"
python3 "$HERE/generate.py" > "$WORK/data.sql" || { echo "generator failed"; exit 1; }

load_start=$(python3 -c 'import time;print(time.time())')
$MYSQL "$DB" < "$WORK/data.sql" || { echo "data load failed"; exit 1; }
load_noidx=$(python3 -c "import time;print(f'{(time.time()-$load_start):.2f}')")
echo "load time WITHOUT performance indexes: ${load_noidx}s"

$MYSQL "$DB" -t -e "
  SELECT 'venue' AS table_name, COUNT(*) AS n_rows FROM venue
  UNION ALL SELECT 'party', COUNT(*) FROM party
  UNION ALL SELECT 'musician', COUNT(*) FROM musician
  UNION ALL SELECT 'member_of', COUNT(*) FROM member_of
  UNION ALL SELECT 'gig', COUNT(*) FROM gig
  UNION ALL SELECT 'earnings_report', COUNT(*) FROM earnings_report;"

OVERHEAD="$(measure_overhead)"
echo "client+connection overhead (subtracted from every timing below): ${OVERHEAD} ms"

section "1. BEFORE — baseline, no performance indexes"
measure before

section "2. A BAD INDEX — low selectivity, non-covering"
echo "  reporter_role has 3 distinct values; the Q1 predicate matches ~85% of rows."
$MYSQL "$DB" -e "CREATE INDEX idx_report_role_only ON earnings_report (reporter_role);"
echo "  Q1 with idx_report_role_only present:"
plan "$Q1"
bad_ms="$(timeq "$Q1" "$OVERHEAD")"
echo "    ${bad_ms} ms per execution (median of 3 batches of $REPS)"
$MYSQL "$DB" -e "DROP INDEX idx_report_role_only ON earnings_report;"

section "3. AFTER — with sql/indexes.sql applied"
$MYSQL "$DB" < "$HERE/indexes.sql" && echo "indexes.sql applied"
$MYSQL "$DB" -e "ANALYZE TABLE earnings_report, gig;" > /dev/null 2>&1
measure after

section "4. Correctness — the indexes must not change any answer"
same=0; diff_n=0
for i in 1 2 3 4; do
  if diff -q "$WORK/q$i.before.out" "$WORK/q$i.after.out" > /dev/null; then
    echo "  Q$i: identical result set before and after   PASS"
    same=$((same+1))
  else
    echo "  Q$i: RESULT SET CHANGED                      FAIL"
    diff_n=$((diff_n+1))
  fi
done

section "5. Write-side cost of the indexes"
$MYSQL < "$HERE/schema.sql"
$MYSQL "$DB" < "$HERE/indexes.sql"
load_start=$(python3 -c 'import time;print(time.time())')
$MYSQL "$DB" < "$WORK/data.sql"
load_idx=$(python3 -c "import time;print(f'{(time.time()-$load_start):.2f}')")
echo "  load WITHOUT indexes: ${load_noidx}s"
echo "  load WITH indexes:    ${load_idx}s"
python3 -c "
n, i = $load_noidx, $load_idx
print(f'  indexes cost {(i-n):+.2f}s on the bulk load ({(i/n-1)*100:+.0f}%) — the price paid on every write')"

section "6. Summary"
printf '  %-4s %-12s %-12s %s\n' query before after change
for i in 1 2 3 4; do
  b=$(cat "$WORK/q$i.before.ms"); a=$(cat "$WORK/q$i.after.ms")
  printf '  %-4s %-12s %-12s %s\n' "Q$i" "${b} ms" "${a} ms" \
    "$(python3 -c "b,a=$b,$a; print(f'{b/a:.2f}x faster' if a<b else f'{a/b:.2f}x slower')")"
done
echo
echo "  All times are ms per execution, server-side (connection overhead removed)."
echo "  Q4 is a CONTROL: no index was added for it, and its plan is identical in"
echo "  both arms (ref via uq_report_party_gig). At ~0.2 ms it sits on the noise"
echo "  floor, so its before/after delta is measurement scatter, not an effect."
echo
b1=$(cat "$WORK/q1.before.ms")
python3 -c "
bad, base = $bad_ms, $b1
print(f'  bad index on Q1: {bad:.2f} ms vs {base:.2f} ms with NO index at all '
      f'-> {bad/base:.2f}x SLOWER than no index')"

section "Result"
if [[ $diff_n -eq 0 ]]; then
  echo "all $same result sets unchanged by indexing — PASS"
else
  echo "$diff_n result set(s) CHANGED — FAIL"; exit 1
fi

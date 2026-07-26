# Sprint 1 — Verification Log

Captured evidence that the Sprint 1 schema loads, the analytics queries return sensible
results, and every integrity rule **rejects** an offending insert. This is the "stands up to
independent testing" evidence for the rubric.

- **Reproduce it:** `sql/verify.sh` (defaults to `mysql -u root`; override with
  `MYSQL="mysql -u me -p" sql/verify.sh`). It exits non-zero if any check fails.
- **Environment:** MySQL 9.7.1 (Homebrew, macOS). Captured 2026-07-26.
- **Related:** the schema/queries themselves are in [`sql/`](../sql/); the design write-up is
  [`sprint-1.md`](sprint-1.md).

---

## Full run output

```text
GigShare Sprint 1 verification — 2026-07-26 16:07:37 PDT
mysql_version
9.7.1

============================================================================
# 1. Load schema + seed
============================================================================
schema.sql loaded OK
seed.sql loaded OK

============================================================================
# 2. Row counts after seed
============================================================================
+-----------------+--------+
| table_name      | n_rows |
+-----------------+--------+
| musician        |      5 |
| party           |      6 |
| act             |      4 |
| promoter        |      2 |
| venue           |      6 |
| gig             |      6 |
| member_of       |      8 |
| earnings_report |     10 |
+-----------------+--------+

============================================================================
# 3. Q1 — benchmark: avg payout per head by venue capacity band
============================================================================
+---------------+-----------+---------------------+----------------+
| capacity_band | n_reports | avg_payout_per_head | avg_net_payout |
+---------------+-----------+---------------------+----------------+
| small (<150)  |         2 |               15.14 |        1330.00 |
| mid (150-400) |         4 |               12.24 |        1964.25 |
| large (>400)  |         1 |               20.00 |       12000.00 |
+---------------+-----------+---------------------+----------------+

============================================================================
# 4. Q2 — reconciliation: reports for one gig that disagree on attendance
============================================================================
+--------+-------------+------------+-----------------+-------+-----------------+-------+------+
| gig_id | venue_name  | gig_date   | party_a         | att_a | party_b         | att_b | gap  |
+--------+-------------+------------+-----------------+-------+-----------------+-------+------+
|      1 | The Coda    | 2026-06-14 | The Ferry Wakes |   105 | Tidal Presents  |   118 |   13 |
|      1 | The Coda    | 2026-06-14 | Neon Salmon     |   110 | Tidal Presents  |   118 |    8 |
|      1 | The Coda    | 2026-06-14 | Neon Salmon     |   110 | The Ferry Wakes |   105 |    5 |
|      5 | The Phoenix | 2026-07-11 | DJ Kelp         |   180 | Sam the Booker  |   175 |    5 |
+--------+-------------+------------+-----------------+-------+-----------------+-------+------+

============================================================================
# 5. Q5 — multi-party shows (>1 reporting party)
============================================================================
+--------+------------------+------------+-----------+----------------------------------------------+
| gig_id | venue_name       | gig_date   | n_reports | reporting_parties                            |
+--------+------------------+------------+-----------+----------------------------------------------+
|      1 | The Coda         | 2026-06-14 |         3 | Neon Salmon, The Ferry Wakes, Tidal Presents |
|      3 | Capital Ballroom | 2026-07-05 |         2 | Neon Salmon, Tidal Presents                  |
|      5 | The Phoenix      | 2026-07-11 |         2 | DJ Kelp, Sam the Booker                      |
+--------+------------------+------------+-----------+----------------------------------------------+

============================================================================
# 6. Constraint checks — each offending insert MUST be rejected
============================================================================
PASS  UNIQUE(party_id,gig_id)            rejected: ERROR 1062 (23000) at line 1: Duplicate entry '1-1' for key 'earnings_report.uq_report_party_gig'
PASS  UNIQUE(venue_id,gig_date)          rejected: ERROR 1062 (23000) at line 1: Duplicate entry '1-2026-06-14' for key 'gig.uq_gig_venue_date'
PASS  FK FiledBy (party must exist)      rejected: ERROR 1452 (23000) at line 1: Cannot add or update a child row: a foreign key constraint fails (`gigshare`.`earnings_report`, CONSTRAINT `fk_report_party` FOREIGN KEY (`party_id`) REFERENCES `party` (`party_id`) ON DELETE CASCADE ON UPDATE CASCADE)
PASS  trigger: role<->party kind         rejected: ERROR 1644 (45000) at line 1: reporter_role must match party kind: promoter<->promoter, headliner/support<->act

============================================================================
# Result
============================================================================
constraint checks: 4 passed, 0 failed
ALL CHECKS PASSED
```

---

## What the results show

- **Load + counts (§1–2):** schema and seed apply cleanly; 10 earnings reports across 6 gigs
  and 6 parties (4 acts + 2 promoters), matching the seed.
- **Q1 benchmark (§3):** payout-per-head is computed per capacity band from performer
  (`headliner`/`support`) reports only — the number a musician actually takes home per head.
- **Q2 reconciliation (§4):** the four surfaced disagreements are all on the two multi-party
  gigs. At **The Coda** the opener (105), headliner (110), and promoter (118) each counted a
  different door — flagged, never overwritten.
- **Q5 multi-party (§5):** confirms three gigs carry more than one party's report, i.e. the
  multi-party model works end to end.
- **Constraint checks (§6):** all four offending inserts are rejected — the two `UNIQUE`
  rules, the mandatory `FiledBy` foreign key, and the role↔party-kind trigger.

### Success criteria — met
- [x] Running MySQL instance; all tables created, keyed, and seeded.
- [x] Foreign keys and both `UNIQUE` constraints verified (offending inserts rejected).
- [x] Benchmark and reconciliation queries return sensible results over the seed.

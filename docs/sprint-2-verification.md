# Sprint 2 — Verification Log (captured run)

**CSC 370 · Databases · Summer 2026 · University of Victoria**

Captured output of the two Sprint 2 harnesses against a live **MySQL 9.7.1**
instance (Homebrew, macOS 15.5, Apple silicon). Both are re-runnable and both
exit non-zero on failure — nothing quoted in [`sprint-2.md`](sprint-2.md) is
estimated or hand-copied.

```bash
sql/verify.sh    # schema, seed, analytics, constraints, normalization, scale
sql/bench.sh     # indexing experiment: plans + timings, before and after
```

**Headline results**

| Check | Result |
|---|---|
| Constraint checks (small seed) | 4 / 4 rejected as designed |
| Constraint checks (~32k generated reports) | 4 / 4 rejected as designed |
| Normalization: claimed FDs not refuted by data | 4 / 4 PASS |
| Normalization: decomposition lossless | PASS — 0 spurious, 0 missing tuples |
| Normalization: lossy control detected | PASS — 30 spurious tuples caught |
| Indexing: result sets unchanged | 4 / 4 identical before/after |
| `verify.sh` exit code | 0 |
| `bench.sh` exit code | 0 |

---

## 1. `sql/verify.sh`

```
GigShare verification (Sprints 1-2) — 2026-08-02 18:27:57 PDT
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
# 7. Normalization checks (Sprint 2)
============================================================================
+---------------------------------------------------------+
| section                                                 |
+---------------------------------------------------------+
| === Test 0: claimed FDs are not refuted by the data === |
+---------------------------------------------------------+
+--------------------------------------------------------+----------+-------------------------+--------------------+
| fd_tested                                              | n_groups | max_distinct_dependents | verdict            |
+--------------------------------------------------------+----------+-------------------------+--------------------+
| f5: venue_id -> venue_name, city, capacity, venue_type |        6 |                       1 | PASS (not refuted) |
| f4: gig_id -> gig_date, door_price, venue_id           |        6 |                       1 | PASS (not refuted) |
| f3: party_id -> party_name, party_kind                 |        6 |                       1 | PASS (not refuted) |
| (party_id, gig_id) is a candidate key                  |       10 |                       1 | PASS (key holds)   |
+--------------------------------------------------------+----------+-------------------------+--------------------+
+-------------------------------------------------------------------+
| section                                                           |
+-------------------------------------------------------------------+
| === Test 1: update anomaly (rows touched to rename one venue) === |
+-------------------------------------------------------------------+
+---------------------+-------------------------------+-------------------------------------+---------------------+
| venue_name          | rows_to_update_in_wide_design | rows_to_update_in_normalized_design | write_amplification |
+---------------------+-------------------------------+-------------------------------------+---------------------+
| The Coda            |                             3 |                                   1 | 3x                  |
| Capital Ballroom    |                             2 |                                   1 | 2x                  |
| The Phoenix         |                             2 |                                   1 | 2x                  |
| Lucky Bar           |                             1 |                                   1 | 1x                  |
| The Little Fernwood |                             1 |                                   1 | 1x                  |
| Wheelies            |                             1 |                                   1 | 1x                  |
+---------------------+-------------------------------+-------------------------------------+---------------------+
+---------------------------------------------------------------+
| section                                                       |
+---------------------------------------------------------------+
| === Test 2: decomposition of report_wide must be lossless === |
+---------------------------------------------------------------+
+---------------------------------------------------+------------+------------+-------------------+------------------+-----------------+
| decomposition                                     | n_original | n_rejoined | n_spurious_tuples | n_missing_tuples | verdict         |
+---------------------------------------------------+------------+------------+-------------------+------------------+-----------------+
| 1NF wide table -> venue/gig/party/earnings_report |         10 |         10 |                 0 |                0 | PASS (lossless) |
+---------------------------------------------------+------------+------------+-------------------+------------------+-----------------+
+-------------------------------------------------------------------------+
| section                                                                 |
+-------------------------------------------------------------------------+
| === Test 3 (control): a bad decomposition must be detected as lossy === |
+-------------------------------------------------------------------------+
+------------------------------------------------------+------------+------------+-------------------+---------------------------------------+
| decomposition                                        | n_original | n_rejoined | n_spurious_tuples | verdict                               |
+------------------------------------------------------+------------+------------+-------------------+---------------------------------------+
| split (venue_name, city, capacity) on non-key `city` |          6 |         36 |                30 | PASS (lossy split correctly detected) |
+------------------------------------------------------+------------+------------+-------------------+---------------------------------------+
+-------------------------------------------------+
| section                                         |
+-------------------------------------------------+
| === Test 3: sample of the fabricated tuples === |
+-------------------------------------------------+
+------------------+----------+---------------------+
| venue_name       | city     | fabricated_capacity |
+------------------+----------+---------------------+
| Capital Ballroom | Victoria |                  90 |
| Capital Ballroom | Victoria |                 120 |
| Capital Ballroom | Victoria |                 150 |
| Capital Ballroom | Victoria |                 200 |
| Capital Ballroom | Victoria |                 250 |
| Lucky Bar        | Victoria |                  90 |
| Lucky Bar        | Victoria |                 120 |
| Lucky Bar        | Victoria |                 150 |
+------------------+----------+---------------------+

PASS  normalization: no FAIL verdicts

============================================================================
# 8. Constraints still hold at scale (~32k generated reports)
============================================================================
generated dataset loaded
+-----------------+--------+
| table_name      | n_rows |
+-----------------+--------+
| gig             |  20000 |
| earnings_report |  31926 |
+-----------------+--------+
colliding against: report (1,113)  gig (1,2023-01-04)  promoter 801

PASS  UNIQUE(party_id,gig_id) @scale     rejected: ERROR 1062 (23000) at line 1: Duplicate entry '1-113' for key 'earnings_report.uq_report_party_gig'
PASS  UNIQUE(venue_id,gig_date) @scale   rejected: ERROR 1062 (23000) at line 1: Duplicate entry '1-2023-01-04' for key 'gig.uq_gig_venue_date'
PASS  FK FiledBy @scale                  rejected: ERROR 1452 (23000) at line 1: Cannot add or update a child row: a foreign key constraint fails (`gigshare`.`earnings_report`, CONSTRAINT `fk_report_party` FOREIGN KEY (`party_id`) REFERENCES `party` (`party_id`) ON DELETE CASCADE ON UPDATE CASCADE)
PASS  trigger: role<->kind @scale        rejected: ERROR 1644 (45000) at line 1: reporter_role must match party kind: promoter<->promoter, headliner/support<->act

database restored to the small seed

============================================================================
# Result
============================================================================
checks: 8 passed, 0 failed
ALL CHECKS PASSED
```

---

## 2. `sql/bench.sh`

```
GigShare Sprint 2 benchmark — 2026-08-02 18:26:21 PDT
mysql_version
9.7.1

============================================================================
# 0. Build a fresh database and load the generated dataset
============================================================================
schema.sql loaded
generated: 220 venues, 1500 musicians, 800 acts, 120 promoters, 2296 memberships, 20000 gigs, 31926 earnings reports
load time WITHOUT performance indexes: 0.82s
+-----------------+--------+
| table_name      | n_rows |
+-----------------+--------+
| venue           |    220 |
| party           |    920 |
| musician        |   1500 |
| member_of       |   2296 |
| gig             |  20000 |
| earnings_report |  31926 |
+-----------------+--------+
client+connection overhead (subtracted from every timing below): 11.1 ms

============================================================================
# 1. BEFORE — baseline, no performance indexes
============================================================================
  Q1:
    earnings_report  type=ALL     key=-                      rows=31926   Using where; Using temporary; Using filesort
    17.11 ms per execution (median of 3 batches of 20)
  Q2:
    r                type=ALL     key=-                      rows=31926   Using where
    g                type=eq_ref  key=PRIMARY                rows=1       Using where
    22.05 ms per execution (median of 3 batches of 20)
  Q3:
    earnings_report  type=ALL     key=-                      rows=31926   Using where
    3.76 ms per execution (median of 3 batches of 20)
  Q4:
    r                type=ref     key=uq_report_party_gig    rows=22      Using temporary; Using filesort
    g                type=eq_ref  key=PRIMARY                rows=1       NULL
    0.14 ms per execution (median of 3 batches of 20)

============================================================================
# 2. A BAD INDEX — low selectivity, non-covering
============================================================================
  reporter_role has 3 distinct values; the Q1 predicate matches ~85% of rows.
  Q1 with idx_report_role_only present:
    earnings_report  type=index   key=idx_report_role_only   rows=31926   Using where
    25.31 ms per execution (median of 3 batches of 20)

============================================================================
# 3. AFTER — with sql/indexes.sql applied
============================================================================
indexes.sql applied
  Q1:
    earnings_report  type=range   key=idx_report_bench       rows=28636   Using where; Using index
    10.54 ms per execution (median of 3 batches of 20)
  Q2:
    g                type=range   key=idx_gig_date           rows=1654    Using where; Using index
    r                type=ref     key=fk_report_gig          rows=1       Using where
    3.71 ms per execution (median of 3 batches of 20)
  Q3:
    earnings_report  type=range   key=idx_report_submitted   rows=882     Using where; Using index
    0.15 ms per execution (median of 3 batches of 20)
  Q4:
    r                type=ref     key=uq_report_party_gig    rows=22      Using temporary; Using filesort
    g                type=eq_ref  key=PRIMARY                rows=1       NULL
    0.17 ms per execution (median of 3 batches of 20)

============================================================================
# 4. Correctness — the indexes must not change any answer
============================================================================
  Q1: identical result set before and after   PASS
  Q2: identical result set before and after   PASS
  Q3: identical result set before and after   PASS
  Q4: identical result set before and after   PASS

============================================================================
# 5. Write-side cost of the indexes
============================================================================
  load WITHOUT indexes: 0.82s
  load WITH indexes:    0.90s
  indexes cost +0.08s on the bulk load (+10%) — the price paid on every write

============================================================================
# 6. Summary
============================================================================
  query before       after        change
  Q1   17.11 ms     10.54 ms     1.62x faster
  Q2   22.05 ms     3.71 ms      5.94x faster
  Q3   3.76 ms      0.15 ms      25.07x faster
  Q4   0.14 ms      0.17 ms      1.21x slower

  All times are ms per execution, server-side (connection overhead removed).
  Q4 is a CONTROL: no index was added for it, and its plan is identical in
  both arms (ref via uq_report_party_gig). At ~0.2 ms it sits on the noise
  floor, so its before/after delta is measurement scatter, not an effect.

  bad index on Q1: 25.31 ms vs 17.11 ms with NO index at all -> 1.48x SLOWER than no index

============================================================================
# Result
============================================================================
all 4 result sets unchanged by indexing — PASS
```

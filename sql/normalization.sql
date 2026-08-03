-- ============================================================================
-- GigShare — Sprint 2: normalization analysis, checked against real data
--
-- Run:  mysql -u root gigshare < sql/normalization.sql
--
-- The FD analysis in docs/sprint-2.md §2 finds that all seven shipped relations
-- are already in BCNF. Nothing in the schema needs decomposing. So the
-- decomposition theory is exercised where it actually applies: against the
-- NAIVE design — the single wide "one row per report, with everything on it"
-- table that a designer who skipped the ERD would have built.
--
-- This script:
--   Test 0  tests the FDs claimed for the wide relation against the data
--           (refutation only — see the note at Test 0)
--   Test 1  measures the wide relation's update anomaly
--   Test 2  decomposes it and shows the rejoin reconstructs it exactly
--   Test 3  runs a deliberately BAD decomposition as a control
--
-- Test 3 is what makes Test 2 worth anything. A losslessness check that has only
-- ever been run against a correct decomposition proves nothing — it would pass
-- even if the comparison logic were broken. Showing the same machinery *catch* a
-- lossy split is the evidence that a PASS means something.
--
-- `report_wide` is a scratch table, built here and dropped at the end. It is a
-- counter-example, not part of the schema.
--
-- Every check emits a `verdict` column of PASS/FAIL; sql/verify.sh fails the run
-- if any row reads FAIL.
-- ============================================================================

USE gigshare;

-- ---------------------------------------------------------------------------
-- The naive design: one wide relation, no ERD, everything about a report on the
-- report's own row.
--
--   report_wide(report_id, party_id, party_name, party_kind,
--               gig_id, gig_date, door_price,
--               venue_id, venue_name, city, capacity, venue_type,
--               reporter_role, attendance, net_payout)
--
-- Candidate keys:  report_id  and  (party_id, gig_id)
-- Prime attributes: report_id, party_id, gig_id
--
-- FDs that hold:
--   f1  report_id            -> every other attribute
--   f2  (party_id, gig_id)   -> every other attribute
--   f3  party_id             -> party_name, party_kind
--   f4  gig_id               -> gig_date, door_price, venue_id
--   f5  venue_id             -> venue_name, city, capacity, venue_type
--
-- f3 and f4 determine non-prime attributes from a PROPER SUBSET of the candidate
-- key (party_id, gig_id) -> partial dependencies -> violates 2NF.
-- f5's determinant venue_id is non-prime -> report_id -> venue_id -> venue_name
-- is a transitive dependency -> violates 3NF.
-- So report_wide is in 1NF only.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS report_wide;
CREATE TABLE report_wide AS
SELECT r.report_id,
       p.party_id, p.party_name, p.party_kind,
       g.gig_id, g.gig_date, g.door_price,
       v.venue_id, v.venue_name, v.city, v.capacity, v.venue_type,
       r.reporter_role, r.attendance, r.net_payout
FROM earnings_report r
JOIN party p ON p.party_id = r.party_id
JOIN gig   g ON g.gig_id   = r.gig_id
JOIN venue v ON v.venue_id = g.venue_id;

-- ---------------------------------------------------------------------------
-- TEST 0 — do the claimed FDs survive contact with the data?
--
-- If X -> Y holds, then grouping by X must yield exactly one distinct Y per
-- group. Any group with more than one REFUTES the FD.
--
-- Note the asymmetry, which the verdict wording reflects: data can refute a
-- functional dependency but can never establish one. Finding no counterexample
-- in 10 rows (or 10 million) only means none was found. An FD is a constraint
-- asserted about the domain, not a pattern discovered in a sample. So a PASS
-- here reads "not refuted", not "proved".
-- ---------------------------------------------------------------------------
SELECT '=== Test 0: claimed FDs are not refuted by the data ===' AS section;

SELECT 'f5: venue_id -> venue_name, city, capacity, venue_type' AS fd_tested,
       COUNT(*)                                                 AS n_groups,
       MAX(worst)                                               AS max_distinct_dependents,
       CASE WHEN MAX(worst) = 1 THEN 'PASS (not refuted)'
            ELSE 'FAIL (refuted by data)' END                AS verdict
FROM (SELECT GREATEST(COUNT(DISTINCT venue_name), COUNT(DISTINCT city),
                      COUNT(DISTINCT capacity),   COUNT(DISTINCT venue_type)) AS worst
      FROM report_wide GROUP BY venue_id) t
UNION ALL
SELECT 'f4: gig_id -> gig_date, door_price, venue_id',
       COUNT(*), MAX(worst),
       CASE WHEN MAX(worst) = 1 THEN 'PASS (not refuted)'
            ELSE 'FAIL (refuted by data)' END
FROM (SELECT GREATEST(COUNT(DISTINCT gig_date), COUNT(DISTINCT door_price),
                      COUNT(DISTINCT venue_id)) AS worst
      FROM report_wide GROUP BY gig_id) t
UNION ALL
SELECT 'f3: party_id -> party_name, party_kind',
       COUNT(*), MAX(worst),
       CASE WHEN MAX(worst) = 1 THEN 'PASS (not refuted)'
            ELSE 'FAIL (refuted by data)' END
FROM (SELECT GREATEST(COUNT(DISTINCT party_name), COUNT(DISTINCT party_kind)) AS worst
      FROM report_wide GROUP BY party_id) t
UNION ALL
-- The candidate key claim: (party_id, gig_id) must be unique across the relation.
SELECT '(party_id, gig_id) is a candidate key',
       COUNT(*), MAX(n),
       CASE WHEN MAX(n) = 1 THEN 'PASS (key holds)'
            ELSE 'FAIL (duplicate key values)' END
FROM (SELECT COUNT(*) AS n FROM report_wide GROUP BY party_id, gig_id) t;

-- ---------------------------------------------------------------------------
-- TEST 1 — the update anomaly the violations cause.
--
-- Because f5 puts venue_name on every report row, renaming one venue means
-- rewriting one row per report at that venue, and any missed row silently
-- forks the venue into two. In the normalized schema it is one UPDATE of one
-- row, always.
-- ---------------------------------------------------------------------------
SELECT '=== Test 1: update anomaly (rows touched to rename one venue) ===' AS section;

SELECT v.venue_name,
       COUNT(*) AS rows_to_update_in_wide_design,
       1        AS rows_to_update_in_normalized_design,
       CONCAT(COUNT(*), 'x') AS write_amplification
FROM report_wide rw
JOIN venue v ON v.venue_id = rw.venue_id
GROUP BY rw.venue_id, v.venue_name
ORDER BY COUNT(*) DESC, v.venue_name;

-- ---------------------------------------------------------------------------
-- TEST 2 — decompose report_wide, then rejoin and compare.
--
-- Removing the violating FDs one at a time:
--   f5 out -> venue(venue_id, venue_name, city, capacity, venue_type)
--   f4 out -> gig(gig_id, venue_id, gig_date, door_price)
--   f3 out -> party(party_id, party_name, party_kind)
--   residue -> earnings_report(report_id, party_id, gig_id,
--                              reporter_role, attendance, net_payout)
--
-- Each split shares exactly the key of the fragment it peels off (venue_id,
-- gig_id, party_id respectively), so each step satisfies the lossless-join
-- condition and the chain as a whole is lossless.
--
-- Note where this lands: the decomposition reproduces the shipped schema
-- attribute for attribute. Normalizing the naive design arrives at the design
-- the ERD already produced in Sprint 1 — which is the actual finding of this
-- sprint, and the reason nothing in the schema needed to change.
-- ---------------------------------------------------------------------------
SELECT '=== Test 2: decomposition of report_wide must be lossless ===' AS section;

WITH d_venue AS (
  SELECT DISTINCT venue_id, venue_name, city, capacity, venue_type FROM report_wide
),
d_gig AS (
  SELECT DISTINCT gig_id, venue_id, gig_date, door_price FROM report_wide
),
d_party AS (
  SELECT DISTINCT party_id, party_name, party_kind FROM report_wide
),
d_report AS (
  SELECT report_id, party_id, gig_id, reporter_role, attendance, net_payout FROM report_wide
),
rejoined AS (
  SELECT dr.report_id,
         dp.party_id, dp.party_name, dp.party_kind,
         dg.gig_id, dg.gig_date, dg.door_price,
         dv.venue_id, dv.venue_name, dv.city, dv.capacity, dv.venue_type,
         dr.reporter_role, dr.attendance, dr.net_payout
  FROM d_report dr
  JOIN d_party dp ON dp.party_id = dr.party_id
  JOIN d_gig   dg ON dg.gig_id   = dr.gig_id
  JOIN d_venue dv ON dv.venue_id = dg.venue_id
),
spurious AS (SELECT * FROM rejoined    EXCEPT SELECT * FROM report_wide),
missing  AS (SELECT * FROM report_wide EXCEPT SELECT * FROM rejoined),
-- Each of `spurious`/`missing` is collapsed to a count here and referenced ONCE.
-- Referencing a CTE that contains a set operation from several scalar subqueries
-- in one SELECT gives inconsistent results on MySQL 9.7 (the count reads 0 while
-- `count = 0` reads false), so the verdict is computed over these columns instead.
counts AS (
  SELECT (SELECT COUNT(*) FROM report_wide) AS n_original,
         (SELECT COUNT(*) FROM rejoined)    AS n_rejoined,
         (SELECT COUNT(*) FROM spurious)    AS n_spurious,
         (SELECT COUNT(*) FROM missing)     AS n_missing
)
SELECT '1NF wide table -> venue/gig/party/earnings_report' AS decomposition,
       n_original, n_rejoined,
       n_spurious AS n_spurious_tuples,
       n_missing  AS n_missing_tuples,
       CASE WHEN n_spurious = 0 AND n_missing = 0 AND n_rejoined = n_original
            THEN 'PASS (lossless)' ELSE 'FAIL (lossy)' END AS verdict
FROM counts;

-- ---------------------------------------------------------------------------
-- TEST 3 (control) — a BAD decomposition must be caught.
--
-- Take S(venue_name, city, capacity) and split it on `city`:
--     S1 = (venue_name, city)      S2 = (city, capacity)
-- S1 ∩ S2 = city, which is a key of NEITHER fragment. The lossless-join
-- condition fails, so rejoining should fabricate tuples — every venue in a city
-- paired with every capacity in that city.
--
-- The expected outcome here is a LOSSY decomposition. `verdict` reads PASS when
-- the check correctly detects that.
-- ---------------------------------------------------------------------------
SELECT '=== Test 3 (control): a bad decomposition must be detected as lossy ===' AS section;

WITH s  AS (SELECT DISTINCT venue_name, city, capacity FROM report_wide),
     s1 AS (SELECT DISTINCT venue_name, city FROM s),
     s2 AS (SELECT DISTINCT city, capacity    FROM s),
     rejoined AS (SELECT s1.venue_name, s1.city, s2.capacity
                  FROM s1 JOIN s2 ON s2.city = s1.city),
     spurious AS (SELECT * FROM rejoined EXCEPT SELECT * FROM s),
     counts   AS (SELECT (SELECT COUNT(*) FROM s)        AS n_original,
                         (SELECT COUNT(*) FROM rejoined) AS n_rejoined,
                         (SELECT COUNT(*) FROM spurious) AS n_spurious)
SELECT 'split (venue_name, city, capacity) on non-key `city`' AS decomposition,
       n_original, n_rejoined,
       n_spurious AS n_spurious_tuples,
       CASE WHEN n_spurious > 0
            THEN 'PASS (lossy split correctly detected)'
            ELSE 'FAIL (check is blind - it missed a lossy split)' END AS verdict
FROM counts;

-- Make "spurious tuple" concrete: venue/capacity pairings that never existed.
SELECT '=== Test 3: sample of the fabricated tuples ===' AS section;

WITH s  AS (SELECT DISTINCT venue_name, city, capacity FROM report_wide),
     s1 AS (SELECT DISTINCT venue_name, city FROM s),
     s2 AS (SELECT DISTINCT city, capacity    FROM s)
SELECT s1.venue_name, s1.city, s2.capacity AS fabricated_capacity
FROM s1 JOIN s2 ON s2.city = s1.city
WHERE (s1.venue_name, s2.capacity) NOT IN (SELECT venue_name, capacity FROM s)
ORDER BY s1.venue_name, s2.capacity
LIMIT 8;

DROP TABLE report_wide;

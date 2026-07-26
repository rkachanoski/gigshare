-- ============================================================================
-- GigShare — Sprint 1 queries (MySQL 8.0)
-- Run after schema.sql + seed.sql:  mysql -u root -p gigshare < sql/queries.sql
--
-- Each analytical query is paired with its relational-algebra expression in
-- docs/sprint-1.md (§4). Queries Q1 (benchmark) and Q2 (reconciliation) are the
-- two required by the sprint plan; Q3-Q5 support the app's read features.
-- ============================================================================

USE gigshare;

-- ---------------------------------------------------------------------------
-- Q1 — BENCHMARK: average net payout per attendee, by venue capacity band.
-- The headline analytics query: "which size of room actually pays per head?"
-- Only ACT reports (headliner/support) count toward payout-per-head; promoter
-- reports describe the promoter's own margin, not a performer's take-home.
-- ---------------------------------------------------------------------------
SELECT
    CASE
        WHEN v.capacity < 150            THEN 'small (<150)'
        WHEN v.capacity <= 400           THEN 'mid (150-400)'
        ELSE                                  'large (>400)'
    END                                                    AS capacity_band,
    COUNT(*)                                               AS n_reports,
    ROUND(AVG(r.net_payout / r.attendance), 2)             AS avg_payout_per_head,
    ROUND(AVG(r.net_payout), 2)                            AS avg_net_payout
FROM earnings_report r
JOIN gig   g ON g.gig_id   = r.gig_id
JOIN venue v ON v.venue_id = g.venue_id
WHERE r.reporter_role IN ('headliner', 'support')   -- performer take-home only
  AND r.attendance IS NOT NULL
  AND r.attendance > 0
  AND r.net_payout IS NOT NULL
GROUP BY capacity_band
ORDER BY MIN(v.capacity);

-- ---------------------------------------------------------------------------
-- Q2 — RECONCILIATION: gigs where two parties' reports DISAGREE on attendance.
-- Surfaces conflicts to flag (never overwrite). Self-join earnings_report to
-- itself on the same gig; r1.report_id < r2.report_id avoids duplicate/mirror
-- pairs and self-matches.
-- ---------------------------------------------------------------------------
SELECT
    g.gig_id,
    v.venue_name,
    g.gig_date,
    p1.party_name              AS party_a,
    r1.attendance              AS attendance_a,
    p2.party_name              AS party_b,
    r2.attendance              AS attendance_b,
    ABS(r1.attendance - r2.attendance) AS attendance_gap
FROM earnings_report r1
JOIN earnings_report r2
      ON r2.gig_id = r1.gig_id
     AND r1.report_id < r2.report_id
     AND r1.attendance <> r2.attendance
JOIN party p1 ON p1.party_id = r1.party_id
JOIN party p2 ON p2.party_id = r2.party_id
JOIN gig   g  ON g.gig_id    = r1.gig_id
JOIN venue v  ON v.venue_id  = g.venue_id
ORDER BY attendance_gap DESC;

-- ---------------------------------------------------------------------------
-- Q3 — An act's own earnings history across gigs and venues.
-- (Parameterised in the app; here filtered to 'Neon Salmon'.)
-- ---------------------------------------------------------------------------
SELECT
    p.party_name,
    g.gig_date,
    v.venue_name,
    v.city,
    r.reporter_role,
    r.attendance,
    r.net_payout
FROM earnings_report r
JOIN party p ON p.party_id = r.party_id
JOIN gig   g ON g.gig_id   = r.gig_id
JOIN venue v ON v.venue_id = g.venue_id
WHERE p.party_name = 'Neon Salmon'
ORDER BY g.gig_date;

-- ---------------------------------------------------------------------------
-- Q4 — Current roster of an act (active members only), via the association table.
-- ---------------------------------------------------------------------------
SELECT
    p.party_name,
    m.display_name,
    mo.role,
    m.primary_instrument
FROM member_of mo
JOIN musician m ON m.musician_id = mo.musician_id
JOIN party    p ON p.party_id    = mo.party_id
WHERE p.party_name = 'Neon Salmon'
  AND mo.is_active = TRUE
ORDER BY m.display_name;

-- ---------------------------------------------------------------------------
-- Q5 — Multi-party shows: gigs with more than one reporting party.
-- ---------------------------------------------------------------------------
SELECT
    g.gig_id,
    v.venue_name,
    g.gig_date,
    COUNT(*)                                          AS n_reports,
    GROUP_CONCAT(p.party_name ORDER BY p.party_name SEPARATOR ', ') AS reporting_parties
FROM earnings_report r
JOIN party p ON p.party_id = r.party_id
JOIN gig   g ON g.gig_id   = r.gig_id
JOIN venue v ON v.venue_id = g.venue_id
GROUP BY g.gig_id, v.venue_name, g.gig_date
HAVING COUNT(*) > 1
ORDER BY n_reports DESC, g.gig_date;

-- ============================================================================
-- CONSTRAINT DEMOS — each of these SHOULD FAIL, proving the rules hold.
-- Run individually; they are commented out so the script completes cleanly.
-- ============================================================================

-- (a) One report per party per gig -> UNIQUE(party_id, gig_id) rejects a second
--     report from Neon Salmon (party 1) for gig 1 (which it already reported).
-- INSERT INTO earnings_report (party_id, gig_id, reporter_role, net_payout)
--   VALUES (1, 1, 'headliner', 999.00);
--   -> ERROR 1062 (23000): Duplicate entry '1-1' for key 'uq_report_party_gig'

-- (b) Gig dedup -> UNIQUE(venue_id, gig_date) rejects a second gig at the same
--     venue on the same date (The Coda already has a gig on 2026-06-14).
-- INSERT INTO gig (venue_id, gig_date, door_price) VALUES (1, '2026-06-14', 10.00);
--   -> ERROR 1062 (23000): Duplicate entry '1-2026-06-14' for key 'uq_gig_venue_date'

-- (c) FiledBy is mandatory -> a report must reference an existing party.
-- INSERT INTO earnings_report (party_id, gig_id, reporter_role) VALUES (999, 1, 'support');
--   -> ERROR 1452 (23000): foreign key constraint fails (fk_report_party)

-- (d) role<->kind rule (trigger) -> a promoter (party 5) cannot file a 'headliner' report.
-- INSERT INTO earnings_report (party_id, gig_id, reporter_role) VALUES (5, 4, 'headliner');
--   -> ERROR 1644 (45000): reporter_role must match party kind ...

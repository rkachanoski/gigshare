-- ============================================================================
-- GigShare — synthetic seed data (MySQL 8.0)
-- Run after schema.sql:  mysql -u root -p gigshare < sql/seed.sql
--
-- Venues are real Victoria, BC rooms; all capacities and financials are
-- SYNTHETIC placeholders (easy to swap later). The data is shaped to exercise
-- the Sprint 1 goals:
--   * A gig reported by MULTIPLE parties (headliner + opener + promoter), with
--     numbers that deliberately DISAGREE -> exercises the reconciliation query.
--   * A DIY gig with NO promoter (the act reports venue-side figures itself).
--   * Venues across three capacity bands -> exercises the benchmark query.
-- IDs are explicit so the foreign keys are easy to follow.
-- ============================================================================

USE gigshare;

-- ---- Venues (bands: small <150, mid 150-400, large >400; capacities synthetic) ----
INSERT INTO venue (venue_id, venue_name, city, capacity, venue_type) VALUES
  (1, 'The Coda',           'Victoria', 150, 'bar'),      -- mid (boundary)
  (2, 'Lucky Bar',          'Victoria', 250, 'club'),     -- mid
  (3, 'Wheelies',           'Victoria',  90, 'bar'),      -- small
  (4, 'The Little Fernwood','Victoria', 120, 'hall'),     -- small
  (5, 'Capital Ballroom',   'Victoria', 650, 'hall'),     -- large
  (6, 'The Phoenix',        'Victoria', 200, 'bar');      -- mid

-- ---- Parties (supertype rows) + subtype rows -------------------------------
INSERT INTO party (party_id, party_name, contact_info, party_kind) VALUES
  (1, 'Neon Salmon',    'neon@example.com',   'act'),
  (2, 'The Ferry Wakes','ferry@example.com',  'act'),
  (3, 'DJ Kelp',        'kelp@example.com',   'act'),
  (4, 'Static Harbour', 'static@example.com', 'act'),
  (5, 'Tidal Presents', 'book@tidal.example', 'promoter'),
  (6, 'Sam the Booker', 'sam@example.com',    'promoter');

INSERT INTO act (party_id, genre, act_type) VALUES
  (1, 'indie rock', 'band'),
  (2, 'folk',       'band'),
  (3, 'electronic', 'solo'),
  (4, 'post-punk',  'band');

INSERT INTO promoter (party_id, is_company) VALUES
  (5, TRUE),   -- a company
  (6, FALSE);  -- an individual booker

-- ---- Musicians -------------------------------------------------------------
INSERT INTO musician (musician_id, display_name, email, primary_instrument, home_city) VALUES
  (1, 'Reg K.',      'r.kachanoski@gmail.com', 'guitar', 'Victoria'),
  (2, 'Ada Cormier', 'ada@example.com',        'bass',   'Victoria'),
  (3, 'Theo Nunn',   'theo@example.com',       'drums',  'Victoria'),
  (4, 'Priya Rao',   'priya@example.com',      'vocals', 'Victoria'),
  (5, 'Marco Vidal', 'marco@example.com',      'synths', 'Nanaimo');

-- ---- MemberOf (a musician can be in several acts) --------------------------
INSERT INTO member_of (musician_id, party_id, role, is_active) VALUES
  (1, 1, 'guitar/vocals', TRUE),   -- Reg in Neon Salmon
  (2, 1, 'bass',          TRUE),   -- Ada in Neon Salmon
  (3, 1, 'drums',         TRUE),   -- Theo in Neon Salmon
  (1, 2, 'guitar',        TRUE),   -- Reg also in The Ferry Wakes (multi-act)
  (4, 2, 'vocals',        TRUE),   -- Priya in The Ferry Wakes
  (5, 3, 'everything',    TRUE),   -- Marco is DJ Kelp (solo)
  (2, 4, 'bass',          TRUE),   -- Ada also in Static Harbour
  (3, 4, 'drums',         FALSE);  -- Theo, inactive in Static Harbour

-- ---- Gigs (deduplicated by venue+date) -------------------------------------
INSERT INTO gig (gig_id, venue_id, gig_date, door_price) VALUES
  (1, 1, '2026-06-14', 15.00),  -- The Coda (mid)        -- multi-party show
  (2, 3, '2026-06-20', 20.00),  -- Wheelies (small)      -- DIY, no promoter
  (3, 5, '2026-07-05', 35.00),  -- Capital Ballroom (large)
  (4, 4, '2026-06-28', 12.00),  -- The Little Fernwood (small)
  (5, 6, '2026-07-11', 18.00),  -- The Phoenix (mid)
  (6, 2, '2026-07-18', 22.00);  -- Lucky Bar (mid)

-- ============================================================================
-- Earnings reports
-- ============================================================================

-- Gig 1 @ The Coda — reported by THREE parties. Note the disagreements:
--   attendance: headliner 110, opener 105, promoter 118 (they don't match)
--   venue_fee : the opener doesn't know it (NULL); headliner & promoter do.
INSERT INTO earnings_report
  (report_id, party_id, gig_id, reporter_role, agreed_guarantee, door_split_pct,
   door_revenue, merch_sales, venue_fee, technician_fees, additional_expenses,
   attendance, net_payout, currency) VALUES
  (1, 1, 1, 'headliner', 300.00, 70.00, 1650.00, 220.00, 250.00, 120.00,  40.00, 110, 1160.00, 'CAD'),
  (2, 2, 1, 'support',   150.00, 30.00,  707.00,  90.00,  NULL,   NULL,    NULL, 105,  797.00, 'CAD'),
  (3, 5, 1, 'promoter',    NULL,  NULL, 1770.00,   NULL, 250.00, 120.00, 300.00, 118,  650.00, 'CAD');

-- Gig 2 @ Wheelies — DIY, no promoter. The act reports venue-side figures itself.
INSERT INTO earnings_report
  (report_id, party_id, gig_id, reporter_role, agreed_guarantee, door_split_pct,
   door_revenue, merch_sales, venue_fee, technician_fees, additional_expenses,
   attendance, net_payout, currency) VALUES
  (4, 3, 2, 'headliner', 0.00, 100.00, 1600.00, 250.00, 200.00, 100.00, 80.00, 80, 1470.00, 'CAD');

-- Gig 3 @ Capital Ballroom (large) — headliner + promoter, numbers agree here.
INSERT INTO earnings_report
  (report_id, party_id, gig_id, reporter_role, agreed_guarantee, door_split_pct,
   door_revenue, merch_sales, venue_fee, technician_fees, additional_expenses,
   attendance, net_payout, currency) VALUES
  (5, 1, 3, 'headliner', 1200.00, 60.00, 21000.00, 900.00, 2000.00, 800.00, 500.00, 600, 12000.00, 'CAD'),
  (6, 5, 3, 'promoter',      NULL,  NULL, 21000.00,   NULL, 2000.00, 800.00, 1500.00, 600,  4800.00, 'CAD');

-- Gig 4 @ The Little Fernwood (small) — single act, self-reported.
INSERT INTO earnings_report
  (report_id, party_id, gig_id, reporter_role, agreed_guarantee, door_split_pct,
   door_revenue, merch_sales, venue_fee, technician_fees, additional_expenses,
   attendance, net_payout, currency) VALUES
  (7, 4, 4, 'headliner', 200.00, 80.00, 1200.00, 60.00, 150.00, 80.00, 40.00, 100, 1190.00, 'CAD');

-- Gig 5 @ The Phoenix (mid) — headliner + individual promoter (attendance differs).
INSERT INTO earnings_report
  (report_id, party_id, gig_id, reporter_role, agreed_guarantee, door_split_pct,
   door_revenue, merch_sales, venue_fee, technician_fees, additional_expenses,
   attendance, net_payout, currency) VALUES
  (8, 3, 5, 'headliner', 400.00, 50.00, 3240.00, 300.00, 400.00, 150.00, 100.00, 180, 2390.00, 'CAD'),
  (9, 6, 5, 'promoter',     NULL,  NULL, 3240.00,   NULL, 400.00, 150.00, 500.00, 175, 1620.00, 'CAD');

-- Gig 6 @ Lucky Bar (mid) — single act, self-reported.
INSERT INTO earnings_report
  (report_id, party_id, gig_id, reporter_role, agreed_guarantee, door_split_pct,
   door_revenue, merch_sales, venue_fee, technician_fees, additional_expenses,
   attendance, net_payout, currency) VALUES
  (10, 2, 6, 'headliner', 350.00, 65.00, 4400.00, 180.00, 450.00, 160.00, 120.00, 200, 3510.00, 'CAD');

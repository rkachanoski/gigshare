-- ============================================================================
-- GigShare — Sprint 2: performance indexes
--
-- Run:  mysql -u root gigshare < sql/indexes.sql
-- Measured by sql/bench.sh; results in docs/sprint-2.md §4.
--
-- These are deliberately NOT in schema.sql. schema.sql declares only what the
-- logical design requires (primary keys, the uniqueness business rules, and the
-- indexes InnoDB creates on its own to support foreign keys). Keeping tuning
-- separate means the before/after experiment has an honest baseline.
--
-- WHAT IS ALREADY INDEXED BEFORE THIS FILE RUNS — worth knowing, because two
-- indexes that look missing are not:
--   * earnings_report(gig_id)  — InnoDB auto-creates `fk_report_gig` to support
--     the foreign key, so joins and self-joins on gig_id are already served.
--   * earnings_report(party_id) — the leftmost prefix of the UNIQUE constraint
--     uq_report_party_gig(party_id, gig_id). The Sprint 0 business rule "one
--     report per party per gig" therefore pays for the act-history access path
--     for free. No index is added for it here.
-- ============================================================================

USE gigshare;

-- ---------------------------------------------------------------------------
-- 1. Covering index for the community benchmark aggregate.
--
--   SELECT reporter_role, COUNT(*), AVG(net_payout/attendance)
--   FROM earnings_report
--   WHERE reporter_role IN ('headliner','support') AND attendance > 0 ...
--   GROUP BY reporter_role
--
-- Every column the query touches is in the index, so InnoDB never reads the
-- clustered row (EXPLAIN: `Using index`). Leading with reporter_role also means
-- the index is already ordered for the GROUP BY, which removes the temporary
-- table the baseline plan needs.
--
-- Note this index does NOT win by reading fewer rows — 85% of reports are
-- headliner/support, so the estimate barely moves. It wins on access method.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_report_bench
    ON earnings_report (reporter_role, attendance, net_payout, gig_id);

-- ---------------------------------------------------------------------------
-- 2. Date-window queries over gigs.
--
-- gig already has UNIQUE(venue_id, gig_date), but gig_date is not the leftmost
-- column, so a date range with no venue predicate cannot seek into it — the
-- baseline plan is a full scan of that index. A standalone index on gig_date
-- turns it into a range scan.
--
-- (When the same query also joins venue, the optimizer can drive from venue and
-- use the composite as 220 separate range scans. This index matters for the
-- common case where it cannot.)
-- ---------------------------------------------------------------------------
CREATE INDEX idx_gig_date ON gig (gig_date);

-- ---------------------------------------------------------------------------
-- 3. "Recently filed reports" — the moderation/activity feed.
--
-- submitted_at is unindexed at baseline, so any recency window scans the whole
-- table. This is the most selective of the three: a one-month window is roughly
-- 3% of the table.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_report_submitted ON earnings_report (submitted_at);

-- ---------------------------------------------------------------------------
-- NOT ADDED, on purpose — see docs/sprint-2.md §4.3.
--
--   CREATE INDEX idx_report_role_only ON earnings_report (reporter_role);
--
-- reporter_role has three values and the benchmark predicate matches 85% of the
-- table. The optimizer does not ignore this index — it picks it, scans it end to
-- end, and then does a clustered-row lookup per entry because the index does not
-- cover the query. That is measurably worse than the sequential table scan it
-- replaces. bench.sh creates it temporarily to measure exactly that.
-- ---------------------------------------------------------------------------

-- To undo (bench.sh instead reloads from schema.sql, so it never needs these):
--   DROP INDEX idx_report_bench     ON earnings_report;
--   DROP INDEX idx_report_submitted ON earnings_report;
--   DROP INDEX idx_gig_date         ON gig;

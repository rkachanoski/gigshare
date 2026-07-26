-- ============================================================================
-- GigShare — logical schema (MySQL 8.0)
-- Sprint 1: Logical Design & SQL. Maps the Sprint 0 ERD to relational tables.
--
-- Run:  mysql -u root -p < sql/schema.sql
-- Then: mysql -u root -p gigshare < sql/seed.sql
--       mysql -u root -p gigshare < sql/queries.sql
--
-- Mapping summary (see docs/sprint-1.md for the full derivation):
--   * Each entity set -> one table.
--   * isa generalization (Party -> Act / Promoter): one table per subtype, each
--     sharing party_id as PK *and* FK to party (class-table inheritance).
--   * Many-one relationships (HostedAt, FiledBy, Covers) -> FK on the "many" side.
--   * Many-many relationship (MemberOf) -> association table member_of.
--   * (1,1) participation -> NOT NULL FK.  (min,max) rules -> keys/constraints.
-- ============================================================================

DROP DATABASE IF EXISTS gigshare;
CREATE DATABASE gigshare CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE gigshare;

-- ---------------------------------------------------------------------------
-- Musician
-- ---------------------------------------------------------------------------
CREATE TABLE musician (
  musician_id        INT          NOT NULL AUTO_INCREMENT,
  display_name       VARCHAR(120) NOT NULL,
  email              VARCHAR(255) NOT NULL,
  primary_instrument VARCHAR(60),
  home_city          VARCHAR(120),
  PRIMARY KEY (musician_id),
  UNIQUE KEY uq_musician_email (email)          -- email is a candidate key
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- Party (supertype) + disjoint subtype discriminator.
-- party_kind records which subtype a row belongs to (disjoint generalization).
-- ---------------------------------------------------------------------------
CREATE TABLE party (
  party_id     INT          NOT NULL AUTO_INCREMENT,
  party_name   VARCHAR(160) NOT NULL,
  contact_info VARCHAR(255),
  party_kind   ENUM('act','promoter') NOT NULL,
  PRIMARY KEY (party_id)
) ENGINE=InnoDB;

-- Act (subtype of Party). party_id is both PK and FK -> party (shared identifier).
CREATE TABLE act (
  party_id INT NOT NULL,
  genre    VARCHAR(80),
  act_type ENUM('solo','duo','band') NOT NULL DEFAULT 'band',
  PRIMARY KEY (party_id),
  CONSTRAINT fk_act_party FOREIGN KEY (party_id)
    REFERENCES party (party_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- Promoter (subtype of Party). Optional participant in a gig.
CREATE TABLE promoter (
  party_id   INT     NOT NULL,
  is_company BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (party_id),
  CONSTRAINT fk_promoter_party FOREIGN KEY (party_id)
    REFERENCES party (party_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- Venue
-- ---------------------------------------------------------------------------
CREATE TABLE venue (
  venue_id   INT          NOT NULL AUTO_INCREMENT,
  venue_name VARCHAR(160) NOT NULL,
  city       VARCHAR(120) NOT NULL,
  capacity   INT,
  venue_type ENUM('bar','club','theatre','hall','festival','other')
             NOT NULL DEFAULT 'other',
  PRIMARY KEY (venue_id),
  CONSTRAINT chk_venue_capacity CHECK (capacity IS NULL OR capacity > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- Gig  (HostedAt: many gigs -> one venue, so venue_id FK lives here)
--   * venue_id NOT NULL  realizes Gig(1,1) participation in HostedAt.
--   * UNIQUE(venue_id, gig_date) deduplicates gigs so every party's report
--     for one show resolves to the same Gig.
-- ---------------------------------------------------------------------------
CREATE TABLE gig (
  gig_id     INT          NOT NULL AUTO_INCREMENT,
  venue_id   INT          NOT NULL,
  gig_date   DATE         NOT NULL,
  door_price DECIMAL(8,2),
  PRIMARY KEY (gig_id),
  UNIQUE KEY uq_gig_venue_date (venue_id, gig_date),
  CONSTRAINT fk_gig_venue FOREIGN KEY (venue_id)
    REFERENCES venue (venue_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT chk_gig_door_price CHECK (door_price IS NULL OR door_price >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- MemberOf  (Musician many-many Act) -> association table.
--   * References the ACT subtype (only acts have members, not promoters).
--   * PK(musician_id, party_id) enforces one membership per (musician, act).
-- ---------------------------------------------------------------------------
CREATE TABLE member_of (
  musician_id INT     NOT NULL,
  party_id    INT     NOT NULL,               -- an Act's party_id
  role        VARCHAR(80),                     -- attribute of the relationship
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (musician_id, party_id),
  CONSTRAINT fk_member_musician FOREIGN KEY (musician_id)
    REFERENCES musician (musician_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_member_act FOREIGN KEY (party_id)
    REFERENCES act (party_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- EarningsReport  (FiledBy + Covers: many reports -> one party, one gig)
--   * party_id NOT NULL  realizes Report(1,1) in FiledBy.
--   * gig_id   NOT NULL  realizes Report(1,1) in Covers.
--   * UNIQUE(party_id, gig_id) = one report per party per gig.
--   * Financial fields are nullable: each report is one party's partial view.
-- ---------------------------------------------------------------------------
CREATE TABLE earnings_report (
  report_id           INT      NOT NULL AUTO_INCREMENT,
  party_id            INT      NOT NULL,
  gig_id              INT      NOT NULL,
  reporter_role       ENUM('headliner','support','promoter') NOT NULL,
  agreed_guarantee    DECIMAL(10,2),
  door_split_pct      DECIMAL(5,2),
  door_revenue        DECIMAL(10,2),
  merch_sales         DECIMAL(10,2),
  venue_fee           DECIMAL(10,2),
  technician_fees     DECIMAL(10,2),
  additional_expenses DECIMAL(10,2),
  attendance          INT,
  net_payout          DECIMAL(10,2),
  currency            CHAR(3)  NOT NULL DEFAULT 'CAD',
  submitted_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (report_id),
  UNIQUE KEY uq_report_party_gig (party_id, gig_id),
  CONSTRAINT fk_report_party FOREIGN KEY (party_id)
    REFERENCES party (party_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_report_gig FOREIGN KEY (gig_id)
    REFERENCES gig (gig_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT chk_report_split
    CHECK (door_split_pct IS NULL OR (door_split_pct >= 0 AND door_split_pct <= 100)),
  CONSTRAINT chk_report_attendance
    CHECK (attendance IS NULL OR attendance >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- Trigger: enforce reporter_role <-> party kind consistency.
-- (A cross-table rule a single-table CHECK cannot express: a 'promoter' report
--  must be filed by a promoter; 'headliner'/'support' reports by an act.)
-- ---------------------------------------------------------------------------
DELIMITER //
CREATE TRIGGER trg_report_role_matches_kind
BEFORE INSERT ON earnings_report
FOR EACH ROW
BEGIN
  DECLARE k VARCHAR(10);
  SELECT party_kind INTO k FROM party WHERE party_id = NEW.party_id;
  IF (NEW.reporter_role = 'promoter' AND k <> 'promoter')
     OR (NEW.reporter_role IN ('headliner','support') AND k <> 'act') THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT =
        'reporter_role must match party kind: promoter<->promoter, headliner/support<->act';
  END IF;
END//
DELIMITER ;

-- ---------------------------------------------------------------------------
-- Constraints NOT declaratively enforceable in standard SQL (documented):
--   * MemberOf Act(1,N): "an act has at least one member" is a participation
--     minimum on the Act side of a many-many. It cannot be enforced by a plain
--     FK/UNIQUE (that would require a row to exist in member_of before the act
--     itself). Enforced at the application layer, or with deferred/trigger-based
--     checks. Left as an application invariant for this sprint.
--   * The role<->kind rule above is enforced on INSERT; an equivalent BEFORE
--     UPDATE trigger would cover edits (omitted here for brevity).
-- ---------------------------------------------------------------------------

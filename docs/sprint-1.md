# Sprint 1 — Logical Design, Relational Algebra & SQL

**CSC 370 · Databases · Summer 2026 · University of Victoria**
Covers course competencies **Logical Design / relational mapping**, **Relational
Algebra**, and **Basic SQL (DDL + queries)**. Delivers on the plan set out in the
[README study plan](../README.md#4-study-plan--how-this-project-covers-the-course).

> Builds directly on [Sprint 0](sprint-0.md) (requirements + conceptual ERD). This
> document maps that ERD to a relational schema, expresses the key analytics in
> relational algebra, and stands the schema up in MySQL with runnable SQL.

**Artifacts in this sprint**
| File | What it is |
|---|---|
| [`sql/schema.sql`](../sql/schema.sql) | `CREATE TABLE` DDL: all tables, keys, FKs, constraints, one trigger. |
| [`sql/seed.sql`](../sql/seed.sql) | Small synthetic seed (real Victoria venues, synthetic figures). |
| [`sql/queries.sql`](../sql/queries.sql) | Benchmark + reconciliation + supporting queries, and constraint demos. |

**Run it**
```bash
mysql -u root < sql/schema.sql          # creates the `gigshare` database + tables
mysql -u root gigshare < sql/seed.sql   # loads synthetic data
mysql -u root gigshare < sql/queries.sql
```

---

## 1. Sprint goals (recap from the plan)

1. **Map the ERD to a relational schema** — entity sets → tables; `MemberOf` (many–many)
   → association table; many–one relationships (`HostedAt`, `FiledBy`, `Covers`) → foreign
   keys on the "many" side; choose a **subtype-mapping** strategy for the
   `Party`/`Act`/`Promoter` `isa`.
2. **Translate multiplicities and rules into keys/constraints** — including
   `UNIQUE(party_id, gig_id)` (one report per party per gig) and
   `UNIQUE(venue_id, gig_date)` (gig deduplication).
3. **Write the `CREATE TABLE`s in MySQL** and load a small **synthetic seed** that
   includes a gig reported by **multiple parties** (headliner + opener + promoter).
4. **Run ≥1 benchmark query** (avg net payout per attendee by venue capacity band) and one
   **reconciliation query** (surface where parties' reports for the same gig disagree).

New this sprint (added competency): **relational algebra** — each analytical query is given
its RA expression (§4) alongside the SQL, tying the formal query language to the SQL that
implements it.

---

## 2. Logical design — ERD → relational schema

### 2.1 Mapping rules applied
| ERD construct | Relational mapping |
|---|---|
| Entity set | One table; the identifier becomes the `PRIMARY KEY`. |
| Many–one relationship (`HostedAt`, `FiledBy`, `Covers`) | Foreign key on the **"many"** side. `(1,1)` participation → **`NOT NULL`** FK. |
| Many–many relationship (`MemberOf`) | **Association table** `member_of` with a composite PK of the two FKs; relationship attributes (`role`, `is_active`) become columns. |
| Generalization (`isa`: Party ▷ Act, Promoter) | **One table per subtype** (`act`, `promoter`), each with `party_id` as **both PK and FK** to `party` (class-table inheritance). A `party_kind` discriminator on `party` records the disjoint subtype. |
| Multiplicity minimum `= 1` | `NOT NULL` on the FK. |
| Multiplicity maximum `= 1` | The FK/`UNIQUE` places the relationship on the "one" side. |
| Uniqueness rules from §2.3 of Sprint 0 | `UNIQUE` constraints. |

**Why class-table inheritance for the `isa`?** The three common strategies are
(a) one table for the whole hierarchy with nullable subtype columns, (b) one table per
subtype only (no supertype table), and (c) supertype table **plus** a table per subtype
(chosen here). Option (c) keeps the single clean `FiledBy` relationship to `party` (the
supertype is a real table other things can reference), avoids nulls for subtype-specific
columns, and leaves an obvious place to add a future party type (e.g. a booking agent).

### 2.2 Relational schema (relation list)
Primary keys are <u>underlined</u>; foreign keys are marked → target.

- **musician**(<u>musician_id</u>, display_name, email `UNIQUE`, primary_instrument, home_city)
- **party**(<u>party_id</u>, party_name, contact_info, party_kind)
- **act**(<u>party_id</u> → party, genre, act_type)
- **promoter**(<u>party_id</u> → party, is_company)
- **venue**(<u>venue_id</u>, venue_name, city, capacity, venue_type)
- **gig**(<u>gig_id</u>, venue_id → venue `NOT NULL`, gig_date, door_price) &nbsp; `UNIQUE(venue_id, gig_date)`
- **member_of**(<u>musician_id</u> → musician, <u>party_id</u> → act, role, is_active)
- **earnings_report**(<u>report_id</u>, party_id → party `NOT NULL`, gig_id → gig `NOT NULL`, reporter_role, agreed_guarantee, door_split_pct, door_revenue, merch_sales, venue_fee, technician_fees, additional_expenses, attendance, net_payout, currency, submitted_at) &nbsp; `UNIQUE(party_id, gig_id)`

### 2.3 How each multiplicity/rule became a constraint
| From Sprint 0 | Constraint in the schema |
|---|---|
| `HostedAt` Gig `(1,1)` → Venue | `gig.venue_id` **`NOT NULL`** FK → venue |
| `FiledBy` Report `(1,1)` → Party | `earnings_report.party_id` **`NOT NULL`** FK → party |
| `Covers` Report `(1,1)` → Gig | `earnings_report.gig_id` **`NOT NULL`** FK → gig |
| `MemberOf` many–many | `member_of` association table, `PRIMARY KEY(musician_id, party_id)` |
| One report per party per gig | `UNIQUE(party_id, gig_id)` on `earnings_report` |
| Gig dedup by (venue, date) | `UNIQUE(venue_id, gig_date)` on `gig` |
| Financials are partial | financial columns **nullable** |
| Disjoint `isa` | `party.party_kind ENUM('act','promoter')` + one subtype table each |

**Constraints not declaratively enforceable (documented limitations):**
- **`MemberOf` Act `(1,N)` — "an act has ≥1 member":** a participation *minimum* on the
  many side of a many–many. A plain FK/`UNIQUE` can't require a `member_of` row to exist
  before the act does. Left as an **application invariant** (a trigger or deferred check is
  a later-module option).
- **`reporter_role` ↔ party kind:** a cross-table rule (a `'promoter'` report must be filed
  by a promoter; `'headliner'`/`'support'` by an act). A single-table `CHECK` can't see
  another table, so this is enforced by a **`BEFORE INSERT` trigger**
  (`trg_report_role_matches_kind`) that raises `SQLSTATE '45000'` on a mismatch.

---

## 3. DDL highlights

The full DDL is in [`sql/schema.sql`](../sql/schema.sql). Two representative tables:

```sql
-- Gig: many gigs -> one venue (FK here); deduplicated by (venue, date).
CREATE TABLE gig (
  gig_id     INT NOT NULL AUTO_INCREMENT,
  venue_id   INT NOT NULL,                    -- HostedAt (1,1)
  gig_date   DATE NOT NULL,
  door_price DECIMAL(8,2),
  PRIMARY KEY (gig_id),
  UNIQUE KEY uq_gig_venue_date (venue_id, gig_date),   -- dedup rule
  CONSTRAINT fk_gig_venue FOREIGN KEY (venue_id)
    REFERENCES venue (venue_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- EarningsReport: many reports -> one party, one gig; one per (party, gig).
CREATE TABLE earnings_report (
  report_id     INT NOT NULL AUTO_INCREMENT,
  party_id      INT NOT NULL,                 -- FiledBy (1,1)
  gig_id        INT NOT NULL,                 -- Covers  (1,1)
  reporter_role ENUM('headliner','support','promoter') NOT NULL,
  -- ... nullable financial columns ...
  attendance    INT,
  net_payout    DECIMAL(10,2),
  PRIMARY KEY (report_id),
  UNIQUE KEY uq_report_party_gig (party_id, gig_id),   -- one report per party per gig
  CONSTRAINT fk_report_party FOREIGN KEY (party_id) REFERENCES party (party_id),
  CONSTRAINT fk_report_gig   FOREIGN KEY (gig_id)   REFERENCES gig (gig_id)
) ENGINE=InnoDB;
```

---

## 4. Relational algebra ↔ SQL

Each analytical query below is given first in **relational algebra**, then in SQL. Operators:
σ (select/filter), π (project), ⋈ (natural/theta join), ρ (rename), γ (group-and-aggregate),
← (assignment). `γ` and arithmetic in projections are **extensions** to Codd's core algebra
(the core has no aggregation) — noting exactly where SQL goes beyond the pure algebra is
itself part of the competency.

### Q1 — Benchmark: average payout-per-head by venue capacity band
We restrict to performer reports (`headliner`/`support`), join report→gig→venue, derive a
`band` from `capacity` and `pph = net_payout / attendance` (a generalized projection), then
group and average.

```
R ← σ_{reporter_role ∈ {headliner, support} ∧ attendance > 0} (earnings_report)
J ← R ⋈ gig ⋈ venue
P ← π_{band ← band(capacity), pph ← net_payout / attendance} (J)
Result ← γ_{band ; AVG(pph) → avg_payout_per_head, COUNT(*) → n} (P)
```
where `band(capacity)` = *small* (<150) / *mid* (150–400) / *large* (>400).

```sql
SELECT
    CASE WHEN v.capacity < 150 THEN 'small (<150)'
         WHEN v.capacity <= 400 THEN 'mid (150-400)'
         ELSE 'large (>400)' END                AS capacity_band,
    COUNT(*)                                     AS n_reports,
    ROUND(AVG(r.net_payout / r.attendance), 2)   AS avg_payout_per_head
FROM earnings_report r
JOIN gig   g ON g.gig_id   = r.gig_id
JOIN venue v ON v.venue_id = g.venue_id
WHERE r.reporter_role IN ('headliner','support')
  AND r.attendance > 0 AND r.net_payout IS NOT NULL
GROUP BY capacity_band
ORDER BY MIN(v.capacity);
```

### Q2 — Reconciliation: reports for one gig that disagree on attendance
A self-join of `earnings_report` on the same gig, keeping only pairs with different
attendance; `report_id_1 < report_id_2` drops self-matches and mirror duplicates.

```
ρ_{r1}(earnings_report), ρ_{r2}(earnings_report)
Pairs ← σ_{r1.gig_id = r2.gig_id ∧ r1.report_id < r2.report_id ∧ r1.attendance ≠ r2.attendance} (r1 × r2)
Result ← π_{gig_id, r1.party_id, r1.attendance, r2.party_id, r2.attendance} (Pairs)
```

```sql
SELECT g.gig_id, v.venue_name, g.gig_date,
       p1.party_name AS party_a, r1.attendance AS attendance_a,
       p2.party_name AS party_b, r2.attendance AS attendance_b,
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
```

### Q3 — An act's earnings history (pure-algebra example)
Classic select/project/join, no aggregation — expressible in **core** relational algebra:

```
π_{gig_date, venue_name, net_payout} (
    σ_{party_name = 'Neon Salmon'} (party ⋈ earnings_report ⋈ gig ⋈ venue)
)
```

The remaining supporting queries (roster via the association table; multi-party shows) are in
[`sql/queries.sql`](../sql/queries.sql).

---

## 5. Verification (stands up to testing)

Reproduce with **[`sql/verify.sh`](../sql/verify.sh)**; the full captured run is in
**[`sprint-1-verification.md`](sprint-1-verification.md)**. Loaded on MySQL 9.7 (Homebrew).
Row counts after seed: musician 5, party 6 (act 4 + promoter 2), venue 6, gig 6,
member_of 8, earnings_report 10.

**Q1 — benchmark** (performer take-home per head, by band):

| capacity_band | n_reports | avg_payout_per_head |
|---|---|---|
| small (<150) | 2 | 15.14 |
| mid (150-400) | 4 | 12.24 |
| large (>400) | 1 | 20.00 |

**Q2 — reconciliation** (attendance disagreements): 4 conflicting pairs surfaced, all on
the two multi-party gigs — e.g. at **The Coda (gig 1)** the opener reported 105, the
headliner 110, and the promoter 118 (largest gap 13). Conflicts are *flagged, not
overwritten*.

**Constraint demos** — all four offending statements are **rejected** as designed:

| Rule | Attempt | Result |
|---|---|---|
| `UNIQUE(party_id, gig_id)` | second report from same party for gig 1 | `ERROR 1062` duplicate key |
| `UNIQUE(venue_id, gig_date)` | second gig at The Coda on 2026-06-14 | `ERROR 1062` duplicate key |
| `FiledBy` FK | report referencing a non-existent party | `ERROR 1452` FK fails |
| role ↔ kind trigger | promoter filing a `headliner` report | `ERROR 1644` (custom message) |

### Success criteria — status
- [x] Running MySQL instance with all tables created, keyed, and seeded.
- [x] FKs and both `UNIQUE` constraints verified (offending `INSERT`s rejected).
- [x] Benchmark and reconciliation queries return sensible results over the seed.

---

## 6. Next sprint plan (Sprint 2 → *Normalization & Query Performance*)

Sprint 1 delivers a working, constrained, queryable schema. Sprint 2 moves to the next
course modules — **schema quality (normalization)** and **physical/performance** concerns.

**Goals**
1. **Functional-dependency & normalization analysis** — write out the FDs for each table,
   confirm the schema is in **3NF/BCNF**, and justify (or refactor) any table that isn't
   (e.g. whether `city` belongs in a separate `city`/`region` table; whether `currency`
   implies anything).
2. **Views** — add a `report_reconciliation` view and an anonymised
   `benchmark_by_band` view so analytics don't re-hand-write the joins each time.
3. **Indexing & performance** — grow the synthetic seed to a few thousand gigs/reports,
   add indexes for the hot query paths (e.g. `earnings_report(gig_id)`,
   `gig(venue_id, gig_date)`), and use `EXPLAIN` + timings to show before/after.
4. **Larger synthetic generator** — a repeatable script (SQL or Python) producing
   realistic distributions, replacing the hand-written seed.

**Success criteria (measurable)**
- Each table annotated with its FDs and a stated normal form; any decomposition shown to
  be lossless and dependency-preserving.
- `EXPLAIN` output demonstrating an index changing a scan to a lookup on the benchmark
  query over the larger dataset, with wall-clock timings.

**Course-competency mapping:** *Normalization / FD theory* → goal 1; *Views / advanced SQL*
→ goal 2; *Physical design / indexing / performance* → goals 3–4.

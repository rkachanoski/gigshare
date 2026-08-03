# Sprint 2 — Normalization & Query Performance

**CSC 370 · Databases · Summer 2026 · University of Victoria**
Covers course competencies **Normalization / FD theory** and **Physical design,
indexing & query performance**. Delivers on the plan set in
[Sprint 1 §6](sprint-1.md#6-next-sprint-plan-sprint-2--normalization--query-performance).

> Builds on [Sprint 1](sprint-1.md), which mapped the ERD to a MySQL schema and
> verified its constraints. This sprint asks two questions Sprint 1 did not:
> **is the schema well-formed?** and **is it fast?** — and answers both with
> measurements rather than assertions.

**Artifacts in this sprint**
| File | What it is |
|---|---|
| [`sql/normalization.sql`](../sql/normalization.sql) | FD tests, lossless-decomposition check, and a lossy control. |
| [`sql/generate.py`](../sql/generate.py) | Seeded synthetic generator — 20,000 gigs / 31,926 reports. |
| [`sql/indexes.sql`](../sql/indexes.sql) | The three performance indexes, with the reasoning for each. |
| [`sql/bench.sh`](../sql/bench.sh) | Before/after experiment: query plans, timings, write cost. |
| [`sql/verify.sh`](../sql/verify.sh) | Extended: normalization checks + constraints re-checked at scale. |
| [`docs/sprint-2-verification.md`](sprint-2-verification.md) | The captured run of both harnesses. |

**Run it**
```bash
sql/verify.sh                      # schema, seed, analytics, constraints, normalization, scale
sql/bench.sh                       # the indexing experiment
```
Both exit non-zero on failure. Every number in this document comes from
[the captured run](sprint-2-verification.md) against **MySQL 9.7.1**.

---

## 1. Goals set for this sprint, and what happened

Set in [Sprint 1 §6](sprint-1.md#6-next-sprint-plan-sprint-2--normalization--query-performance):

| # | Goal | Status |
|---|---|---|
| 1 | FD & normalization analysis (3NF/BCNF), decompose or justify | ✅ Delivered — §2–3 |
| 2 | Views (`report_reconciliation`, anonymised `benchmark_by_band`) | ⛔ **Deliberately dropped** — §5.1 |
| 3 | Indexing & performance over a larger dataset, `EXPLAIN` + timings | ✅ Delivered — §4 |
| 4 | Larger synthetic data generator | ✅ Delivered — §4.1 |

Three of four delivered; one dropped on purpose, for a reason given in §5.1.

---

## 2. Functional dependencies and normal forms

For each relation: the FD set `F`, the candidate keys (derived by attribute
closure), and the highest normal form it satisfies.

**The test used throughout.** A relation is in **BCNF** iff for every non-trivial
FD `X → Y` in `F`, `X` is a superkey. Since BCNF implies 3NF implies 2NF, showing
every determinant is a superkey settles all three at once.

### 2.1 The relations

**`musician`**(<u>musician_id</u>, display_name, email, primary_instrument, home_city)
```
F = { musician_id → display_name, email, primary_instrument, home_city
      email       → musician_id, display_name, primary_instrument, home_city }
{musician_id}⁺ = all attributes   → superkey
{email}⁺       = all attributes   → superkey   (from UNIQUE)
```
Candidate keys: `{musician_id}`, `{email}`. Both determinants in `F` are
superkeys → **BCNF**.

**`party`**(<u>party_id</u>, party_name, contact_info, party_kind)
```
F = { party_id → party_name, contact_info, party_kind }
```
`party_name` is deliberately *not* unique — two acts really can share a name.
Sole candidate key `{party_id}`, sole determinant → **BCNF**.

**`act`**(<u>party_id</u>, genre, act_type) and **`promoter`**(<u>party_id</u>, is_company)
```
F = { party_id → genre, act_type }      F = { party_id → is_company }
```
One determinant each, and it is the key → **BCNF**.

**`venue`**(<u>venue_id</u>, venue_name, city, capacity, venue_type)
```
F = { venue_id → venue_name, city, capacity, venue_type }
```
No FD has `city` on the left, because the relation holds no attribute that a city
determines. Sole candidate key `{venue_id}` → **BCNF**. (This is the one
relation where that could change; see §5.2.)

**`gig`**(<u>gig_id</u>, venue_id, gig_date, door_price)
```
F = { gig_id               → venue_id, gig_date, door_price
      (venue_id, gig_date) → gig_id, door_price }          ← the Sprint 0 dedup rule
{gig_id}⁺ = all             {venue_id, gig_date}⁺ = all
```
**Two** candidate keys: `{gig_id}` and `{venue_id, gig_date}`. Prime attributes:
`gig_id, venue_id, gig_date`. Both determinants are superkeys → **BCNF**.
Note `door_price` depends on the *whole* of `(venue_id, gig_date)` — a given room
on a given night has one advertised price — so no partial dependency arises.

**`member_of`**(<u>musician_id</u>, <u>party_id</u>, role, is_active)
```
F = { (musician_id, party_id) → role, is_active }
```
`role` depends on the pair, not on either half: the same player is on bass in one
act and guitar in another, so `musician_id → role` does **not** hold. That is
precisely why this is not a 2NF violation. Sole candidate key is the full PK →
**BCNF**.

**`earnings_report`**(<u>report_id</u>, party_id, gig_id, reporter_role, …financials…, currency, submitted_at)
```
F = { report_id          → all other attributes
      (party_id, gig_id) → all other attributes }          ← one report per party per gig
```
**Two** candidate keys, `{report_id}` and `{party_id, gig_id}`; both determinants
are superkeys → **BCNF**.

### 2.2 The one FD that had to be argued, not read off

Is `net_payout` determined by the other financial columns? If

```
(agreed_guarantee, door_split_pct, door_revenue, merch_sales, …expenses) → net_payout
```

held, its determinant would not be a superkey and `earnings_report` would violate
BCNF, forcing a decomposition.

**It does not hold, by design.** A report is one party's *claim* about a night,
not a computation over its own inputs. Two reports can carry identical inputs and
different `net_payout` — cash adjustments, a side deal, rounding, or simply a
disagreement — and the reconciliation feature exists precisely to store and
surface that. Making `net_payout` derived would delete the phenomenon the system
is built to observe.

Worth being exact about the epistemics here: **no dataset can establish this.**
Data can refute an FD by exhibiting a counterexample; it can never confirm one,
since absence of a counterexample in a sample says nothing about the domain. An
FD is a constraint asserted about the world, and the argument above is that
assertion. `sql/normalization.sql` is written to match — its verdicts read
*"not refuted"*, not *"proved"*.

### 2.3 Result

**All seven relations are already in BCNF. No decomposition is required.**

This is the sprint's actual finding, and the reason is methodological rather than
lucky: the schema was derived from an ER model in which each entity set was given
an identifier *before* any attributes were attached, so every non-key attribute
describes exactly one entity. Normalization violations arise when facts about
different things get merged into one relation — which is the failure mode ER
modelling structurally prevents. Normalization theory and ER modelling are two
routes to the same place; arriving via one means the other has little left to do.

That is worth stating plainly rather than manufacturing a violation to fix.

---

## 3. The theory applied where it bites: the naive design

A clean bill of health is not a demonstration of competence, so the decomposition
machinery is exercised against the design GigShare would have had **without** the
ERD — one wide table, one row per report, everything on it. This is a
counter-example built in [`sql/normalization.sql`](../sql/normalization.sql), not
part of the schema.

```
report_wide(report_id, party_id, party_name, party_kind,
            gig_id, gig_date, door_price,
            venue_id, venue_name, city, capacity, venue_type,
            reporter_role, attendance, net_payout)
```

### 3.1 Its violations

```
f1  report_id            → every other attribute
f2  (party_id, gig_id)   → every other attribute
f3  party_id             → party_name, party_kind
f4  gig_id               → gig_date, door_price, venue_id
f5  venue_id             → venue_name, city, capacity, venue_type
```

Candidate keys `{report_id}` and `{party_id, gig_id}`; prime attributes
`report_id, party_id, gig_id`.

- **f3 and f4 violate 2NF.** Each determines non-prime attributes from a *proper
  subset* of the candidate key `(party_id, gig_id)` — textbook partial dependencies.
- **f5 violates 3NF.** `venue_id` is non-prime, so
  `report_id → venue_id → venue_name` is transitive.

`report_wide` is therefore in **1NF only**.

### 3.2 What that costs, measured

`venue_name` is repeated on every report row for that venue, so a rename must
rewrite all of them, and any row missed silently forks one venue into two. On the
seed, The Coda's three reports mean **3× write amplification**; on the generated
dataset the busiest venue carries far more. In the normalized schema it is always
one `UPDATE` of one row.

The insert and delete anomalies are worse for this application specifically: with
no separate `venue` relation you cannot record a venue until someone files a
report about it, and deleting the last report for a venue **destroys its
capacity** — which is the reference data the entire capacity-band benchmark is
computed against.

### 3.3 Decomposing it, and where it lands

Removing the violating FDs one at a time:

| Step | Fragment peeled off | Shared attribute | Key of a fragment? |
|---|---|---|---|
| f5 out | `venue(venue_id, venue_name, city, capacity, venue_type)` | `venue_id` | ✅ key of `venue` |
| f4 out | `gig(gig_id, venue_id, gig_date, door_price)` | `gig_id` | ✅ key of `gig` |
| f3 out | `party(party_id, party_name, party_kind)` | `party_id` | ✅ key of `party` |
| residue | `earnings_report(report_id, party_id, gig_id, reporter_role, attendance, net_payout)` | — | — |

Each step satisfies the **lossless-join condition** (`R₁ ∩ R₂` is a key of one
fragment), so the chain is lossless. It is also **dependency-preserving**: every
FD in `F` lands wholly inside one fragment — f5 in `venue`, f4 in `gig`, f3 in
`party`, f1/f2 in `earnings_report` — so no FD needs a join to enforce.

**The decomposition reproduces the shipped schema, attribute for attribute.**
Normalizing the naive design arrives at the design the ERD already produced in
Sprint 1. That convergence is the evidence for §2.3's claim.

### 3.4 Checked against data, with a control

Theory verified empirically ([captured run](sprint-2-verification.md)):

| Check | Result |
|---|---|
| f3, f4, f5 tested against the data | not refuted (max 1 distinct dependent per determinant group) |
| `(party_id, gig_id)` unique | holds |
| **Decomposition rejoined vs. original** | 10 → 10 rows, **0 spurious, 0 missing** → lossless |
| **Control: bad split on non-key `city`** | 6 → **36 rows, 30 spurious** → correctly detected lossy |

The control is the point. A losslessness check that has only ever been run against
a correct decomposition proves nothing — it would pass with the comparison logic
broken. Splitting `(venue_name, city, capacity)` on `city`, which is a key of
neither fragment, fabricates every venue×capacity pairing in the city; the same
machinery catches it. That is what makes the PASS above mean something.

---

## 4. Indexing and query performance

### 4.1 A dataset worth measuring

Every access path over the 10-row seed is a trivial scan, so it cannot distinguish
a good index from a bad one. [`sql/generate.py`](../sql/generate.py) produces a
seeded (`--seed 370`, reproducible) dataset:

| venues | musicians | acts | promoters | memberships | gigs | **earnings reports** |
|---|---|---|---|---|---|---|
| 220 | 1,500 | 800 | 120 | 2,296 | 20,000 | **31,926** |

Constraints stay **enabled** during the load — including the role↔kind trigger,
which fires 31,926 times. Disabling them would load faster but would prove nothing
about whether the generated data respects them. It loads in **0.82 s**.

The data is shaped so the analytics have something to find: capacities skewed
toward small rooms, attendance a fraction of capacity, and — importantly —
co-reporters on the same gig **disagree** about attendance by a few percent, so
the reconciliation query has real signal at scale.

### 4.2 What was already indexed (and why two "missing" indexes weren't)

The baseline is not indexless, and assuming otherwise would have produced a fake
result. Two access paths already exist:

- **`earnings_report(gig_id)`** — InnoDB *auto-creates* `fk_report_gig` to support
  the foreign key. The reconciliation self-join is already served. An earlier
  plan for this sprint had "add an index for the self-join on `gig_id`" as the
  headline win; inspecting `SHOW INDEX` first showed there was nothing to win.
- **`earnings_report(party_id)`** — the leftmost prefix of
  `uq_report_party_gig(party_id, gig_id)`. The Sprint 0 business rule *one report
  per party per gig* pays for the act-history lookup for free. Q4 below is
  included as a control precisely to show this.

### 4.3 Results

Four queries, measured before and after [`sql/indexes.sql`](../sql/indexes.sql).
Times are **ms per execution, server-side**: each is the median of three batches
of 20 executions in one connection, minus the measured 11.1 ms client-connection
overhead. Timing single `mysql` invocations was tried first and abandoned — the
connection cost exceeded most of the query times and compressed every ratio
toward 1.0.

| | Query | Plan before | Plan after | Time before | Time after | Change |
|---|---|---|---|---|---|---|
| **Q1** | Community benchmark, whole dataset | `ALL` 31,926 rows, *temporary + filesort* | `range` on `idx_report_bench`, **`Using index`** | 17.11 ms | 10.54 ms | **1.62× faster** |
| **Q2** | Benchmark over a date window | `ALL` 31,926 rows | `range` on `idx_gig_date` 1,654 rows, **`Using index`** | 22.05 ms | 3.71 ms | **5.94× faster** |
| **Q3** | Recently filed reports | `ALL` 31,926 rows | `range` on `idx_report_submitted` 882 rows, **`Using index`** | 3.76 ms | 0.15 ms | **25.07× faster** |
| **Q4** | One act's history *(control)* | `ref` on `uq_report_party_gig`, 22 rows | *identical — no index added* | 0.14 ms | 0.17 ms | noise floor |

**Q3** is the cleanest win: `ALL` → `range`, **36× fewer rows** examined, covering.
**Q2** likewise, **19× fewer rows**.

**Q1 is the interesting one.** Its row estimate barely moves — 31,926 → 28,636 —
because 85% of reports are `headliner`/`support`, so the predicate filters almost
nothing. It still gets 1.6× faster, for two reasons that have nothing to do with
row counts: the index **covers** the query (`Using index` — InnoDB never touches
the clustered row), and because the index is already ordered by `reporter_role`,
the `GROUP BY` is satisfied by index order, eliminating the *temporary table and
filesort* the baseline plan needed. Rows examined is not the only cost.

**Q4 is a control**: no index was added, its plan is byte-identical in both arms,
and at ~0.2 ms it sits on the measurement noise floor. Its before/after delta is
scatter, not an effect — reported as such rather than dressed up.

### 4.4 An index that makes things worse

`reporter_role` has three values and the Q1 predicate matches ~85% of the table.
Indexing it alone:

```
type=index   key=idx_report_role_only   rows=31926   Using where
25.31 ms  vs  17.11 ms with no index at all  →  1.48× SLOWER
```

The optimizer does not politely ignore it — it **picks** it, scans the whole index
end to end, and then performs a clustered-row lookup per entry because the index
does not cover the query. That is strictly more work than the sequential table
scan it replaced. A low-selectivity, non-covering index is not merely useless; it
is a regression the optimizer will walk into.

### 4.5 The cost side

Indexes are paid for on every write. Reloading the same 31,926 reports with the
three indexes present: **0.82 s → 0.90 s, +10%**. Modest here, but it is the
standing charge on all future inserts, and the reason `schema.sql` declares only
what the logical design requires while tuning lives in `indexes.sql`.

### 4.6 Correctness

An optimization that changes an answer is a bug. All four result sets are
**byte-identical** before and after indexing (`bench.sh` §4, diffed per query) —
the indexes changed cost, not semantics.

---

## 5. Honest accounting

### 5.1 The dropped goal: views

Sprint 1 §6 committed to two views: `report_reconciliation` and an anonymised
`benchmark_by_band`. **They were dropped, deliberately, and not attempted.**

The reason is that they were mis-filed. The flagship one — an anonymised benchmark
view that exposes aggregates while withholding party identities — is an
**access-control mechanism**. A view used that way is only meaningful alongside
the thing that makes it binding: privileges granted on the view and withheld on
the base tables. Shipping it in a normalization-and-performance sprint would
produce a view that *looks* anonymised while every user retains full `SELECT` on
`earnings_report` underneath — security theatre, and a worse demonstration of the
competency than not doing it.

It is deferred to whichever sprint covers authorization/`GRANT`, where it can be
built against the mechanism that actually enforces it. This was a scope judgement,
not a shortfall of time: no work was started and none was abandoned.

### 5.2 What the analysis surfaced that isn't a normalization problem

Two findings worth recording, neither acted on this sprint:

1. **`venue.city` is free text.** Not an FD violation — nothing in the relation
   depends on `city` — but a data-integrity weakness: nothing stops `Victoria`,
   `victoria`, and `Victoria, BC` becoming three cities and silently splitting the
   city filter (Sprint 0 req. 9). It also becomes a genuine 3NF violation the
   moment any region attribute (`province`, `country`) is added to `venue`, since
   `city → province` would then be transitive. Flagged as the trigger condition
   for a future `city` relation; adding one now would be schema the requirements
   do not yet call for.
2. **`earnings_report` overloads some columns across reporter roles.** `venue_fee`
   means "what I was charged" on an act's report and "what I collected" on a
   promoter's. Legal under BCNF — no FD is violated — but a modelling smell worth
   revisiting if promoter analytics grow.

### 5.3 Technical snags hit along the way

- **MySQL 9.7 defaults `@@explain_format` to `TREE`**, which omits the
  `type`/`key`/`rows` columns entirely. Every `EXPLAIN` in `bench.sh` must specify
  `FORMAT=TRADITIONAL` or the experiment silently reports nothing measurable.
- **A CTE containing a set operation (`EXCEPT`) returns inconsistent results when
  referenced from several scalar subqueries in one `SELECT`** on 9.7: the
  losslessness check read `n_spurious = 0` while the expression `n_spurious = 0`
  simultaneously evaluated false, producing a spurious FAIL. Fixed by collapsing
  each such CTE to a count *once* and computing the verdict over those columns.
  Worth flagging as a caught false negative — the first run of that check reported
  a failure that was an artifact of the query, not of the decomposition.
- **The first data generator hung.** Names were drawn by rejection sampling until
  unique, but 800 acts were being drawn from a 16×14 = 224-name vocabulary, so the
  loop could never terminate. Replaced with suffix-based disambiguation, which
  always terminates.

### 5.4 Velocity

Three of four goals delivered, one dropped by choice; the delivered work also
exceeded plan in two places (a lossy control for the decomposition check, and a
measured negative result for indexing). Velocity looks right — Sprint 3 is planned
at comparable size below.

---

## 6. Progress on a course-level competency

**Competency: design, implement, and *evaluate* a database-backed information
system against real application requirements.**

Sprints 0 and 1 built: requirements → ERD → relational mapping → constraints →
relational algebra → SQL. Every step produced an artifact, but each was judged by
inspection — the schema was correct because the mapping rules were followed.

Sprint 2 is the first sprint that **evaluates** rather than constructs, and the
shift is what the competency is about:

- The design is no longer *asserted* to be well-formed; it is checked against BCNF
  and the check is itself controlled against a known-bad case (§3.4).
- Performance claims are no longer plausible-sounding; they are measurements with
  a stated method, a stated overhead, a control query, and a negative result
  (§4.3–4.4).
- The system is exercised at 3,000× the seed size, where the constraints are
  re-verified (§4.1) rather than assumed to scale.

The through-line back to the requirements holds: the *one report per party per gig*
rule from Sprint 0 §1.3 became a `UNIQUE` in Sprint 1, was shown in §2 to be the
second candidate key that puts `earnings_report` in BCNF, and was found in §4.2 to
be the index already serving act-history lookups. One business rule doing
correctness, normalization, and performance work simultaneously is the clearest
evidence available that the layers are actually connected rather than merely
sequential.

---

## 7. Next sprint plan (Sprint 3 → *ACID Transactions*)

Scoped per the sprint handout: competencies **up to and including ACID
Transactions**, with isolation/concurrency treated as an explicit stretch.

**Motivating problem.** Filing a report is not one statement. It is: resolve the
venue, find-or-create the gig for `(venue, date)` — the Sprint 0 dedup rule — then
insert the report. Today that is three round trips with no atomicity. If the
role↔kind trigger rejects the report, a gig row created moments earlier is
**orphaned**: a show that exists in the database with nobody reporting it, which
silently corrupts the "multi-party shows" analytics. This is a real defect in the
current system, not a contrived exercise.

**Goals**

1. **`sp_submit_report` — the operation as one transaction.** A stored procedure
   wrapping find-or-create-gig plus report insert in `START TRANSACTION` /
   `COMMIT`, with a handler that rolls back on any failure.
2. **Atomicity, demonstrated.** A scripted failing call (promoter filing a
   `headliner` report) must leave `gig` and `earnings_report` counts *unchanged*.
3. **Consistency.** Show the constraints and the trigger hold across the
   transaction boundary, including the deduplication invariant under
   find-or-create.
4. **Durability.** Restart `mysqld` after `COMMIT` and assert the committed row
   survives; explain the InnoDB redo log (WAL) and
   `innodb_flush_log_at_trx_commit` as the mechanism.
5. **`SAVEPOINT` for partial rollback.** A batch import where one bad row rolls
   back to a savepoint while the other N−1 rows still commit — the behaviour a
   bulk CSV upload of a season's gigs actually needs.
6. *(stretch)* **Isolation.** Two concurrent sessions, `SELECT … FOR UPDATE`,
   isolation levels, and an induced deadlock — the find-or-create above is a
   genuine race, so this is the natural continuation rather than an add-on.

**Success criteria (measurable, each asserted in `verify.sh`)**
- A failing `sp_submit_report` call leaves both table counts byte-identical to
  their pre-call values; the harness exits non-zero otherwise.
- A successful call creates **exactly one** report and **at most one** gig, with a
  second call for the same `(venue, date)` reusing the existing gig — proving the
  dedup rule survives concurrency-free repetition.
- After a real `mysqld` restart, a row committed immediately before shutdown is
  present.
- The savepoint test commits exactly N−1 of N rows, with the count asserted.
- *(stretch)* Two sessions produce a reproducible deadlock, with MySQL's victim
  selection shown from `SHOW ENGINE INNODB STATUS`.

**Course-competency mapping:** *Transactions / ACID* → goals 1–5;
*Concurrency control & isolation* → goal 6; the stored procedure also extends
*advanced SQL* beyond the DDL and queries of Sprint 1.

**Carried forward:** views + `GRANT`-based anonymisation (§5.1), to land in the
sprint covering authorization.

# GigShare — A Data Platform for Pooling Live-Music Earnings

**CSC 370 · Databases · Summer 2026 · University of Victoria**
A MySQL-backed information system built over weekly one-week sprints.

---

## 1. Overview

### The problem
Among the many relationships in the live-music industry, **the musicians themselves
tend to hold the weakest position.** Margins on live performance keep shrinking:
venues increasingly charge door/cover fees, take larger cuts, shift risk onto acts
(e.g. "pay-to-play", unfavourable door splits), and there is almost no shared visibility
into what a fair deal actually looks like. Each act negotiates alone, in the dark, with
no reference data.

### The idea
**GigShare** is an information system that lets musicians **pool the final earnings
reports from their live gigs**. By contributing their own numbers, members gain access
to aggregated, anonymised benchmarks across the community. This turns thousands of
private, siloed payout slips into a shared dataset that musicians can use to:

- **Develop high-level strategy** — which venues, cities, nights, or billing slots
  actually pay, and which don't.
- **Run data analytics** — average payout per head, door-split norms by venue capacity,
  seasonality of earnings, merch-vs-door revenue ratios, etc.
- **Advocate and lobby** — walk into a booking negotiation (or a policy discussion about
  live-music funding) with hard, collective evidence instead of anecdotes.

The core shareable unit of data is the **earnings report**: what a party was actually paid
for a specific performance at a specific venue, plus the surrounding financial context
(guarantee, door split, attendance, merch, expenses).

### Who uses it
| Stakeholder | What they do with the system |
|---|---|
| **Individual musician** | Submits earnings reports for their acts; browses benchmarks. |
| **Act / band** | The performing unit a report is attributed to. |
| **Promoter** | *(optional)* Organises gigs and files reports from the promoter's side. |
| **The community (aggregate)** | Consumes anonymised analytics and benchmarks. |
| *(future)* **Advocacy org / researcher** | Exports aggregate trends for lobbying. |

---

## 2. The data model at a glance

The full requirements and conceptual model live in the [Sprint 0 deliverable](docs/sprint-0.md);
the relational schema lives in [Sprint 1](docs/sprint-1.md). In brief:

- **Entities:** `Musician`, `Party` (supertype), `Act` & `Promoter` (subtypes of `Party`
  via an `isa` generalization), `Venue`, `Gig`, `EarningsReport`.
- **Core relationships:** a musician is a **member of** many acts (many–many); a gig is
  **hosted at** exactly one venue; an **earnings report** is *filed by* one party and
  *covers* one gig.
- **Key rules:** a gig can be reported by **many parties** (headliner, opener, and
  *optionally* a promoter); **one report per party per gig** (`UNIQUE(party_id, gig_id)`);
  gigs are **deduplicated by `(venue, date)`** so every party's report attaches to the same
  show. Each report is one party's own — possibly partial — claim; conflicts are
  **reconciled at read time, never overwritten**.

For the authoritative Chen-notation ERD, entity/attribute tables, and multiplicities, see
[`docs/sprint-0.md`](docs/sprint-0.md). For the tables, keys, and DDL, see
[`docs/sprint-1.md`](docs/sprint-1.md) and [`sql/`](sql/).

---

## 3. Sprints

Each sprint is delivered as a git commit + video against the course rubric. Deliverable
docs live in [`docs/`](docs/).

| Sprint | Focus | Deliverable | Status |
|---|---|---|---|
| **0 — Kick-Off** | Requirements & Basic Conceptual Design | [`docs/sprint-0.md`](docs/sprint-0.md) | ✅ Complete |
| **1 — Logical Design & SQL** | ERD → relational schema, relational algebra, MySQL DDL + queries | [`docs/sprint-1.md`](docs/sprint-1.md), [`sql/`](sql/) | ✅ Complete |
| **2 — Normalization & Performance** | FD/BCNF analysis, lossless decomposition, indexing & measured performance | [`docs/sprint-2.md`](docs/sprint-2.md), [`sql/`](sql/) | ✅ Complete |
| **3 — ACID Transactions** | Transactional report submission, atomicity/consistency/durability, savepoints | *planned — see [Sprint 2 §7](docs/sprint-2.md#7-next-sprint-plan-sprint-3--acid-transactions)* | ⬜ Planned |

### Running the SQL
```bash
mysql -u root < sql/schema.sql          # creates the `gigshare` database + tables
mysql -u root gigshare < sql/seed.sql   # loads a small synthetic dataset
mysql -u root gigshare < sql/queries.sql

sql/verify.sh    # schema, seed, analytics, constraints, normalization, at-scale checks
sql/bench.sh     # the indexing experiment: plans + timings, before and after
python3 sql/generate.py | mysql -u root gigshare   # ~32k synthetic reports
```
`sql/verify.sh` and `sql/bench.sh` exit non-zero on failure. Their captured runs are
committed in [`docs/sprint-1-verification.md`](docs/sprint-1-verification.md) and
[`docs/sprint-2-verification.md`](docs/sprint-2-verification.md).

---

## 4. Study Plan — How this project covers the course

The project is intentionally chosen to touch many modules, with clear levers to
increase complexity as competencies advance.

| Course area | How GigShare exercises it | Status | Complexity lever |
|---|---|---|---|
| **Requirements / Data Architecture** | Requirements + business rules ([Sprint 0 §1](docs/sprint-0.md#1-requirements)) | ✅ | add stakeholder roles (advocacy orgs, researchers) |
| **Conceptual design (ERD + multiplicity)** | Entities, identifiers, relationships, `(min,max)` multiplicities ([Sprint 0 §2](docs/sprint-0.md#2-basic-conceptual-design-erd)) | ✅ | more entity sets: tours, tickets, agents |
| **Generalization / specialization** | `Party` supertype with `Act` / `Promoter` subtypes (`isa`) | ✅ | more party types (e.g. booking agent) |
| **Logical design / relational mapping** | ERD → tables; association table + FKs; subtype→table strategy ([Sprint 1 §2](docs/sprint-1.md#2-logical-design--erd--relational-schema)) | ✅ | normalization of address/city |
| **Relational algebra** | Analytics expressed in RA alongside SQL ([Sprint 1 §4](docs/sprint-1.md#4-relational-algebra--sql)) | ✅ | more complex algebra (division, outer joins) |
| **SQL (DDL + queries)** | `CREATE TABLE`s, constraints, benchmark + reconciliation queries ([`sql/`](sql/)) | ✅ | aggregation, `GROUP BY` |
| **Normalization / FD theory** | FD sets, candidate keys by closure, BCNF proof; lossless + dependency-preserving decomposition with a lossy control ([Sprint 2 §2–3](docs/sprint-2.md#2-functional-dependencies-and-normal-forms)) | ✅ | multivalued dependencies / 4NF |
| **Physical design / performance** | 32k-row generator, covering & range indexes, `EXPLAIN` + timings, a measured negative result ([Sprint 2 §4](docs/sprint-2.md#4-indexing-and-query-performance)) | ✅ | query-plan rewriting, partitioning |
| **Transactions / ACID** | Transactional report submission; atomicity, consistency, durability, savepoints | ⬜ | isolation levels, deadlocks |
| **Views / access control** | Anonymised benchmark view enforced by `GRANT` — *deferred from Sprint 2, see [§5.1](docs/sprint-2.md#51-the-dropped-goal-views)* | ⬜ | row-level security |

### Data acquisition plan
We do not need real (sensitive) financial data to build and demo the system:
1. **Synthetic generation** — a seed producing realistic gigs/venues/reports (plausible
   capacities, door splits, payouts) for development and analytics demos. The current
   [`sql/seed.sql`](sql/seed.sql) uses real Victoria venues with synthetic figures.
   [`sql/generate.py`](sql/generate.py) scales this to ~32,000 reports from a fixed
   seed for reproducibility, supporting the performance work.
2. **Public reference points** — venue capacities and ticket prices from public listings
   to calibrate the synthetic distributions.
3. *(stretch)* a small **opt-in real submission** form once the schema stabilises.

---

## 5. Repository & Submission

- **Repo:** https://github.com/rkachanoski/gigshare
- **Team:** solo (1 member — Reg Kachanoski).
- **Submission per sprint:** git link + commit hash + video, with group members named in
  the submission comments.
- **Video length limit:** `2 + 1.5 × group size` minutes — a hard cap of **3.5 minutes**
  for this solo project. Any overrun is a failing grade. This formula took effect at
  Sprint 2, superseding the `4 + 2.0 × group size` rule that applied to Sprints 0–1.
- **AI-use disclosure:** generative AI (Claude) assisted with drafting the requirements and
  conceptual-design document, structuring/rendering the ERD (Sprint 0); in Sprint 1,
  drafting the relational mapping, MySQL DDL, the relational-algebra formulations, and the
  synthetic seed/queries; and in Sprint 2, drafting the FD/normalization analysis, the
  synthetic data generator, the indexing experiment harness, and the sprint write-up.
  All design decisions, requirements, business rules, and the project concept are the
  author's own. The AI's output was reviewed, run, and verified against a live MySQL
  instance; every figure quoted in the sprint documents originates from a captured run
  of the committed harnesses. Per-component attribution is maintained here as the
  project grows.

---

## 6. Glossary

- **Party** — anything that can file a report: an **act** or a **promoter** (a generalization).
- **Act** — a performing unit (solo or band) that earnings are attributed to.
- **Promoter** — *(optional)* a person/company that organises a gig and moves money.
- **Gig** — one live-performance event at one venue on one date (deduplicated by `(venue, date)`).
- **Earnings report** — one party's own financial account of one gig; the core shared datum.
- **Door split** — the agreed division of door/cover revenue between venue and act.
- **Guarantee** — a flat fee promised to an act regardless of attendance.
- **Payout per head** — net payout ÷ attendance; a key benchmarking metric.
- **Reconciliation** — comparing multiple parties' reports for one gig and flagging (not
  overwriting) disagreements.

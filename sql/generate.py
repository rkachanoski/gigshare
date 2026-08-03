#!/usr/bin/env python3
"""
GigShare — Sprint 2 synthetic data generator.

Emits SQL on stdout for a dataset large enough that indexing decisions actually
show up in a query plan. The hand-written sql/seed.sql (10 reports) is fine for
demonstrating constraints, but every access path over it is a trivial scan, so it
can't tell a good index from a bad one.

Usage:
    mysql -u root < sql/schema.sql
    python3 sql/generate.py | mysql -u root gigshare

    python3 sql/generate.py --gigs 2000 > /tmp/small.sql      # smaller run

Design notes:
  * stdlib only, and seeded (--seed, default 370) so a given seed always yields
    a byte-identical script. Performance numbers are only comparable across runs
    if the data is.
  * Constraints stay ENABLED during the load. It would be faster to drop
    foreign_key_checks/unique_checks, but a load that bypasses the constraints
    proves nothing about whether the generated data respects them — and
    "the integrity rules still hold at scale" is one of this sprint's claims.
  * Every value is synthetic. Venue and act names are assembled from word lists;
    the real Victoria rooms stay in sql/seed.sql.

Shape of the data (chosen so the analytics have something to find):
  * Venue capacities are skewed toward small rooms, as the real market is.
  * Attendance is a fraction of capacity, so payout-per-head varies by band.
  * Co-reporters on the same gig DISAGREE about attendance by a few percent,
    which is what gives the reconciliation query real signal at scale.
  * Support acts often leave venue-side fields NULL — they genuinely don't know
    the venue fee. That keeps the "partial report" design exercised.
"""

import argparse
import datetime as dt
import random
import sys

# --- vocabulary for synthetic names ----------------------------------------
CITIES = [
    "Victoria", "Vancouver", "Nanaimo", "Kelowna", "Calgary", "Edmonton",
    "Winnipeg", "Toronto", "Montreal", "Halifax", "Saskatoon", "Ottawa",
]
VENUE_A = ["The", "Old", "Blue", "Electric", "Golden", "Iron", "Red", "Silver",
           "Lucky", "Royal", "Rusty", "Velvet", "Wild", "Northern"]
VENUE_B = ["Anchor", "Lantern", "Fox", "Hall", "Ballroom", "Tavern", "Room",
           "Cellar", "Union", "Alley", "Mill", "Wheel", "Dock", "Parlour"]
VENUE_C = ["", "", "", " Club", " Bar", " Live", " Social", " Lounge"]
ACT_A = ["Neon", "Paper", "Glass", "Slow", "Velvet", "Ghost", "Salt", "Iron",
         "Wild", "Quiet", "Bitter", "Golden", "Cold", "Hollow", "Amber", "Static"]
ACT_B = ["Salmon", "Harbour", "Wakes", "Tide", "Signal", "Cassette", "Arcade",
         "Machine", "Weather", "Choir", "Divide", "Anchor", "Lantern", "Season"]
PROMO_A = ["Tidal", "Westcoast", "Nightshift", "Harbour", "Foghorn", "Union",
           "Riptide", "Lowlight", "Beacon", "Crosstown"]
PROMO_B = ["Presents", "Productions", "Concerts", "Live", "Bookings", "Collective"]
FIRST = ["Ada", "Theo", "Priya", "Marco", "Reg", "Sam", "Nina", "Owen", "Iris",
         "Luca", "Mei", "Cass", "Jonah", "Rosa", "Kit", "Dev", "Nora", "Emil",
         "Sana", "Beau", "Tova", "Rhys", "Juno", "Vero", "Milo", "Anya"]
LAST = ["Cormier", "Nunn", "Rao", "Vidal", "Okafor", "Lindqvist", "Bhatt",
        "Moreau", "Ellis", "Kaur", "Novak", "Ferreira", "Whitehorse", "Tran",
        "Costa", "Aalto", "Mbeki", "Sorensen", "Dubois", "Reyes"]
INSTRUMENTS = ["guitar", "bass", "drums", "vocals", "synths", "sax", "fiddle",
               "keys", "pedal steel", "trumpet", "cello", "banjo"]
GENRES = ["indie rock", "folk", "electronic", "post-punk", "jazz", "country",
          "metal", "hip hop", "shoegaze", "soul", "punk", "ambient"]
VENUE_TYPES = ["bar", "club", "theatre", "hall", "festival", "other"]
ACT_TYPES = ["solo", "duo", "band"]

BATCH = 500          # rows per multi-row INSERT


def q(s):
    """Quote a string literal for MySQL."""
    return "'" + s.replace("\\", "\\\\").replace("'", "''") + "'"


def money(x):
    return "NULL" if x is None else f"{x:.2f}"


def num(x):
    return "NULL" if x is None else str(x)


def unique_name(base, used):
    """Make `base` unique by suffixing a counter.

    Rejection-sampling until a random name happens to be unused only terminates
    while the vocabulary is much larger than the number of names needed — with
    800 acts drawn from a 224-combination vocabulary it never does. Suffixing
    always terminates, and reads plausibly: real scenes do have two bands with
    near-identical names.
    """
    name, n = base, 2
    while name in used:
        name = f"{base} {n}"
        n += 1
    used.add(name)
    return name


def emit(table, cols, rows, out):
    """Write rows as batched multi-row INSERTs."""
    for i in range(0, len(rows), BATCH):
        chunk = rows[i:i + BATCH]
        out.write(f"INSERT INTO {table} ({', '.join(cols)}) VALUES\n")
        out.write(",\n".join("  (" + ", ".join(r) + ")" for r in chunk))
        out.write(";\n")


def pick_capacity(rnd):
    """Skewed toward small rooms — the shape of the actual live-music market."""
    band = rnd.random()
    if band < 0.50:
        return rnd.randint(40, 149)        # small
    if band < 0.85:
        return rnd.randint(150, 400)       # mid
    return rnd.randint(401, 2200)          # large


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=370)
    ap.add_argument("--venues", type=int, default=220)
    ap.add_argument("--musicians", type=int, default=1500)
    ap.add_argument("--acts", type=int, default=800)
    ap.add_argument("--promoters", type=int, default=120)
    ap.add_argument("--gigs", type=int, default=20000)
    args = ap.parse_args()

    rnd = random.Random(args.seed)
    out = sys.stdout

    out.write("-- Generated by sql/generate.py — DO NOT EDIT BY HAND.\n")
    out.write(f"-- seed={args.seed} venues={args.venues} musicians={args.musicians} "
              f"acts={args.acts} promoters={args.promoters} gigs={args.gigs}\n")
    out.write("-- Constraints stay enabled throughout; see the module docstring.\n")
    out.write("USE gigshare;\nSET autocommit = 0;\n\n")

    # ---- venues ------------------------------------------------------------
    venues, seen_names = [], set()
    for vid in range(1, args.venues + 1):
        name = unique_name(
            f"{rnd.choice(VENUE_A)} {rnd.choice(VENUE_B)}{rnd.choice(VENUE_C)}",
            seen_names)
        cap = pick_capacity(rnd)
        venues.append((vid, name, rnd.choice(CITIES), cap, rnd.choice(VENUE_TYPES)))
    emit("venue", ["venue_id", "venue_name", "city", "capacity", "venue_type"],
         [[str(v[0]), q(v[1]), q(v[2]), str(v[3]), q(v[4])] for v in venues], out)
    capacity_of = {v[0]: v[3] for v in venues}

    # ---- parties: acts occupy ids 1..A, promoters A+1..A+P -----------------
    n_acts, n_promo = args.acts, args.promoters
    act_ids = list(range(1, n_acts + 1))
    promo_ids = list(range(n_acts + 1, n_acts + n_promo + 1))

    party_rows, act_rows, promo_rows = [], [], []
    used = set()
    for pid in act_ids:
        nm = unique_name(f"{rnd.choice(ACT_A)} {rnd.choice(ACT_B)}", used)
        party_rows.append([str(pid), q(nm), q(f"act{pid}@example.com"), q("act")])
        act_rows.append([str(pid), q(rnd.choice(GENRES)), q(rnd.choice(ACT_TYPES))])
    for pid in promo_ids:
        nm = unique_name(f"{rnd.choice(PROMO_A)} {rnd.choice(PROMO_B)}", used)
        party_rows.append([str(pid), q(nm), q(f"promo{pid}@example.com"), q("promoter")])
        promo_rows.append([str(pid), "TRUE" if rnd.random() < 0.6 else "FALSE"])

    emit("party", ["party_id", "party_name", "contact_info", "party_kind"], party_rows, out)
    emit("act", ["party_id", "genre", "act_type"], act_rows, out)
    emit("promoter", ["party_id", "is_company"], promo_rows, out)

    # ---- musicians ---------------------------------------------------------
    mus_rows = []
    for mid in range(1, args.musicians + 1):
        nm = f"{rnd.choice(FIRST)} {rnd.choice(LAST)}"
        mus_rows.append([str(mid), q(nm), q(f"m{mid}@example.com"),
                         q(rnd.choice(INSTRUMENTS)), q(rnd.choice(CITIES))])
    emit("musician", ["musician_id", "display_name", "email",
                      "primary_instrument", "home_city"], mus_rows, out)

    # ---- member_of: 1-5 musicians per act, unique (musician, act) ----------
    member_rows = []
    for pid in act_ids:
        size = rnd.choices([1, 2, 3, 4, 5], weights=[18, 22, 30, 20, 10])[0]
        for mid in rnd.sample(range(1, args.musicians + 1), size):
            member_rows.append([str(mid), str(pid), q(rnd.choice(INSTRUMENTS)),
                                "TRUE" if rnd.random() < 0.88 else "FALSE"])
    emit("member_of", ["musician_id", "party_id", "role", "is_active"], member_rows, out)

    # ---- gigs: unique (venue_id, gig_date) ---------------------------------
    # Resample on collision rather than disabling the constraint.
    start = dt.date(2023, 1, 1)
    span = 1095                                  # three years of dates
    gig_rows, gigs, taken = [], [], set()
    for gid in range(1, args.gigs + 1):
        while True:
            vid = rnd.randint(1, args.venues)
            d = start + dt.timedelta(days=rnd.randint(0, span - 1))
            if (vid, d) not in taken:
                taken.add((vid, d))
                break
        # Bigger rooms charge more; keep it loosely tied to capacity.
        cap = capacity_of[vid]
        base = 8 + cap / 90.0
        door_price = round(max(5.0, rnd.gauss(base, base * 0.25)), 2)
        gig_rows.append([str(gid), str(vid), q(d.isoformat()), money(door_price)])
        gigs.append((gid, vid, d, door_price))
    emit("gig", ["gig_id", "venue_id", "gig_date", "door_price"], gig_rows, out)

    # ---- earnings reports --------------------------------------------------
    # Per gig: always a headliner; an opener 35% of the time; a promoter 25%.
    # Expected ~1.6 reports/gig.
    report_cols = ["party_id", "gig_id", "reporter_role", "agreed_guarantee",
                   "door_split_pct", "door_revenue", "merch_sales", "venue_fee",
                   "technician_fees", "additional_expenses", "attendance",
                   "net_payout", "currency", "submitted_at"]
    report_rows = []

    for gid, vid, d, door_price in gigs:
        cap = capacity_of[vid]
        # Ground truth for the night; each party reports its own view of it.
        true_att = max(1, int(cap * rnd.triangular(0.12, 1.0, 0.55)))
        gross = round(true_att * door_price * rnd.uniform(0.80, 1.0), 2)  # comps/guests
        venue_fee = round(max(0.0, rnd.gauss(cap * 0.9, cap * 0.3)), 2)
        tech_fees = round(max(0.0, rnd.gauss(cap * 0.35, cap * 0.15)), 2)
        filed = d + dt.timedelta(days=rnd.randint(1, 21))
        submitted = f"{filed.isoformat()} {rnd.randint(9,23):02d}:{rnd.randint(0,59):02d}:00"

        parties = [(rnd.choice(act_ids), "headliner")]
        if rnd.random() < 0.35:
            opener = rnd.choice(act_ids)
            if opener != parties[0][0]:                 # UNIQUE(party_id, gig_id)
                parties.append((opener, "support"))
        if rnd.random() < 0.25:
            parties.append((rnd.choice(promo_ids), "promoter"))

        for pid, role in parties:
            # Reporters disagree: each sees attendance a few percent off.
            att = max(1, int(true_att * rnd.uniform(0.93, 1.07)))
            revenue = round(gross * rnd.uniform(0.97, 1.03), 2)

            if role == "headliner":
                split = round(rnd.uniform(50, 80), 2)
                guar = round(rnd.choice([0, 0, 1]) * rnd.uniform(150, 1500), 2)
                merch = round(max(0.0, rnd.gauss(att * 2.2, att * 1.1)), 2)
                extra = round(max(0.0, rnd.gauss(cap * 0.2, cap * 0.1)), 2)
                payout = max(guar, revenue * split / 100.0) + merch - extra
                row = [str(pid), str(gid), q(role), money(guar), money(split),
                       money(revenue), money(merch), money(venue_fee),
                       money(tech_fees), money(extra), str(att),
                       money(round(max(0.0, payout), 2)), q("CAD"), q(submitted)]
            elif role == "support":
                split = round(rnd.uniform(15, 40), 2)
                guar = round(rnd.choice([0, 0, 0, 1]) * rnd.uniform(50, 400), 2)
                merch = round(max(0.0, rnd.gauss(att * 0.9, att * 0.6)), 2)
                payout = max(guar, revenue * split / 100.0) + merch
                # An opener usually does not know the venue-side numbers.
                knows = rnd.random() < 0.25
                row = [str(pid), str(gid), q(role), money(guar), money(split),
                       money(revenue), money(merch),
                       money(venue_fee if knows else None),
                       money(tech_fees if knows else None),
                       money(None), str(att),
                       money(round(max(0.0, payout), 2)), q("CAD"), q(submitted)]
            else:  # promoter — reports its own margin, not a performer's take
                extra = round(max(0.0, rnd.gauss(cap * 1.1, cap * 0.4)), 2)
                margin = revenue - venue_fee - tech_fees - extra
                row = [str(pid), str(gid), q(role), money(None), money(None),
                       money(revenue), money(None), money(venue_fee),
                       money(tech_fees), money(extra), str(att),
                       money(round(margin, 2)), q("CAD"), q(submitted)]
            report_rows.append(row)

    emit("earnings_report", report_cols, report_rows, out)
    out.write("COMMIT;\n")

    print(f"generated: {len(venues)} venues, {len(mus_rows)} musicians, "
          f"{len(act_rows)} acts, {len(promo_rows)} promoters, "
          f"{len(member_rows)} memberships, {len(gig_rows)} gigs, "
          f"{len(report_rows)} earnings reports", file=sys.stderr)


if __name__ == "__main__":
    main()

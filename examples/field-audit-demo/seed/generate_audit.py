#!/usr/bin/env python3
"""Generate the seeded audit: audit.json plus one JPEG per photo.

Every photo is a different framing of an openly licensed source picture
(see fetch_sources.py and CREDITS.md): a wide shot, a closer shot and detail
shots, the way an auditor photographs a finding. Each frame is resized to a
4:3 phone-camera resolution, given light sensor noise and saved as JPEG with
the quality tuned so the file lands near a target size. With the defaults the
audit has 336 photos and about 418 MB, the same volume as the stress test in
the article.

Outputs (git-ignored):
  out/photos/<photoId>.jpg   full-size photos, pushed to the device
  out/thumbs/<photoId>.jpg   480 px thumbnails, pushed next to them
  ../app/src/data/audit.json audit, areas, findings and photo metadata (committed)
"""
import argparse
import datetime as dt
import io
import json
import os
import random

import numpy as np
from PIL import Image, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "sources")
OUT = os.path.join(HERE, "out")
APP_DATA = os.path.join(HERE, "..", "app", "src", "data", "audit.json")

# Sources that were downloaded but are off-topic for a plant audit
# (museum displays, buildings, people, historic prints, aircraft panels).
EXCLUDE = {
    1, 2, 8, 9, 13, 15, 16, 17, 26, 29, 30, 31, 38, 40, 41, 43, 44, 45, 47, 48,
    57, 58, 60, 61, 70, 71, 72, 81, 82, 83, 84, 85, 87, 88, 89, 91, 93, 94, 97,
    98, 99, 68, 73,
}

# Which source categories can illustrate each audit area.
AREA_POOLS = {
    "pump-house": ["pumps", "piping"],
    "pipe-rack": ["piping"],
    "tank-farm": ["tanks", "piping"],
    "electrical": ["electrical"],
    "boiler-house": ["utilities", "piping"],
    "production": ["production", "structure"],
    "warehouse": ["warehouse"],
    "emergency": ["safety"],
}

AREAS = [
    ("pump-house", "Pump House P-100", "Building 4, ground floor", [
        ("Mechanical seal leak on pump P-104B", "major", "Product weeping at the seal gland, drip tray half full. Seal flush pressure below the value on the datasheet.", 11),
        ("Coupling guard missing on pump P-102A", "critical", "Guard removed during last maintenance and not refitted. Rotating coupling exposed at walkway height.", 9),
        ("Pressure gauge PI-1041 unreadable", "minor", "Gauge glass cracked and face fogged. Reading cannot be confirmed during rounds.", 5),
        ("Corrosion at baseplate anchor bolts", "minor", "Surface rust and section loss on two of four anchor bolts of P-103.", 7),
        ("Vibration route tags out of date", "observation", "Route tags show readings from the previous quarter. Data in the CMMS is current.", 4),
    ]),
    ("pipe-rack", "Pipe Rack A", "Between Units 2 and 3, elevation +6 m", [
        ("External corrosion at support shoe, line 6\"-P-2104", "major", "Pitting where the pipe rests on the shoe. Wall loss suspected, UT thickness check requested.", 12),
        ("Damaged and wet insulation on steam line", "major", "Cladding split over 1.5 m, insulation saturated. Risk of corrosion under insulation.", 10),
        ("Short bolt engagement on flange FL-2231", "minor", "Two studs do not show full thread engagement through the nut.", 6),
        ("Handwheel missing on isolation valve HV-2210", "minor", "Valve operated with a cheater bar. Handwheel found on the rack floor.", 5),
        ("Faded line identification labels", "observation", "Flow direction and service labels illegible on four lines near the battery limit.", 6),
        ("Temporary hose left connected", "major", "Utility hose connected to a drain point with no tag or permit reference.", 7),
    ]),
    ("tank-farm", "Tank Farm", "Bund 3, tanks T-301 to T-304", [
        ("Crack in bund wall near drain valve", "major", "Vertical crack about 40 cm long. Bund integrity cannot be guaranteed until repaired.", 9),
        ("Bund drain valve found open", "critical", "Drain valve DV-31 open with no one attending. Closed and locked on the spot, reported to the shift lead.", 6),
        ("Level gauge on T-301 differs from DCS", "minor", "Local gauge reads 62%, DCS shows 58%. Calibration requested.", 5),
        ("Vent screen clogged on T-303", "minor", "Bird debris on the vent screen. Risk of vacuum during pump-out.", 6),
        ("Coating breakdown on lower shell course", "observation", "Coating failure in patches on the north side. No active corrosion yet.", 8),
    ]),
    ("electrical", "Substation and MCC Room", "Building 7, MCC-2", [
        ("Overfilled cable tray", "minor", "Cables above the tray side rails along 3 m of the main run.", 7),
        ("Panel door left open on MCC-2 section 4", "major", "Door open with the latch broken. Enclosure rating compromised.", 6),
        ("Missing fire stopping at cable penetration", "major", "Wall penetration between MCC room and corridor not sealed.", 8),
        ("No arc flash labels on switchgear SG-02", "major", "Incident energy and PPE category labels missing on three cubicles.", 7),
        ("Hot spot on breaker Q12 terminals", "critical", "Thermography shows 38 degrees C above ambient on phase L2. Load to be reduced until repaired.", 10),
        ("Materials stored in front of panels", "minor", "Spare parts boxes blocking the 1 m clearance in front of MCC-2.", 5),
    ]),
    ("boiler-house", "Boiler House", "Building 2", [
        ("Steam trap failed open", "minor", "Trap ST-118 discharging live steam to drain.", 5),
        ("Safety valve certificate expired", "major", "PSV-201 test certificate expired three weeks ago. No extension on file.", 6),
        ("Water treatment log incomplete", "observation", "Daily conductivity readings missing for two days last week.", 4),
        ("Missing insulation on steam header", "minor", "Bare section of about 2 m on the main header, burn risk at shoulder height.", 7),
    ]),
    ("production", "Production Hall, Line 2", "Building 5", [
        ("Emergency pull-cord slack on conveyor C-204", "critical", "Pull-cord sags about 30 cm between supports. Stop switch did not trip on test.", 10),
        ("Guarding gap at conveyor tail pulley", "major", "Gap of about 15 cm between guard and frame at the tail pulley.", 8),
        ("Hydraulic oil leak under press PR-2", "minor", "Oil on the floor around the press base, absorbent applied.", 6),
        ("Damaged floor at walkway crossing", "minor", "Broken concrete edge at the forklift crossing. Trip hazard.", 6),
        ("Loose handrail on access stairway", "major", "Two handrail brackets loose on the mezzanine stairs.", 7),
        ("Corrosion at column base, grid line C4", "minor", "Paint loss and surface corrosion at the base plate of the column.", 8),
    ]),
    ("warehouse", "Warehouse and Dispatch", "Building 9", [
        ("Damaged racking upright, aisle 6", "critical", "Upright bent at the first beam level after an impact. Bay not offloaded.", 11),
        ("Rack load signs missing", "minor", "Safe working load signs missing at the ends of aisles 3 and 4.", 5),
        ("No eyewash at forklift charging area", "major", "Battery charging area has no eyewash station within 10 m.", 6),
        ("Worn pedestrian walkway markings", "minor", "Yellow walkway lines worn through at the dispatch doors.", 7),
        ("Pallets stored in fire exit route", "major", "Two pallets blocking the exit route to door D-4.", 6),
    ]),
    ("emergency", "Emergency Equipment", "Site wide", [
        ("Extinguisher inspection overdue", "minor", "Extinguisher FE-117 last inspected 14 months ago.", 6),
        ("Safety shower flow test not recorded", "major", "No weekly flow test records for the shower at the acid unloading point.", 8),
        ("Exit sign not illuminated", "minor", "Exit sign above door D-2 not lit. Emergency lighting test due.", 5),
        ("Fire hose reel obstructed", "major", "Hose reel HR-05 blocked by stored drums.", 7),
        ("Emergency station complete and in good order", "observation", "Station at the tank farm entrance checked, all items present and tagged.", 8),
    ]),
]

AUDIT = {
    "id": "AUD-2026-0418",
    "title": "Annual Mechanical Integrity Audit",
    "site": "Northgate Process Plant",
    "unit": "Units 2 to 5",
    "client": "Northgate Chemicals",
    "auditor": "Marta Lopes",
    "date": "2026-10-01",
    "status": "Ready to sync",
}

# Two smaller audits so the list screen is not a single card. They are
# already synced and carry no photos on the device.
OTHER_AUDITS = [
    {"id": "AUD-2026-0397", "title": "Contractor Safety Walkdown", "site": "Northgate Process Plant", "unit": "Unit 3",
     "auditor": "Marta Lopes", "date": "2026-09-17", "status": "Synced", "findingCount": 14, "photoCount": 61, "totalBytes": 74_100_000},
    {"id": "AUD-2026-0362", "title": "Quarterly Fire Equipment Check", "site": "Riverside Logistics Hub", "unit": "Warehouse A",
     "auditor": "Marta Lopes", "date": "2026-09-02", "status": "Synced", "findingCount": 9, "photoCount": 27, "totalBytes": 31_800_000},
]


def scale_counts(target):
    """Scale the per-finding photo counts above so they add up to target."""
    flat = [(ai, fi, f[3]) for ai, a in enumerate(AREAS) for fi, f in enumerate(a[3])]
    total = sum(n for *_, n in flat)
    exact = [(ai, fi, n * target / total) for ai, fi, n in flat]
    counts = {(ai, fi): int(x) for ai, fi, x in exact}
    rest = target - sum(counts.values())
    for ai, fi, x in sorted(exact, key=lambda e: e[2] - int(e[2]), reverse=True)[:rest]:
        counts[(ai, fi)] += 1
    for ai, a in enumerate(AREAS):
        a[3][:] = [(t, s, note, counts[(ai, fi)]) for fi, (t, s, note, _) in enumerate(a[3])]


def framings(rng, img, n):
    """Yield n crops of img: a wide shot first, then progressively tighter ones."""
    W, H = img.size
    for i in range(n):
        if i == 0:
            scale = rng.uniform(0.88, 1.0)
        elif i < 3:
            scale = rng.uniform(0.6, 0.8)
        else:
            scale = rng.uniform(0.38, 0.6)
        cw = W * scale
        ch = cw * 3 / 4
        if ch > H:
            ch = H * rng.uniform(0.9, 1.0)
            cw = ch * 4 / 3
        x = rng.uniform(0, W - cw)
        y = rng.uniform(0, H - ch)
        crop = img.crop((int(x), int(y), int(x + cw), int(y + ch)))
        if rng.random() < 0.5:
            crop = crop.rotate(rng.uniform(-2.5, 2.5), resample=Image.BICUBIC, expand=False)
            # trim the rotated borders
            m = int(cw * 0.03)
            crop = crop.crop((m, m * 3 // 4, crop.width - m, crop.height - m * 3 // 4))
        yield crop


def finish(rng, crop, size):
    img = crop.resize(size, Image.LANCZOS)
    img = ImageEnhance.Brightness(img).enhance(rng.uniform(0.92, 1.08))
    img = ImageEnhance.Contrast(img).enhance(rng.uniform(0.95, 1.08))
    img = ImageEnhance.Color(img).enhance(rng.uniform(0.9, 1.1))
    arr = np.asarray(img).astype(np.int16)
    noise = np.random.default_rng(rng.randrange(1 << 30)).normal(0, rng.uniform(2.5, 4.0), arr.shape[:2])
    arr = np.clip(arr + noise[..., None], 0, 255).astype(np.uint8)
    return Image.fromarray(arr)


def encode_to_target(img, target):
    lo, hi, best = 60, 97, None
    while lo <= hi:
        q = (lo + hi) // 2
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=q, optimize=True)
        data = buf.getvalue()
        best = data if best is None or abs(len(data) - target) < abs(len(best) - target) else best
        if len(data) > target:
            hi = q - 1
        else:
            lo = q + 1
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--total-mb", type=float, default=418.0)
    ap.add_argument("--width", type=int, default=3264)
    ap.add_argument("--seed", type=int, default=418)
    ap.add_argument("--photos", type=int, default=336)
    args = ap.parse_args()
    scale_counts(args.photos)

    rng = random.Random(args.seed)
    manifest = json.load(open(os.path.join(SRC, "manifest.json")))
    by_cat = {}
    for m in manifest:
        if int(m["file"][4:7]) in EXCLUDE:
            continue
        by_cat.setdefault(m["area"], []).append(m)

    total_photos = sum(f[3] for a in AREAS for f in a[3])
    target_mean = args.total_mb * 1e6 / total_photos
    size = (args.width, args.width * 3 // 4)

    os.makedirs(os.path.join(OUT, "photos"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "thumbs"), exist_ok=True)

    used_sources = {}
    areas_out = []
    clock = dt.datetime(2026, 10, 1, 8, 42, 10)
    photo_seq = 0
    finding_seq = 0
    for area_key, area_name, location, findings in AREAS:
        pool = [m for cat in AREA_POOLS[area_key] for m in by_cat.get(cat, [])]
        rng.shuffle(pool)
        pool_idx = 0
        area_out = {"id": area_key, "name": area_name, "location": location, "findings": []}
        for title, severity, note, n in findings:
            finding_seq += 1
            fid = f"F-{finding_seq:02d}"
            # one or two source scenes per finding
            scenes = [pool[pool_idx % len(pool)]]
            pool_idx += 1
            if n >= 8:
                scenes.append(pool[pool_idx % len(pool)])
                pool_idx += 1
            photos = []
            per_scene = [n // len(scenes) + (1 if i < n % len(scenes) else 0) for i in range(len(scenes))]
            for scene, count in zip(scenes, per_scene):
                used_sources[scene["file"]] = scene
                src = Image.open(os.path.join(SRC, scene["file"])).convert("RGB")
                for crop in framings(rng, src, count):
                    photo_seq += 1
                    clock += dt.timedelta(seconds=rng.randint(9, 75))
                    pid = f"{AUDIT['id']}-{fid}-{len(photos) + 1:02d}"
                    fname = f"IMG_{clock:%Y%m%d_%H%M%S}.jpg"
                    img = finish(rng, crop, size)
                    target = max(0.6, rng.gauss(1.0, 0.12)) * target_mean
                    data = encode_to_target(img, target)
                    with open(os.path.join(OUT, "photos", f"{pid}.jpg"), "wb") as f:
                        f.write(data)
                    thumb = img.copy()
                    thumb.thumbnail((480, 360))
                    thumb.save(os.path.join(OUT, "thumbs", f"{pid}.jpg"), "JPEG", quality=78)
                    photos.append({
                        "id": pid,
                        "file": f"{pid}.jpg",
                        "name": fname,
                        "bytes": len(data),
                        "takenAt": clock.isoformat(),
                        "source": scene["file"],
                    })
                    print(f"{photo_seq:3d} {pid} {len(data) / 1e6:.2f} MB")
            area_out["findings"].append({
                "id": fid,
                "title": title,
                "severity": severity,
                "note": note,
                "photos": photos,
            })
            clock += dt.timedelta(minutes=rng.randint(2, 9))
        areas_out.append(area_out)
        clock += dt.timedelta(minutes=rng.randint(8, 20))

    all_photos = [p for a in areas_out for f in a["findings"] for p in f["photos"]]
    audit = dict(AUDIT,
                 findingCount=finding_seq,
                 photoCount=len(all_photos),
                 totalBytes=sum(p["bytes"] for p in all_photos),
                 areas=areas_out)
    os.makedirs(os.path.dirname(APP_DATA), exist_ok=True)
    with open(APP_DATA, "w") as f:
        json.dump({"audits": [audit] + OTHER_AUDITS}, f, indent=1)

    credits = sorted(used_sources.values(), key=lambda m: m["file"])
    with open(os.path.join(HERE, "credits.json"), "w") as f:
        json.dump(credits, f, indent=2)
    print(f"{len(all_photos)} photos, {audit['totalBytes'] / 1e6:.1f} MB, {len(credits)} source pictures")


if __name__ == "__main__":
    main()

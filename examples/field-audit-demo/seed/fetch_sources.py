#!/usr/bin/env python3
"""Download openly licensed industrial photos from Wikimedia Commons.

These are the source pictures for the seeded audit. By default this downloads
the exact files pinned in sources.json (the list the committed audit.json and
CREDITS.md were built from), so the 336 photos can be rebuilt as they were.
Commons search results change over time, so searching again picks different
pictures.

--search runs the original discovery instead: it searches Commons, keeps only
files whose licence is CC0, Public Domain, CC BY or CC BY-SA, and records each
one (title, author, licence, page URL) so CREDITS.md can be regenerated. Its
results no longer match audit.json or the EXCLUDE list in generate_audit.py.

Either way the list is written to sources/manifest.json, which
generate_audit.py reads. The downloads themselves are not committed.

Usage: python3 fetch_sources.py              # pinned list (sources.json)
       python3 fetch_sources.py --search [--target 64]
"""
import argparse
import json
import os
import re
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "sources")
PINNED = os.path.join(HERE, "sources.json")
API = "https://commons.wikimedia.org/w/api.php"
UA = "field-audit-demo/1.0 (https://hfps.dev; demo seed data)"

# Each query maps to the audit area the pictures will illustrate.
QUERIES = [
    ("corroded pipe flange", "piping"),
    ("rusty pipes industrial", "piping"),
    ("industrial valve", "piping"),
    ("pressure gauge industrial", "piping"),
    ("centrifugal pump industrial", "pumps"),
    ("air compressor industrial", "pumps"),
    ("electrical cabinet industrial", "electrical"),
    ("cable tray", "electrical"),
    ("switchgear", "electrical"),
    ("fire extinguisher wall", "safety"),
    ("emergency exit sign factory", "safety"),
    ("safety shower eyewash", "safety"),
    ("storage tank industrial", "tanks"),
    ("steel structure rust", "structure"),
    ("industrial staircase steel", "structure"),
    ("factory interior machinery", "production"),
    ("conveyor belt factory", "production"),
    ("boiler room", "utilities"),
    ("forklift warehouse", "warehouse"),
    ("pallet racking warehouse", "warehouse"),
    ("electrical panel breakers", "electrical"),
    ("fire hose reel", "safety"),
    ("pipe insulation industrial", "piping"),
    ("handwheel valve pipe", "piping"),
    ("chemical plant pipes", "piping"),
    ("electric motor industrial", "pumps"),
    ("hydraulic hoses machine", "production"),
    ("bolted flange", "piping"),
    ("corrosion steel", "structure"),
    ("industrial floor cracks", "structure"),
]

OK_LICENCES = re.compile(r"^(CC0|Public domain|PD|CC BY(-SA)? [0-9.]+)", re.I)
SKIP_TITLES = re.compile(r"panorama|hdr|preview|map|diagram|logo|drawing|svg|scan|poster|stamp|\.tif", re.I)


def api(params):
    params = dict(params, format="json")
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def strip_html(s):
    return re.sub(r"<[^>]+>", "", s or "").strip()


def search(query, limit=25):
    data = api({
        "action": "query",
        "generator": "search",
        "gsrnamespace": 6,
        "gsrsearch": f"{query} filetype:bitmap",
        "gsrlimit": limit,
        "prop": "imageinfo",
        "iiprop": "url|size|mime|extmetadata",
        "iiextmetadatafilter": "LicenseShortName|Artist",
        "iiurlwidth": 2400,
    })
    pages = (data.get("query") or {}).get("pages") or {}
    return sorted(pages.values(), key=lambda p: p.get("index", 0))


def download(url, fname):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=120) as r, open(os.path.join(OUT, fname), "wb") as f:
        f.write(r.read())


def fetch_pinned():
    """Download every file in sources.json under its pinned name."""
    os.makedirs(OUT, exist_ok=True)
    pinned = json.load(open(PINNED))
    missing = []
    for i in range(0, len(pinned), 50):
        batch = pinned[i:i + 50]
        data = api({
            "action": "query",
            "titles": "|".join(m["title"] for m in batch),
            "prop": "imageinfo",
            "iiprop": "url",
            "iiurlwidth": 2400,
        })
        query = data.get("query") or {}
        # The API returns normalized titles; map them back to the pinned ones.
        norm = {n["to"]: n["from"] for n in query.get("normalized") or []}
        urls = {}
        for page in (query.get("pages") or {}).values():
            info = (page.get("imageinfo") or [{}])[0]
            if info.get("thumburl"):
                urls[norm.get(page["title"], page["title"])] = info["thumburl"]
        for m in batch:
            path = os.path.join(OUT, m["file"])
            if os.path.exists(path) and os.path.getsize(path) > 0:
                continue
            url = urls.get(m["title"])
            try:
                if not url:
                    raise RuntimeError("not found on Commons")
                download(url, m["file"])
                print(f"{m['file']}  [{m['licence']}]  {m['title']}")
                time.sleep(0.5)
            except Exception as e:
                print("download failed", m["file"], m["title"], e)
                missing.append(m["file"])
    json.dump(pinned, open(os.path.join(OUT, "manifest.json"), "w"), indent=2)
    print(f"{len(pinned) - len(missing)} of {len(pinned)} pinned source photos in {OUT}")
    if missing:
        raise SystemExit(f"missing: {', '.join(missing)} (run again to retry)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--search", action="store_true", help="search Commons instead of using sources.json")
    ap.add_argument("--target", type=int, default=64)
    ap.add_argument("--per-query", type=int, default=4)
    args = ap.parse_args()
    if not args.search:
        return fetch_pinned()

    os.makedirs(OUT, exist_ok=True)
    manifest_path = os.path.join(OUT, "manifest.json")
    manifest = json.load(open(manifest_path)) if os.path.exists(manifest_path) else []
    have = {m["title"] for m in manifest}

    for query, area in QUERIES:
        if len(manifest) >= args.target:
            break
        taken = 0
        try:
            results = search(query)
        except Exception as e:  # network hiccup, keep going with the next query
            print("search failed", query, e)
            continue
        for page in results:
            if taken >= args.per_query or len(manifest) >= args.target:
                break
            title = page["title"]
            if title in have or SKIP_TITLES.search(title):
                continue
            info = (page.get("imageinfo") or [{}])[0]
            if info.get("mime") != "image/jpeg":
                continue
            w, h = info.get("width", 0), info.get("height", 0)
            if w < 2000 or h < 1300 or not (1.2 <= w / max(h, 1) <= 1.8):
                continue
            meta = info.get("extmetadata") or {}
            licence = strip_html((meta.get("LicenseShortName") or {}).get("value"))
            if not OK_LICENCES.match(licence):
                continue
            artist = strip_html((meta.get("Artist") or {}).get("value")) or "Unknown"
            thumb = info.get("thumburl")
            if not thumb:
                continue
            fname = f"src_{len(manifest) + 1:03d}.jpg"
            try:
                download(thumb, fname)
            except Exception as e:
                print("download failed", title, e)
                continue
            manifest.append({
                "file": fname,
                "area": area,
                "title": title,
                "author": artist,
                "licence": licence,
                "page": info.get("descriptionurl"),
            })
            have.add(title)
            taken += 1
            print(f"{fname}  [{licence}]  {title}")
            json.dump(manifest, open(manifest_path, "w"), indent=2)
            time.sleep(0.5)

    print(f"{len(manifest)} source photos in {OUT}")


if __name__ == "__main__":
    main()

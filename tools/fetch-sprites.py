#!/usr/bin/env python3
"""Download the buddy sprite sheets from PMDCollab/SpriteCollab.

Writes one directory per sprite set under forms/ (normal sheets, plus shiny
ones in forms/<name>/shiny/ when SpriteCollab has them), forms/forms.json with
the per-set frame data the QML side needs, and forms/species.json listing the
Pokémon you can pick in the settings. Eevee's evolutions are sprite sets too,
but not pickable species: she evolves into them on her own.

Also writes CREDITS.md at the plugin root: the sprites are CC BY-NC 4.0 and
every artist has to be credited.

Run it again after editing SPECIES or EEVEELUTIONS (--credits only rewrites
CREDITS.md)."""
import io, json, pathlib, sys, urllib.error, urllib.request, xml.etree.ElementTree as ET

REPO = "https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master"
BASE = f"{REPO}/sprite"
# Pickable buddies: name -> (dex number, display name)
SPECIES = {
    "eevee": ("0133", "Eevee"), "pikachu": ("0025", "Pikachu"),
    "charmander": ("0004", "Charmander"), "bulbasaur": ("0001", "Bulbasaur"),
    "squirtle": ("0007", "Squirtle"), "psyduck": ("0054", "Psyduck"),
    "munchlax": ("0446", "Munchlax"), "snorlax": ("0143", "Snorlax"),
    "gengar": ("0094", "Gengar"),
}
EEVEELUTIONS = {"vaporeon": "0134", "jolteon": "0135", "flareon": "0136",
                "espeon": "0196", "umbreon": "0197", "leafeon": "0470",
                "glaceon": "0471", "sylveon": "0700"}
# Later evolution stages, reached by levelling up (see bin/eevee-brain).
STAGES = {"charmeleon": ("0005", "Charmeleon"), "charizard": ("0006", "Charizard"),
          "ivysaur": ("0002", "Ivysaur"), "venusaur": ("0003", "Venusaur"),
          "wartortle": ("0008", "Wartortle"), "blastoise": ("0009", "Blastoise"),
          "raichu": ("0026", "Raichu"), "golduck": ("0055", "Golduck")}
ANIMS = ["Walk", "Idle", "Sleep", "Hop", "Eat", "Sit", "Nod", "LookUp", "Pose", "Charge", "Shoot", "Attack"]
LOOPS = {"Walk", "Idle", "Sleep", "Nod"}
out_dir = pathlib.Path(__file__).resolve().parent.parent / "forms"


def get(url):
    try:
        with urllib.request.urlopen(url) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def fetch(name, num):
    d = out_dir / name
    d.mkdir(parents=True, exist_ok=True)
    root = ET.fromstring(get(f"{BASE}/{num}/AnimData.xml"))
    by_name = {a.findtext("Name"): a for a in root.iter("Anim")}
    specs = {}
    for anim in ANIMS:
        a = by_name.get(anim)
        if a is None:
            continue
        src = a.findtext("CopyOf") or anim
        a2 = by_name[src]
        png = get(f"{BASE}/{num}/{src}-Anim.png")
        if png is None:
            continue
        (d / f"{anim}.png").write_bytes(png)
        shiny = get(f"{BASE}/{num}/0000/0001/{src}-Anim.png")
        if shiny is not None:
            (d / "shiny").mkdir(exist_ok=True)
            (d / "shiny" / f"{anim}.png").write_bytes(shiny)
        from PIL import Image
        im = Image.open(io.BytesIO(png)).convert("RGBA")
        w, h = int(a2.findtext("FrameWidth")), int(a2.findtext("FrameHeight"))
        rows = im.height // h
        # Feet: lowest opaque pixel of the first frame, measured from centre.
        row = 2 if rows == 8 else 0
        bbox = im.crop((0, row * h, w, row * h + h)).getbbox() or (0, 0, w, h)
        specs[anim] = {"w": w, "h": h, "rows": rows,
                       "d": [int(x.text) for x in a2.iter("Duration")],
                       "loop": anim in LOOPS, "foot": bbox[3] - h // 2,
                       "bodyW": bbox[2] - bbox[0]}
    print(name, ", ".join(specs), "(+shiny)" if (d / "shiny").is_dir() else "")
    return specs


def authors(path):
    """Credit ids from a SpriteCollab credits.txt (2nd column), in order."""
    text = get(f"{BASE}/{path}/credits.txt")
    ids = []
    for line in (text or b"").decode().splitlines():
        cols = line.split("\t")
        if len(cols) > 1 and cols[1] not in ids:
            ids.append(cols[1])
    return ids


def write_credits():
    names = {}
    for line in get(f"{REPO}/credit_names.txt").decode().splitlines()[1:]:
        cols = line.split("\t")
        if len(cols) >= 2:
            names[cols[1]] = (cols[0], cols[2] if len(cols) > 2 else "")

    def who(ids):
        out = []
        for i in ids:
            name, contact = names.get(i, (i, ""))
            out.append(f"[{name}]({contact})" if contact.startswith("http") else name)
        return ", ".join(out) or "unknown"

    rows = []
    sets = ([(k, v[0], v[1]) for k, v in SPECIES.items()] + [(k, v, k.capitalize()) for k, v in EEVEELUTIONS.items()]
            + [(k, v[0], v[1]) for k, v in STAGES.items()])
    for name, num, label in sets:
        rows.append(f"| {label} | #{int(num)} | {who(authors(num))} | {who(authors(f'{num}/0000/0001'))} |")
        print("credits", name)
    (out_dir.parent / "CREDITS.md").write_text(
        "# Sprite credits\n\n"
        "All sprites come from the [PMD Sprite Repository](https://sprites.pmdcollab.org/) "
        "([PMDCollab/SpriteCollab](https://github.com/PMDCollab/SpriteCollab)), used under "
        "[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/): non-commercial use, with credit. "
        "CHUNSOFT sprites are the originals from the Pokémon Mystery Dungeon games.\n\n"
        "Pokémon and all related names are trademarks of Nintendo, Creatures Inc. and GAME FREAK inc. "
        "This is an unofficial fan project, not affiliated with or endorsed by them.\n\n"
        "| Pokémon | Dex | Sprites by | Shiny sprites by |\n|---|---|---|---|\n"
        + "\n".join(rows) + "\n\n"
        "Generated by `tools/fetch-sprites.py` from SpriteCollab's credits files.\n")


if "--credits" not in sys.argv:
    meta = {}
    for name, (num, _label) in SPECIES.items():
        meta[name] = fetch(name, num)
    for name, num in EEVEELUTIONS.items():
        meta[name] = fetch(name, num)
    for name, (num, _label) in STAGES.items():
        meta[name] = fetch(name, num)
    (out_dir / "forms.json").write_text(json.dumps(meta, indent=1) + "\n")
    (out_dir / "species.json").write_text(json.dumps(
        [{"id": k, "label": v[1], "evolves": k == "eevee"} for k, v in SPECIES.items()], indent=1) + "\n")
    (out_dir / "labels.json").write_text(json.dumps(
        {**{k: v[1] for k, v in SPECIES.items()}, **{k: k.capitalize() for k in EEVEELUTIONS},
         **{k: v[1] for k, v in STAGES.items()}}, indent=1) + "\n")
write_credits()

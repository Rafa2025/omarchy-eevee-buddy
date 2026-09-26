#!/usr/bin/env python3
"""Find installed desktop apps for Eevee.

  eevee-apps.py find <query>   best matches as JSON lines, best first
  eevee-apps.py list [filter]  "id<TAB>name<TAB>generic" for every visible app
"""
import configparser, difflib, json, os, pathlib, re, sys

def app_dirs():
    home = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
    dirs = [home] + os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
    dirs += [os.path.expanduser("~/.local/share/flatpak/exports/share"), "/var/lib/flatpak/exports/share"]
    seen = []
    for d in dirs:
        p = pathlib.Path(d) / "applications"
        if p.is_dir() and p not in seen:
            seen.append(p)
    return seen

def load_apps():
    apps, ids = [], set()
    for base in app_dirs():  # earlier dirs win, like XDG lookup
        for f in sorted(base.rglob("*.desktop")):
            app_id = str(f.relative_to(base)).replace("/", "-")
            if app_id in ids:
                continue
            ids.add(app_id)
            cp = configparser.RawConfigParser(strict=False, interpolation=None)
            try:
                cp.read(f, encoding="utf-8")
                e = cp["Desktop Entry"]
            except Exception:
                continue
            if e.get("Type", "Application") != "Application":
                continue
            if e.get("NoDisplay", "false").lower() == "true" or e.get("Hidden", "false").lower() == "true":
                continue
            apps.append({
                "id": app_id,
                "name": e.get("Name", app_id[:-8]),
                "generic": e.get("GenericName", ""),
                "keywords": e.get("Keywords", ""),
                "categories": e.get("Categories", ""),
                "comment": e.get("Comment", ""),
                "wmclass": e.get("StartupWMClass", ""),
                "exec": e.get("Exec", ""),
                "terminal": e.get("Terminal", "false").lower() == "true",
            })
    return apps

def norm(s):
    return re.sub(r"[^a-z0-9 ]+", " ", s.lower()).strip()

def score(app, q):
    name, stem = norm(app["name"]), norm(app["id"][:-8].split(".")[-1])
    exe = norm(os.path.basename(app["exec"].split()[0])) if app["exec"] else ""
    if q in (name, stem, exe):
        return 100
    if name.startswith(q) or stem.startswith(q):
        return 85
    if re.search(r"\b" + re.escape(q), name):
        return 75
    extra = norm(" ".join([app["generic"], app["keywords"].replace(";", " "), app["categories"].replace(";", " ")]))
    if q in extra.split() or re.search(r"\b" + re.escape(q) + r"\b", extra):
        return 55
    if q in name or q in stem:
        return 50
    r = max(difflib.SequenceMatcher(None, q, name).ratio(), difflib.SequenceMatcher(None, q, stem).ratio())
    return int(r * 60) if r >= 0.75 else 0

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    arg = norm(" ".join(sys.argv[2:]))
    apps = load_apps()
    if cmd == "find":
        q = re.sub(r"^(the|my|a|an) ", "", arg)
        q = re.sub(r" (app|application|program)$", "", q)
        ranked = sorted(((score(a, q), a) for a in apps), key=lambda t: -t[0])
        for s, a in ranked[:5]:
            if s > 0:
                print(json.dumps(dict(a, score=s)))
    else:
        for a in sorted(apps, key=lambda a: a["name"].lower()):
            line = f'{a["id"]}\t{a["name"]}\t{a["generic"]}'
            if not arg or arg in norm(line + " " + a["keywords"] + " " + a["categories"]):
                print(line)

main()

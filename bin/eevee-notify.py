#!/usr/bin/env python3
"""Watch desktop notifications for Eevee.

Omarchy's shell owns org.freedesktop.Notifications, so Eevee listens in on the
session bus (busctl monitor) and prints one JSON object per Notify call:

  {"app", "summary", "body", "urgency": 0|1|2, "replaces": id,
   "bypass": bool, "exec": "<omarchy-exec-argv JSON>", "desktop": "<entry>"}

"bypass" marks the ones Omarchy still pops up under Do Not Disturb
(omarchy-action toasts, critical notify-send), so Eevee can take them over.
"""
import html, json, re, subprocess, sys

MON = ["busctl", "--user", "monitor", "org.freedesktop.Notifications", "--json=short"]


def hint(hints, key):
    v = hints.get(key)
    return v.get("data") if isinstance(v, dict) else None


def clean(text):
    text = re.sub(r"<[^>]+>", "", str(text or ""))
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def main():
    proc = subprocess.Popen(MON, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    for line in proc.stdout:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("type") != "method_call" or msg.get("member") != "Notify":
            continue
        try:
            app, replaces, _icon, summary, body, _actions, hints, _timeout = msg["payload"]["data"]
        except (KeyError, ValueError):
            continue
        hints = hints if isinstance(hints, dict) else {}
        urgency = hint(hints, "urgency")
        urgency = urgency if urgency in (0, 1, 2) else 1
        print(json.dumps({
            "app": app or "",
            "summary": clean(summary),
            "body": clean(body)[:400],
            "urgency": urgency,
            "replaces": replaces or 0,
            "bypass": app == "omarchy-action" or (app == "notify-send" and urgency == 2),
            "exec": hint(hints, "omarchy-exec-argv") or "",
            "desktop": hint(hints, "desktop-entry") or "",
        }), flush=True)
    sys.exit(proc.wait())


main()

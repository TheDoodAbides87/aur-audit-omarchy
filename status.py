#!/usr/bin/env python3
"""Summarize aur-audit's state and saved reports as JSON for the Omarchy panel.

    status.py              print the summary
    status.py --mark-seen  remember that the user has looked at the panel, so
                           older blocked installs stop lighting up the bar icon

Only reads files; never runs aur-audit itself.
"""
import json
import os
import re
import shutil
import sys
import time

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"),
                         "aur-audit-omarchy")
SEEN_FILE = os.path.join(STATE_DIR, "seen")
HOOK = "/etc/pacman.d/hooks/01-aur-audit.hook"
YAY_CONFIG = os.path.join(HOME, ".config/yay/config.json")
MAX_REPORTS = 8
STAMP = r"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"

# What the panel may pass back to aur-audit. Package names follow pacman's
# rules; build directories must be plain paths. Anything else is dropped, so a
# crafted report can never smuggle shell syntax into a command.
SAFE_PKG = re.compile(r"^[a-z0-9@_+][a-z0-9@._+-]*$")
SAFE_PATH = re.compile(r"^[A-Za-z0-9@._+/~-]+$")

KINDS = [
    ("blocked", re.compile(rf"^aur-audit-blocked-{STAMP}\.txt$")),
    ("system-scan", re.compile(rf"^aur-audit-system-scan-{STAMP}\.txt$")),
    ("ai-system-review", re.compile(rf"^aur-audit-ai-system-review-{STAMP}\.txt$")),
    ("ai-review", re.compile(rf"^aur-audit-ai-review-(.+)-{STAMP}\.txt$")),
]


def read(path, limit=200_000):
    try:
        with open(path, errors="replace") as f:
            return f.read(limit)
    except OSError:
        return ""


def safe_target(target):
    if SAFE_PKG.match(target):
        return target
    if SAFE_PATH.match(target) and target.startswith("/") and ".." not in target:
        return target
    return ""


def parse_blocked(text):
    """Blocked packages and the target to hand `aur-audit ai` for each."""
    packages, current = [], None
    for line in text.splitlines():
        m = re.match(r"^==> aur-audit: (\S+)(?: (\S+))?\s*$", line)
        if m:
            current = {"name": m.group(1), "version": m.group(2) or "", "aiTarget": ""}
            continue
        if current is None:
            continue
        if "-> HAZARDOUS" in line:
            packages.append(current)
        m = re.match(r"^\s+aur-audit ai (\S+)\s*$", line)
        if m and packages and packages[-1] is current:
            current["aiTarget"] = safe_target(m.group(1))
    return [p for p in packages if SAFE_PKG.match(p["name"])]


def parse_scan(text):
    return {"serious": len(re.findall(r"\[SERIOUS\]", text)),
            "check": len(re.findall(r"\[CHECK\]", text))}


def parse_verdict(text):
    m = re.search(r"^\W*VERDICT:\s*(.+?)\W*$", text, re.M)
    return m.group(1).strip().upper() if m else ""


def describe(kind, path, match):
    text = read(path)
    entry = {"kind": kind, "path": path, "file": os.path.basename(path),
             "time": int(os.path.getmtime(path))}
    if kind == "blocked":
        packages = parse_blocked(text)
        entry["packages"] = packages
        names = ", ".join(p["name"] for p in packages) or "unknown package"
        entry["title"] = f"Blocked {names}"
        entry["detail"] = "Install cancelled"
    elif kind == "system-scan":
        counts = parse_scan(text)
        entry.update(counts)
        entry["title"] = "System scan"
        entry["detail"] = (f"{counts['serious']} serious, {counts['check']} to check"
                           if counts["serious"] or counts["check"] else "Nothing found")
    elif kind == "ai-system-review":
        entry["verdict"] = parse_verdict(text)
        entry["title"] = "AI system review"
        entry["detail"] = entry["verdict"].capitalize() or "See report"
    else:
        name = match.group(1)
        entry["verdict"] = parse_verdict(text)
        entry["title"] = f"AI review of {name}"
        entry["detail"] = entry["verdict"].capitalize() or "See report"
    return entry


def report_files(home=HOME):
    """(time, kind, path, match) for every aur-audit report in home, newest first."""
    found = []
    try:
        names = os.listdir(home)
    except OSError:
        return found
    for name in names:
        for kind, pattern in KINDS:
            m = pattern.match(name)
            if m:
                path = os.path.join(home, name)
                if os.path.isfile(path):
                    found.append((int(os.path.getmtime(path)), kind, path, m))
                break
    found.sort(key=lambda r: r[0], reverse=True)
    return found


def seen_time():
    try:
        return int(read(SEEN_FILE).strip() or 0)
    except ValueError:
        return 0


def yay_wrapper_on():
    try:
        with open(YAY_CONFIG) as f:
            return json.load(f).get("makepkgbin", "").endswith("aur-audit-makepkg")
    except (OSError, ValueError, AttributeError):
        return False


def summary(home=HOME):
    files = report_files(home)
    seen = seen_time()
    last_scan = next((describe(k, p, m) for _, k, p, m in files if k == "system-scan"), None)
    return {
        "installed": shutil.which("aur-audit") is not None,
        "hookInstalled": os.path.exists(HOOK),
        "yayWrapper": yay_wrapper_on(),
        "lastScan": last_scan,
        "newBlocks": sum(1 for t, k, _, _ in files if k == "blocked" and t > seen),
        "reportCount": len(files),
        "reports": [describe(k, p, m) for _, k, p, m in files[:MAX_REPORTS]],
    }


def mark_seen():
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(SEEN_FILE, "w") as f:
        f.write(str(int(time.time())))


def main(argv):
    if argv[1:] == ["--mark-seen"]:
        mark_seen()
        return 0
    print(json.dumps(summary()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

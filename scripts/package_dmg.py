#!/usr/bin/env python3
"""
Build the final DMG with both the .app and the ReadMe.txt visible.

For a release, do NOT run this directly: scripts/sign_and_notarize_macos.sh calls it at
the right point in the signing chain. The .app must already be signed *and* have its
notarization ticket stapled before the DMG is built, because the DMG cannot be touched
afterwards without invalidating its own signature and ticket.

Release flow (full runbook in .claude/skills/release-runbook, Step 3):
    briefcase create macOS --no-input && briefcase build macOS --no-input
    briefcase package macOS -p zip --no-input -i "<Developer ID identity>" --no-notarize
    scripts/sign_and_notarize_macos.sh

Running this script on its own only makes sense for an unsigned local test build.
(`briefcase build --adhoc-sign` does not exist; the flag belongs to `briefcase package`.)
"""
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/macapp/macos/app/Doc Cleaner.app"
README = ROOT / "ReadMe.txt"  # single source of truth (also bundled into the app)

# Version is read from pyproject.toml (single source of truth) rather than
# hardcoded, so the DMG name always matches the built app.
with open(ROOT / "pyproject.toml", "rb") as _f:
    _VERSION = tomllib.load(_f)["tool"]["briefcase"]["version"]
OUT = ROOT / f"dist/Doc Cleaner-{_VERSION}.dmg"

if not APP.exists():
    sys.exit(f"ERROR: .app not found at {APP}\nRun: briefcase create macOS --no-input && briefcase build macOS --no-input")

if not README.exists():
    sys.exit(f"ERROR: ReadMe.txt not found at {README}")

OUT.parent.mkdir(exist_ok=True)
if OUT.exists():
    OUT.unlink()

import dmgbuild  # noqa: E402 — deliberately late: only needed after the early-exit checks above

dmgbuild.build_dmg(
    str(OUT),
    "Doc Cleaner",
    settings={
        "files": [str(APP), str(README)],
        "symlinks": {"Applications": "/Applications"},
        "icon_locations": {
            "Doc Cleaner.app": (150, 185),
            "Applications":    (430, 185),
            "ReadMe.txt":      (290, 370),
        },
        "background": "builtin-arrow",
        "window_rect":  ((200, 120), (600, 500)),
        "icon_size":    100,
        "text_size":    13,
        "format":       "UDZO",
    }
)

size = OUT.stat().st_size // (1024 * 1024)
print(f"Done: {OUT.name} ({size} MB)")
print("Contents: Doc Cleaner.app + ReadMe.txt + Applications symlink")

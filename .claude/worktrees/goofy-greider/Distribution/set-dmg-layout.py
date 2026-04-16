#!/usr/bin/env python3
"""
Write icon positions into the DS_Store of the mounted DMG volume.
Called after hdiutil attach so the correct /Volumes path is used.

Usage: python3 Distribution/set-dmg-layout.py <mount-point>
  e.g. python3 Distribution/set-dmg-layout.py /Volumes/FieldWhisperer
"""
import sys, os, subprocess


def _install(pkg):
    for flags in [["--break-system-packages"], ["--user"], []]:
        try:
            subprocess.check_call(
                [sys.executable, "-m", "pip", "install", "--quiet", pkg, *flags],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except subprocess.CalledProcessError:
            continue
    return False


try:
    from ds_store import DSStore
except ImportError:
    print("  pip install ds-store…", flush=True)
    if not _install("ds-store"):
        print("  Warning: icon positioning skipped (ds-store unavailable)",
              file=sys.stderr)
        sys.exit(0)
    from ds_store import DSStore


mount = sys.argv[1] if len(sys.argv) > 1 else "."
ds_path = os.path.join(mount, ".DS_Store")

if os.path.exists(ds_path):
    os.remove(ds_path)

with DSStore.open(ds_path, "w+") as d:
    d["FieldWhisperer.app"]["Iloc"] = (150, 175)
    d["Applications"]["Iloc"]       = (450, 175)

print(f"  .DS_Store written → {ds_path}")

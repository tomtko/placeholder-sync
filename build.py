#!/usr/bin/env python3
"""Build (and optionally install) the addon with the names from brand.json.

    python3 addon/build.py                 # dist/<Addon>-<version>.zip
    python3 addon/build.py --install       # also copy into the _retail_ AddOns folder (Midnight, for testing)
    python3 addon/build.py --install --flavor _forever_
    python3 addon/build.py --version 0.2.0

The source in addon/src is brand-neutral except for the .toc and the slash constant in Core.lua; this
script rewrites those from brand.json, so renaming the guild is: edit brand.json, run this again.
The addon has its own version (brand.json addonVersion); the desktop app uses appVersion.
"""
import argparse, json, os, re, shutil, sys, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "addon" / "src"
DIST = ROOT / "addon" / "dist"
WOW_DEFAULT = Path("/mnt/c/Program Files (x86)/World of Warcraft")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", help="override brand.json addonVersion")
    ap.add_argument("--install", action="store_true", help="copy into the WoW AddOns folder after building")
    ap.add_argument("--flavor", default="_retail_", help="client folder to install into (default _retail_)")
    ap.add_argument("--wow", default=str(WOW_DEFAULT), help="World of Warcraft install root")
    args = ap.parse_args()

    brand = json.loads((ROOT / "brand.json").read_text())
    addon, slash = brand["addon"], brand["slash"]
    version = args.version or brand.get("addonVersion") or brand.get("version", "0.1.0")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", addon):
        sys.exit(f"brand.addon must be a plain identifier (folder + SavedVariables name): {addon!r}")

    stage = DIST / addon
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    toc_src = next(SRC.glob("*.toc"))
    for f in sorted(SRC.rglob("*")):
        if f.is_dir() or f.suffix == ".toc":
            continue
        rel = f.relative_to(SRC)
        (stage / rel).parent.mkdir(parents=True, exist_ok=True)
        if f.name == "Core.lua":
            text = f.read_text(encoding="utf-8")
            text, n = re.subn(r'^local SLASH = "/[^"]*" -- @brand:slash$', f'local SLASH = "/{slash}" -- @brand:slash', text, flags=re.M)
            if n != 1:
                sys.exit("Core.lua: @brand:slash marker not found")
            (stage / rel).write_text(text, encoding="utf-8")
        else:
            shutil.copy2(f, stage / rel)  # Lua, xml and the vendored Libs/ tree, byte for byte

    toc = toc_src.read_text(encoding="utf-8")
    toc = re.sub(r"^## Title:.*$", f"## Title: {addon}", toc, flags=re.M)
    toc = re.sub(r"^## Version:.*$", f"## Version: {version}", toc, flags=re.M)
    toc = re.sub(r"^## SavedVariables:.*$", f"## SavedVariables: {addon}DB", toc, flags=re.M)
    toc = re.sub(r"^## OptionalDeps: \w+_Data,", f"## OptionalDeps: {addon}_Data,", toc, flags=re.M)  # the bridge's companion folder
    (stage / f"{addon}.toc").write_text(toc, encoding="utf-8")

    modules = {}  # the council columns live inside the main addon now (Council_*.lua)
    stale_module_folders = [f"{addon}_RCLC", f"{addon}_FLC"]

    zip_path = DIST / f"{addon}-{version}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, src in [(addon, stage), *modules.items()]:
            for f in sorted(src.rglob("*")):
                if f.is_file():
                    z.write(f, f"Interface/AddOns/{folder}/{f.relative_to(src)}")
    print(f"built {zip_path.relative_to(ROOT)}  ({addon} v{version}, /{slash}, modules: {', '.join(modules) or 'none'})")

    if args.install:
        addons_dir = Path(args.wow) / args.flavor / "Interface" / "AddOns"
        if not addons_dir.is_dir():
            sys.exit(f"AddOns folder not found: {addons_dir}")
        for stale in stale_module_folders:  # left over from 0.2.0 builds that shipped sub-addons
            if (addons_dir / stale).is_dir():
                shutil.rmtree(addons_dir / stale)
        for folder, src in [(addon, stage), *modules.items()]:
            target = addons_dir / folder
            if target.exists():
                shutil.rmtree(target)  # the bridge's data lives in <addon>_Data next door, so nothing here is kept
            shutil.copytree(src, target)
        print(f"installed {addon} + {len(modules)} module(s) to {addons_dir}")
        sv = Path(args.wow) / args.flavor / "WTF" / "Account"
        print(f"SavedVariables will appear under {sv}/<account>/SavedVariables/{addon}.lua after a /reload")
    return 0


if __name__ == "__main__":
    sys.exit(main())

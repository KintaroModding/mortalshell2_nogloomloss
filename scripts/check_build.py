"""Compares the assets of the built mod with their source JSON files.

build.ps1 converts the built IoStore container back to legacy files and those to UAssetGUI JSON (dist/verify/json).
This script compares each of them with the source JSON in src: every export by name, with its class, its property
values and, for Blueprint functions, its bytecode. Object references are compared by the full name of the object they
point to, because the
conversion to IoStore and back can change the order of the imports. A name that disappears on the way (for example
a new gameplay tag outside the first NamesReferencedFromExportDataCount entries of the NameMap) shows up as a
difference.

Usage:
    python scripts/check_build.py <src folder> <verify json folder>

Exit code: 0 = every asset matches its source, 1 = differences or missing files.
"""

import json
import sys
from pathlib import Path


def resolver(asset: dict):
    imports = asset.get("Imports", [])
    exports = asset.get("Exports", [])

    def full_name(index):
        if not isinstance(index, int) or index == 0:
            return index
        parts = []
        seen = 0
        while isinstance(index, int) and index != 0 and seen < 32:
            seen += 1
            if index < 0 and -index - 1 < len(imports):
                item = imports[-index - 1]
                parts.append(item.get("ObjectName"))
                index = item.get("OuterIndex")
            elif index > 0 and index - 1 < len(exports):
                item = exports[index - 1]
                parts.append(item.get("ObjectName"))
                index = item.get("OuterIndex")
            else:
                parts.append(f"?{index}")
                break
        return ".".join(str(p) for p in reversed(parts))

    return full_name


# Keys that hold an import or export number, in properties and in Blueprint bytecode (Kismet expressions).
REFERENCE_KEYS = ("ResolvedOwner", "AttributeOwner", "StackNode", "Struct", "ClassPtr", "InterfaceClass", "MetaClass",
                  "Delegate", "Function")


def canonical(value, full_name):
    """Returns the value with object references replaced by full names and without serializer details."""
    if isinstance(value, list):
        return [canonical(item, full_name) for item in value]
    if not isinstance(value, dict):
        return value
    kind = value.get("$type", "")
    result = {}
    for key, item in value.items():
        if key in ("$type",):
            continue
        if key == "Value" and ("ObjectPropertyData" in kind or "EX_ObjectConst" in kind):
            result[key] = full_name(item)
        elif key in REFERENCE_KEYS and isinstance(item, int) and not isinstance(item, bool):
            result[key] = full_name(item)
        else:
            result[key] = canonical(item, full_name)
    result["$kind"] = kind.split(",")[0].split(".")[-1]
    return result


def exports_of(asset: dict) -> dict:
    full_name = resolver(asset)
    out = {}
    for export in asset.get("Exports", []):
        out[export.get("ObjectName")] = {
            "class": full_name(export.get("ClassIndex")),
            "data": canonical(export.get("Data"), full_name),
            "table": canonical((export.get("Table") or {}).get("Data"), full_name),
            "bytecode": canonical(export.get("ScriptBytecode"), full_name),
        }
    return out


def first_difference(a, b, path="") -> str:
    if type(a) is not type(b):
        return f"{path}: {json.dumps(a)[:120]} != {json.dumps(b)[:120]}"
    if isinstance(a, dict):
        for key in sorted(set(a) | set(b), key=str):
            if key not in a or key not in b:
                return f"{path}.{key}: only in {'source' if key in a else 'build'}"
            found = first_difference(a[key], b[key], f"{path}.{key}")
            if found:
                return found
        return ""
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{path}: {len(a)} items != {len(b)} items"
        for i, (x, y) in enumerate(zip(a, b)):
            found = first_difference(x, y, f"{path}[{i}]")
            if found:
                return found
        return ""
    return "" if a == b else f"{path}: {json.dumps(a)[:120]} != {json.dumps(b)[:120]}"


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("Usage: python scripts/check_build.py <src folder> <verify json folder>")
    src, built = Path(sys.argv[1]), Path(sys.argv[2])
    errors = 0
    for source in sorted(src.rglob("*.json")):
        relative = source.relative_to(src)
        target = built / relative
        if not target.is_file():
            print(f"MISSING in the build: {relative}")
            errors += 1
            continue
        a = exports_of(json.loads(source.read_text(encoding="utf-8")))
        b = exports_of(json.loads(target.read_text(encoding="utf-8")))
        difference = first_difference(a, b)
        if difference:
            print(f"DIFFERENT: {relative}\n  {difference}")
            errors += 1
        else:
            print(f"OK: {relative} ({len(a)} exports)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()

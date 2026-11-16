#!/usr/bin/env python3
"""Read-only Xcode references, shared scheme, Info and privacy configuration check."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET


def validate_project(root):
    errors, compiled = [], set()
    try:
        project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-",
                             str(root / "Percuscore.xcodeproj/project.pbxproj")], stderr=subprocess.STDOUT))
        objects = project["objects"]
        target = next(objects[key] for key in objects[project["rootObject"]]["targets"] if objects[key].get("name") == "Percuscore")
        for obj in objects.values():
            if obj.get("isa") == "PBXFileReference" and obj.get("sourceTree") == "SOURCE_ROOT":
                if not (root / obj["path"]).exists():
                    errors.append("missing reference: " + obj["path"])
        for phase in target["buildPhases"]:
            if objects[phase]["isa"] == "PBXSourcesBuildPhase":
                for build in objects[phase]["files"]:
                    compiled.add(objects[objects[build]["fileRef"]]["path"])
        actual = {str(path.relative_to(root)) for folder in ("Percuscore", "Sources/PercuscoreCore") for path in (root / folder).rglob("*.swift")}
        if actual != compiled:
            errors.append("Swift source/reference mismatch: " + repr(sorted(actual ^ compiled)))
        info = plistlib.loads((root / "Percuscore/Info.plist").read_bytes())
        for key, value in (("CFBundleShortVersionString", "$(MARKETING_VERSION)"), ("CFBundleVersion", "$(CURRENT_PROJECT_VERSION)")):
            if info.get(key) != value:
                errors.append("Version placeholder invalid: " + key)
        plistlib.loads((root / "Percuscore/Resources/PrivacyInfo.xcprivacy").read_bytes())
        scheme = ET.parse(root / "Percuscore.xcodeproj/xcshareddata/xcschemes/Percuscore.xcscheme")
        for ref in scheme.iter("BuildableReference"):
            if ref.attrib["BlueprintIdentifier"] not in objects:
                errors.append("Shared scheme references missing target")
        for key in objects[target["buildConfigurationList"]]["buildConfigurations"]:
            settings = objects[key]["buildSettings"]
            for field in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "PRODUCT_BUNDLE_IDENTIFIER"):
                if not str(settings.get(field, "")).strip():
                    errors.append("Missing build setting: " + field)
        if not (root / "scripts/write_build_info.py").is_file():
            errors.append("missing build metadata script")
    except (OSError, ValueError, KeyError, StopIteration, ET.ParseError, subprocess.CalledProcessError) as error:
        errors.append("Configuration unreadable or missing: " + str(error))
    return {"status": "failed" if errors else "passed", "compiled_sources": len(compiled), "errors": errors}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    result = validate_project(parser.parse_args().root)
    print(json.dumps(result, indent=2))
    sys.exit(1 if result["errors"] else 0)

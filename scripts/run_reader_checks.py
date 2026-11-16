#!/usr/bin/env python3
"""Run native reader tests in a disposable Simulator project; preserve device signing."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

if len(sys.argv) < 2:
    sys.exit("Usage: run_reader_checks.py <SIMULATOR-UUID> [xcodebuild arguments...]")

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(os.environ.get("VALIDATION_READER_WORK", str(Path(tempfile.gettempdir()) / "Percuscore-reader-tests")))
WORK.mkdir(parents=True, exist_ok=True)
for directory in ["Percuscore", "Sources", "Tests/PercuscoreReaderTests", "Percuscore.xcodeproj", "scripts"]:
    # Replace this runner's disposable source copies, including removed tests.
    if (WORK / directory).exists():
        shutil.rmtree(WORK / directory)
    shutil.copytree(ROOT / directory, WORK / directory, dirs_exist_ok=True)

def uid(name):
    return hashlib.sha1(("reader-test:" + name).encode()).hexdigest()[:24].upper()

def plist(value):
    if isinstance(value, dict):
        return "{\n" + "\n".join(f"{json.dumps(k)} = {plist(v)};" for k, v in value.items()) + "\n}"
    if isinstance(value, list):
        return "(" + ",".join(plist(v) for v in value) + ")"
    return json.dumps(str(value))

project_path = WORK / "Percuscore.xcodeproj/project.pbxproj"
project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project_path)]))
objects = project["objects"]
project_object = objects[project["rootObject"]]
app_id = project_object["targets"][0]
app = objects[app_id]
builds = []
for path in sorted((WORK / "Tests/PercuscoreReaderTests").glob("*.swift")):
    relative = path.relative_to(WORK).as_posix()
    ref, build = uid(relative), uid(relative + ":build")
    objects[ref] = dict(isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
    objects[build] = dict(isa="PBXBuildFile", fileRef=ref)
    builds.append(build)
    objects[project_object["mainGroup"]]["children"].append(ref)

test_id, product = uid("target"), uid("product")
objects[product] = dict(isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path="ReaderTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
objects[project_object["productRefGroup"]]["children"].append(product)
objects[uid("sources")] = dict(isa="PBXSourcesBuildPhase", buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")
objects[uid("frameworks")] = dict(isa="PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
objects[uid("proxy")] = dict(isa="PBXContainerItemProxy", containerPortal=project["rootObject"], proxyType="1", remoteGlobalIDString=app_id, remoteInfo="Percuscore")
objects[uid("dependency")] = dict(isa="PBXTargetDependency", target=app_id, targetProxy=uid("proxy"))
configs = []
for name in ["Debug", "Release"]:
    ident = uid(name)
    configs.append(ident)
    objects[ident] = dict(isa="XCBuildConfiguration", name=name, buildSettings=dict(
        PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="com.percuscore.reader.tests",
        GENERATE_INFOPLIST_FILE="YES", SWIFT_VERSION="5.0", IPHONEOS_DEPLOYMENT_TARGET="17.0",
        TARGETED_DEVICE_FAMILY="2", CODE_SIGNING_ALLOWED="NO",
        TEST_HOST="$(BUILT_PRODUCTS_DIR)/Percuscore.app/Percuscore", BUNDLE_LOADER="$(TEST_HOST)",
        LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks @loader_path/Frameworks"))
objects[uid("configs")] = dict(isa="XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Debug")
objects[test_id] = dict(isa="PBXNativeTarget", name="ReaderTests", productName="ReaderTests", productType="com.apple.product-type.bundle.unit-test",
    productReference=product, buildConfigurationList=uid("configs"), buildPhases=[uid("sources"), uid("frameworks")],
    buildRules=[], dependencies=[uid("dependency")])
project_object["targets"].append(test_id)
for value in objects.values():
    if value.get("isa") == "XCBuildConfiguration" and value.get("buildSettings", {}).get("PRODUCT_BUNDLE_IDENTIFIER") == "com.percuscore.reader":
        value["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] = "com.percuscore.reader.testhost"
project_path.write_text("// !$*UTF8*$!\n" + plist(project))

scheme = WORK / "Percuscore.xcodeproj/xcshareddata/xcschemes/Percuscore.xcscheme"
scheme.write_text(scheme.read_text().replace("<Testables/>", f'''<Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}" BuildableName="ReaderTests.xctest" BlueprintName="ReaderTests" ReferencedContainer="container:Percuscore.xcodeproj"/></TestableReference></Testables>'''))
device = sys.argv[1]
environment = dict(os.environ)
environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
result = subprocess.run(["xcodebuild", "-project", str(WORK / "Percuscore.xcodeproj"), "-scheme", "Percuscore",
    "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", str(WORK / "build"),
    "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO", "test", *sys.argv[2:]], env=environment)
sys.exit(result.returncode)

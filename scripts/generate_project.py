#!/usr/bin/env python3
"""Generate a small, dependency-free Xcode project from the checked-in Swift sources."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Percuscore.xcodeproj"
PROJECT.mkdir(exist_ok=True)

# Keep the user's signing identity and version when rebuilding references.
existing_signing = {}
project_file = PROJECT / "project.pbxproj"
if project_file.exists():
    previous = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project_file)]))
    previous_objects = previous["objects"]
    for target_id in previous_objects[previous["rootObject"]]["targets"]:
        previous_target = previous_objects[target_id]
        if previous_target.get("name") != "Percuscore":
            continue
        configuration_list = previous_objects[previous_target["buildConfigurationList"]]
        for configuration_id in configuration_list["buildConfigurations"]:
            configuration = previous_objects[configuration_id]
            existing_signing[configuration["name"]] = {
                key: value for key, value in configuration["buildSettings"].items()
                if key in {"DEVELOPMENT_TEAM", "PRODUCT_BUNDLE_IDENTIFIER", "CODE_SIGN_STYLE", "PROVISIONING_PROFILE_SPECIFIER", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION"}
            }

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def quoted(value):
    return json.dumps(str(value))

objects = []
def obj(name, body):
    objects.append(f"\t\t{uid(name)} = {{ {body} }};")
    return uid(name)

sources = sorted((ROOT / "Percuscore").rglob("*.swift")) + sorted((ROOT / "Sources/PercuscoreCore").glob("*.swift"))
source_builds, source_refs = [], []
for path in sources:
    rel = path.relative_to(ROOT).as_posix()
    ref = obj("ref:" + rel, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(rel)}; sourceTree = SOURCE_ROOT;")
    source_refs.append(ref)
    source_builds.append(obj("build:" + rel, f"isa = PBXBuildFile; fileRef = {ref};"))

resource_refs, resource_builds = [], []
for rel, kind in [("Percuscore/Resources/Assets.xcassets", "folder.assetcatalog"),
                  ("Percuscore/Resources/PrivacyInfo.xcprivacy", "text.xml"),
                  ("Percuscore/Resources/AppIcon.icon", "folder.iconcomposer")]:
    ref = obj("ref:" + rel, f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quoted(rel)}; sourceTree = SOURCE_ROOT;")
    resource_refs.append(ref)
    resource_builds.append(obj("build:" + rel, f"isa = PBXBuildFile; fileRef = {ref};"))

app = obj("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Percuscore.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj("products", f"isa = PBXGroup; children = ({app},); name = Products; sourceTree = \"<group>\";")
source_group = obj("sources", f"isa = PBXGroup; children = ({','.join(source_refs)},); name = Sources; sourceTree = \"<group>\";")
resources = obj("resources", f"isa = PBXGroup; children = ({','.join(resource_refs)},); name = Resources; sourceTree = \"<group>\";")
main = obj("main", f"isa = PBXGroup; children = ({source_group},{resources},{products},); sourceTree = \"<group>\";")
source_phase = obj("source-phase", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(source_builds)},); runOnlyForDeploymentPostprocessing = 0;")
resource_phase = obj("resource-phase", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(resource_builds)},); runOnlyForDeploymentPostprocessing = 0;")
framework_phase = obj("framework-phase", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
build_info_script = '/usr/bin/python3 "$SRCROOT/scripts/write_build_info.py" --root "$SRCROOT" --output "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/BuildInfo.plist"'
build_info_phase = obj("build-info-phase", f'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = ("$(SRCROOT)/scripts/write_build_info.py",); outputPaths = ("$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/BuildInfo.plist",); name = "Record source version"; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = {quoted(build_info_script)};')

for config in ["Debug", "Release"]:
    settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym",
        "ENABLE_TESTABILITY": "YES" if config == "Debug" else "NO",
    }
    if config == "Debug": settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
    body = " ".join(f"{k} = {quoted(v)};" for k, v in settings.items())
    obj("project-" + config, f"isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};")
    target = {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.percuscore.reader", "PRODUCT_NAME": "$(TARGET_NAME)",
        "TARGETED_DEVICE_FAMILY": "2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO", "INFOPLIST_FILE": "Percuscore/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO", "CODE_SIGN_STYLE": "Automatic",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        # Git metadata may live outside SRCROOT (worktrees). This local script
        # reads source status and writes only its declared built-app resource.
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    }
    target.update(existing_signing.get(config, {}))
    body = " ".join(f"{k} = {quoted(v)};" for k, v in target.items())
    obj("target-" + config, f"isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};")

for owner in ["project", "target"]:
    obj(owner + "-configs", f"isa = XCConfigurationList; buildConfigurations = ({uid(owner+'-Debug')},{uid(owner+'-Release')},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

target_id = obj("target", f"isa = PBXNativeTarget; buildConfigurationList = {uid('target-configs')}; buildPhases = ({source_phase},{framework_phase},{resource_phase},{build_info_phase},); buildRules = (); dependencies = (); name = Percuscore; productName = Percuscore; productReference = {app}; productType = \"com.apple.product-type.application\";")
obj("project", f"isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {{ {target_id} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {uid('project-configs')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {main}; productRefGroup = {products}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({target_id},);")

(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {uid('project')};\n}}\n")
scheme_dir = PROJECT / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="Percuscore.app" BlueprintName="Percuscore" ReferencedContainer="container:Percuscore.xcodeproj"/>'
(scheme_dir / "Percuscore.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

info = {
    "CFBundleDisplayName": "Percuscore", "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleInfoDictionaryVersion": "6.0", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSRequiresIPhoneOS": True, "UILaunchScreen": {},
    "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
    "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
    "CFBundleDocumentTypes": [{"CFBundleTypeName": "PDF Score", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate", "LSItemContentTypes": ["com.adobe.pdf"]}],
    "UTExportedTypeDeclarations": [{
        "UTTypeIdentifier": "com.percuscore.library-backup",
        "UTTypeDescription": "Percuscore Library Backup",
        "UTTypeConformsTo": ["public.data"],
        "UTTypeTagSpecification": {"public.filename-extension": ["percuscorebackup"]},
    }],
    "ITSAppUsesNonExemptEncryption": False,
}
(ROOT / "Percuscore/Info.plist").write_bytes(plistlib.dumps(info))
(ROOT / "Percuscore/Resources/PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [], "NSPrivacyAccessedAPITypes": []}))
print(f"Generated {PROJECT.name}: {len(sources)} Swift sources")

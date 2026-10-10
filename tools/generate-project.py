"""Generate Roadline's dependency-free Xcode project. Run from any directory."""
from pathlib import Path
import hashlib
import json
import plistlib
from xml.sax.saxutils import escape

root = Path(__file__).resolve().parents[1]
objects = {}

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def obj(key_name, isa, **values):
    key = ident(key_name)
    objects[key] = dict(isa=isa, **values)
    return key

def encode(value, depth=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (depth + 1) + json.dumps(k) + " = " + encode(v, depth + 1) + ";\n" for k, v in value.items()) + "\t" * depth + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (depth + 1) + encode(v, depth + 1) + ",\n" for v in value) + "\t" * depth + ")"
    return json.dumps(str(value))

sources = sorted((root / "Roadline").glob("*.swift"))
tests = sorted((root / "RoadlineTests").glob("*.swift"))
resources = [root / "Roadline/Assets.xcassets", root / "Roadline/PrivacyInfo.xcprivacy", root / "Roadline/fonts/bmw_cluster_regular.ttf", root / "Roadline/fonts/bmw_cluster_bold.ttf", root / "Roadline/fonts/Barlow-OFL.txt"]
refs = {}
for path in sources + tests + resources + [root / "Roadline/Info.plist"]:
    relative = path.relative_to(root).as_posix()
    filetype = {".swift": "sourcecode.swift", ".ttf": "file", ".plist": "text.plist.xml", ".xcprivacy": "text.xml", ".xcassets": "folder.assetcatalog"}.get(path.suffix, "text")
    refs[relative] = obj(relative, "PBXFileReference", lastKnownFileType=filetype, path=relative, sourceTree="<group>")

app_product = obj("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="Roadline.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = obj("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="RoadlineTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
products = obj("products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
group = obj("main-group", "PBXGroup", children=list(refs.values()) + [products], sourceTree="<group>")

def phase(name, kind, paths):
    files = [obj("build-" + name + str(path), "PBXBuildFile", fileRef=refs[path.relative_to(root).as_posix()]) for path in paths]
    return obj(name, kind, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)

app_phases = [phase("app-sources", "PBXSourcesBuildPhase", sources), phase("app-resources", "PBXResourcesBuildPhase", resources), phase("app-frameworks", "PBXFrameworksBuildPhase", [])]
test_phases = [phase("test-sources", "PBXSourcesBuildPhase", tests), phase("test-resources", "PBXResourcesBuildPhase", []), phase("test-frameworks", "PBXFrameworksBuildPhase", [])]

def configurations(name, common):
    ids = []
    for mode in ("Debug", "Release"):
        settings = dict(common)
        if mode == "Debug":
            settings.update(SWIFT_OPTIMIZATION_LEVEL="-Onone", ENABLE_TESTABILITY="YES", DEBUG_INFORMATION_FORMAT="dwarf", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG")
        else:
            settings.update(SWIFT_OPTIMIZATION_LEVEL="-O", DEBUG_INFORMATION_FORMAT="dwarf-with-dsym")
        ids.append(obj(name + mode, "XCBuildConfiguration", name=mode, buildSettings=settings))
    return obj(name + "-list", "XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

project_config = configurations("project", dict(CLANG_ENABLE_MODULES="YES", SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="17.0", SWIFT_VERSION="5.0", SWIFT_STRICT_CONCURRENCY="minimal"))
common = dict(CODE_SIGN_STYLE="Automatic", DEVELOPMENT_TEAM="", CURRENT_PROJECT_VERSION="1", MARKETING_VERSION="1.4.2", TARGETED_DEVICE_FAMILY="1,2", SUPPORTED_PLATFORMS="iphoneos iphonesimulator", SUPPORTS_MACCATALYST="NO", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"])
app_settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER="com.roadline.ios", PRODUCT_NAME="Roadline", INFOPLIST_FILE="Roadline/Info.plist", ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", GENERATE_INFOPLIST_FILE="NO")
test_settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER="com.roadline.ios.tests", PRODUCT_NAME="RoadlineTests", GENERATE_INFOPLIST_FILE="YES", TEST_HOST="$(BUILT_PRODUCTS_DIR)/Roadline.app/Roadline", BUNDLE_LOADER="$(TEST_HOST)")
app_config = configurations("app", app_settings)
test_config = configurations("tests", test_settings)
app = obj("app-target", "PBXNativeTarget", name="Roadline", buildConfigurationList=app_config, buildPhases=app_phases, buildRules=[], dependencies=[], productName="Roadline", productReference=app_product, productType="com.apple.product-type.application")
proxy = obj("test-proxy", "PBXContainerItemProxy", containerPortal=ident("project-root"), proxyType=1, remoteGlobalIDString=app, remoteInfo="Roadline")
dependency = obj("test-dependency", "PBXTargetDependency", target=app, targetProxy=proxy)
test_target = obj("test-target", "PBXNativeTarget", name="RoadlineTests", buildConfigurationList=test_config, buildPhases=test_phases, buildRules=[], dependencies=[dependency], productName="RoadlineTests", productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
project = obj("project-root", "PBXProject", attributes={"LastUpgradeCheck": "1600", "TargetAttributes": {app: {"CreatedOnToolsVersion": "16.0"}, test_target: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app}}}, buildConfigurationList=project_config, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app, test_target])
project_dir = root / "Roadline.xcodeproj"
project_dir.mkdir(exist_ok=True)
(project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)) + "\n", encoding="utf-8")
scheme_dir = project_dir / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)

def ref(key, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Roadline.xcodeproj"/>'

app_ref = ref(app, "Roadline", "Roadline.app")
test_ref = ref(test_target, "RoadlineTests", "RoadlineTests.xctest")
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{test_ref}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES" codeCoverageEnabled="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(scheme_dir / "Roadline.xcscheme").write_text(scheme, encoding="utf-8")
print(f"Generated project with {len(sources)} app source files and {len(tests)} test source files.")

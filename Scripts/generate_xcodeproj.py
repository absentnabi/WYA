#!/usr/bin/env python3
"""Write WYA.xcodeproj. Re-run if source files are added."""

from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "WYA/App/WYAApp.swift",
    "WYA/App/AppModel.swift",
    "WYA/Design/Theme.swift",
    "WYA/Services/ArrivalCache.swift",
    "WYA/Services/LLMClient.swift",
    "WYA/Services/LocationService.swift",
    "WYA/Services/PlaceGeocoder.swift",
    "WYA/Services/RealtimeArrivalsService.swift",
    "WYA/Services/SecretsStore.swift",
    "WYA/Services/WalkingRefiner.swift",
    "WYA/Views/NearbyView.swift",
    "WYA/Views/PlanView.swift",
    "WYA/Views/RootView.swift",
    "WYA/Views/RouteBadge.swift",
]
RESOURCES = [
    "WYA/Resources/Assets.xcassets",
    "WYA/Resources/transit-index.json",
    "WYA/Resources/UnionSquare.gpx",
]
TESTS = ["WYACore/Tests/WYACoreTests/WYACoreTests.swift"]
OTHER = ["Scripts/copy-secrets.sh", "Secrets.example.plist"]


def uid(name: str) -> str:
    return hashlib.sha1(f"wya:{name}".encode()).hexdigest()[:24].upper()


def quote(value: str) -> str:
    if value == "" or any(ch in value for ch in ' "$@'):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def settings_block(pairs: list[tuple[str, str]], indent: str = "\t\t\t\t") -> str:
    lines = [f"{indent}{key} = {quote(value)};" for key, value in pairs]
    return "\n".join(lines)


def main() -> None:
    file_refs = {}
    build_files = {}

    def add_ref(path: str, kind: str) -> str:
        ref = uid(f"ref:{path}")
        file_refs[path] = (ref, kind, Path(path).name)
        return ref

    def add_build(path: str, phase: str) -> str:
        ref, _, name = file_refs[path]
        build = uid(f"build:{phase}:{path}")
        build_files[path] = (build, ref, name)
        return build

    for path in SOURCES + TESTS + OTHER:
        add_ref(path, "sourcecode.swift" if path.endswith(".swift") else "text")
    add_ref("WYA/Resources/Assets.xcassets", "folder.assetcatalog")
    add_ref("WYA/Resources/transit-index.json", "text.json")
    add_ref("WYA/Resources/UnionSquare.gpx", "text.xml")
    for path in SOURCES:
        add_build(path, "app")
    for path in RESOURCES:
        add_build(path, "resource")
    for path in TESTS:
        add_build(path, "test")

    app_product = uid("product:app")
    test_product = uid("product:test")
    file_refs["WYA.app"] = (app_product, "wrapper.application", "WYA.app")
    file_refs["WYATests.xctest"] = (test_product, "wrapper.cfbundle", "WYATests.xctest")

    pkg_ref = uid("pkg:WYACore")
    pkg_dep_app = uid("dep:app:WYACore")
    pkg_dep_test = uid("dep:test:WYACore")
    pkg_build_app = uid("build:fw:app")
    pkg_build_test = uid("build:fw:test")

    groups = {
        "root": uid("group:root"),
        "app": uid("group:app"),
        "design": uid("group:design"),
        "services": uid("group:services"),
        "views": uid("group:views"),
        "resources": uid("group:resources"),
        "wya": uid("group:wya"),
        "tests": uid("group:tests"),
        "products": uid("group:products"),
        "support": uid("group:support"),
    }

    def group(gid: str, name: str, children: list[str], path: str | None = None) -> str:
        child_lines = "\n".join(f"\t\t\t\t{child}," for child in children)
        path_line = f"\n\t\t\tpath = {name};" if path else ""
        return f"""\t\t{gid} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{child_lines}
\t\t\t);{path_line}
\t\t\tname = {name};
\t\t\tsourceTree = "<group>";
\t\t}};"""

    # Children are file ref ids. Groups that use path need source files relative.
    # Use name + path so the navigator matches the repo.
    def group_with_path(gid: str, name: str, path: str, children: list[str]) -> str:
        child_lines = "\n".join(f"\t\t\t\t{child}," for child in children)
        return f"""\t\t{gid} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{child_lines}
\t\t\t);
\t\t\tpath = {path};
\t\t\tsourceTree = "<group>";
\t\t}};"""

    app_children = [file_refs[p][0] for p in SOURCES if p.startswith("WYA/App/")]
    design_children = [file_refs[p][0] for p in SOURCES if p.startswith("WYA/Design/")]
    service_children = [file_refs[p][0] for p in SOURCES if p.startswith("WYA/Services/")]
    view_children = [file_refs[p][0] for p in SOURCES if p.startswith("WYA/Views/")]
    resource_children = [file_refs[p][0] for p in RESOURCES]
    test_children = [file_refs[p][0] for p in TESTS]
    support_children = [file_refs[p][0] for p in OTHER]

    group_text = "\n".join([
        group_with_path(groups["app"], "App", "App", app_children),
        group_with_path(groups["design"], "Design", "Design", design_children),
        group_with_path(groups["services"], "Services", "Services", service_children),
        group_with_path(groups["views"], "Views", "Views", view_children),
        group_with_path(groups["resources"], "Resources", "Resources", resource_children),
        group(groups["wya"], "WYA", [groups["app"], groups["design"], groups["services"], groups["views"], groups["resources"]], ),
        group(groups["tests"], "WYATests", test_children),
        group(groups["support"], "Support", support_children),
        group(groups["products"], "Products", [app_product, test_product]),
        group(groups["root"], "", [groups["wya"], groups["tests"], groups["support"], groups["products"]]),
    ])
    # Fix root group: empty name is invalid. Set name to WYA project via a custom block.
    group_text = group_text.replace(
        f"""\t\t{groups["root"]} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{groups["wya"]},
\t\t\t\t{groups["tests"]},
\t\t\t\t{groups["support"]},
\t\t\t\t{groups["products"]},
\t\t\t);
\t\t\tname = ;
\t\t\tsourceTree = "<group>";
\t\t}};""",
        f"""\t\t{groups["root"]} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{groups["wya"]},
\t\t\t\t{groups["tests"]},
\t\t\t\t{groups["support"]},
\t\t\t\t{groups["products"]},
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};""",
    )
    # WYA group should have path WYA and its children paths are relative (App, Design...).
    # The group() helper for WYA used name only. Replace it with path = WYA.
    group_text = group_text.replace(
        f"""\t\t{groups["wya"]} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{groups["app"]},
\t\t\t\t{groups["design"]},
\t\t\t\t{groups["services"]},
\t\t\t\t{groups["views"]},
\t\t\t\t{groups["resources"]},
\t\t\t);
\t\t\tname = WYA;
\t\t\tsourceTree = "<group>";
\t\t}};""",
        f"""\t\t{groups["wya"]} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{groups["app"]},
\t\t\t\t{groups["design"]},
\t\t\t\t{groups["services"]},
\t\t\t\t{groups["views"]},
\t\t\t\t{groups["resources"]},
\t\t\t);
\t\t\tpath = WYA;
\t\t\tsourceTree = "<group>";
\t\t}};""",
    )

    file_ref_lines = []
    for path, (ref, kind, name) in file_refs.items():
        if path in ("WYA.app", "WYATests.xctest"):
            file_ref_lines.append(
                f"""\t\t{ref} /* {name} */ = {{isa = PBXFileReference; explicitFileType = "{kind}"; includeInIndex = 0; path = {name}; sourceTree = BUILT_PRODUCTS_DIR; }};"""
            )
            continue
        # Paths are relative to their parent group.
        # App groups set path to App/Design/Services/Views/Resources, so those
        # file refs are filenames. Everything else hangs off the project root.
        relative = Path(path).name if path.startswith("WYA/") else path
        file_ref_lines.append(
            f"""\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {relative}; sourceTree = "<group>"; }};"""
        )

    def phase(phase_id: str, isa: str, files: list[str], name: str) -> str:
        body = "\n".join(f"\t\t\t\t{item}," for item in files)
        return f"""\t\t{phase_id} /* {name} */ = {{
\t\t\tisa = {isa};
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{body}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""

    sources_phase = uid("phase:sources")
    resources_phase = uid("phase:resources")
    frameworks_phase = uid("phase:frameworks")
    script_phase = uid("phase:script")
    test_sources = uid("phase:testsources")
    test_frameworks = uid("phase:testframeworks")

    app_source_builds = [build_files[p][0] for p in SOURCES]
    resource_builds = [build_files[p][0] for p in RESOURCES]
    test_source_builds = [build_files[p][0] for p in TESTS]

    build_file_lines = []
    for path in SOURCES:
        build, ref, name = build_files[path]
        build_file_lines.append(f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
    for path in RESOURCES:
        build, ref, name = build_files[path]
        build_file_lines.append(f"\t\t{build} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
    for path in TESTS:
        build, ref, name = build_files[path]
        build_file_lines.append(f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
    build_file_lines.append(f"\t\t{pkg_build_app} /* WYACore in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkg_dep_app} /* WYACore */; }};")
    build_file_lines.append(f"\t\t{pkg_build_test} /* WYACore in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkg_dep_test} /* WYACore */; }};")

    project_debug = uid("cfg:project:debug")
    project_release = uid("cfg:project:release")
    project_list = uid("cfglist:project")
    app_debug = uid("cfg:app:debug")
    app_release = uid("cfg:app:release")
    app_list = uid("cfglist:app")
    test_debug = uid("cfg:test:debug")
    test_release = uid("cfg:test:release")
    test_list = uid("cfglist:test")
    app_target = uid("target:app")
    test_target = uid("target:test")
    project_id = uid("project")
    proxy = uid("proxy")
    dependency = uid("dependency")

    shared = [
        ("ALWAYS_SEARCH_USER_PATHS", "NO"),
        ("CLANG_ANALYZER_NONNULL", "YES"),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CLANG_ENABLE_OBJC_ARC", "YES"),
        ("COPY_PHASE_STRIP", "NO"),
        ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
        ("GCC_NO_COMMON_BLOCKS", "YES"),
        ("IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
        ("SDKROOT", "iphoneos"),
        ("SWIFT_VERSION", "5.0"),
    ]
    debug_extra = [
        ("DEBUG_INFORMATION_FORMAT", "dwarf"),
        ("ENABLE_TESTABILITY", "YES"),
        ("GCC_DYNAMIC_NO_PIC", "NO"),
        ("GCC_OPTIMIZATION_LEVEL", "0"),
        ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
        ("ONLY_ACTIVE_ARCH", "YES"),
        ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
        ("SWIFT_OPTIMIZATION_LEVEL", "-Onone"),
    ]
    release_extra = [
        ("COPY_PHASE_STRIP", "NO"),
        ("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym"),
        ("ENABLE_NS_ASSERTIONS", "NO"),
        ("MTL_ENABLE_DEBUG_INFO", "NO"),
        ("SWIFT_COMPILATION_MODE", "wholemodule"),
        ("SWIFT_OPTIMIZATION_LEVEL", "-O"),
        ("VALIDATE_PRODUCT", "YES"),
    ]

    location = "WYA uses your location while the app is open to find nearby subway and bus stops and to estimate the walk."
    app_common = [
        ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
        ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("DEVELOPMENT_TEAM", ""),
        ("ENABLE_PREVIEWS", "YES"),
        ("ENABLE_USER_SCRIPT_SANDBOXING", "NO"),
        ("GENERATE_INFOPLIST_FILE", "YES"),
        ("INFOPLIST_KEY_CFBundleDisplayName", "WYA"),
        ("INFOPLIST_KEY_ITSAppUsesNonExemptEncryption", "NO"),
        ("INFOPLIST_KEY_NSLocationWhenInUseUsageDescription", location),
        ("INFOPLIST_KEY_UIApplicationSceneManifest_Generation", "YES"),
        ("INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents", "YES"),
        ("INFOPLIST_KEY_UILaunchScreen_Generation", "YES"),
        ("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad", "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"),
        ("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone", "UIInterfaceOrientationPortrait"),
        ("LD_RUNPATH_SEARCH_PATHS", "$(inherited) @executable_path/Frameworks"),
        ("MARKETING_VERSION", "1.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", "dev.brandonortiz.wya"),
        ("PRODUCT_NAME", "$(TARGET_NAME)"),
        ("SUPPORTED_PLATFORMS", "iphoneos iphonesimulator"),
        ("SUPPORTS_MACCATALYST", "NO"),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ("SWIFT_VERSION", "5.0"),
        ("TARGETED_DEVICE_FAMILY", "1,2"),
    ]
    test_common = [
        ("BUNDLE_LOADER", "$(TEST_HOST)"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("GENERATE_INFOPLIST_FILE", "YES"),
        ("IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
        ("LD_RUNPATH_SEARCH_PATHS", "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"),
        ("MARKETING_VERSION", "1.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", "dev.brandonortiz.wya.tests"),
        ("PRODUCT_NAME", "$(TARGET_NAME)"),
        ("SDKROOT", "iphoneos"),
        ("SWIFT_EMIT_LOC_STRINGS", "NO"),
        ("SWIFT_VERSION", "5.0"),
        ("TARGETED_DEVICE_FAMILY", "1,2"),
        ("TEST_HOST", "$(BUILT_PRODUCTS_DIR)/WYA.app/WYA"),
    ]

    def config(cid: str, name: str, pairs: list[tuple[str, str]]) -> str:
        return f"""\t\t{cid} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{settings_block(pairs)}
\t\t\t}};
\t\t\tname = {name};
\t\t}};"""

    script = r'''/bin/bash "${SRCROOT}/Scripts/copy-secrets.sh"
'''
    script_literal = script.strip().replace("\\", "\\\\").replace('"', '\\"')
    pbx = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_file_lines)}
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
\t\t{proxy} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {project_id} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {app_target};
\t\t\tremoteInfo = WYA;
\t\t}};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
{chr(10).join(file_ref_lines)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
{phase(frameworks_phase, "PBXFrameworksBuildPhase", [pkg_build_app], "Frameworks")}
{phase(test_frameworks, "PBXFrameworksBuildPhase", [pkg_build_test], "Frameworks")}
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
{group_text}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{app_target} /* WYA */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {app_list} /* Build configuration list for PBXNativeTarget "WYA" */;
\t\t\tbuildPhases = (
\t\t\t\t{sources_phase} /* Sources */,
\t\t\t\t{frameworks_phase} /* Frameworks */,
\t\t\t\t{resources_phase} /* Resources */,
\t\t\t\t{script_phase} /* Copy Secrets */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = WYA;
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkg_dep_app} /* WYACore */,
\t\t\t);
\t\t\tproductName = WYA;
\t\t\tproductReference = {app_product} /* WYA.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
\t\t{test_target} /* WYATests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {test_list} /* Build configuration list for PBXNativeTarget "WYATests" */;
\t\t\tbuildPhases = (
\t\t\t\t{test_sources} /* Sources */,
\t\t\t\t{test_frameworks} /* Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{dependency} /* PBXTargetDependency */,
\t\t\t);
\t\t\tname = WYATests;
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkg_dep_test} /* WYACore */,
\t\t\t);
\t\t\tproductName = WYATests;
\t\t\tproductReference = {test_product} /* WYATests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{project_id} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t}};
\t\t\tbuildConfigurationList = {project_list} /* Build configuration list for PBXProject "WYA" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {groups["root"]};
\t\t\tpackageReferences = (
\t\t\t\t{pkg_ref} /* XCLocalSwiftPackageReference "WYACore" */,
\t\t\t);
\t\t\tproductRefGroup = {groups["products"]} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{app_target} /* WYA */,
\t\t\t\t{test_target} /* WYATests */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
{phase(resources_phase, "PBXResourcesBuildPhase", resource_builds, "Resources")}
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
\t\t{script_phase} /* Copy Secrets */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\talwaysOutOfDate = 1;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tinputPaths = (
\t\t\t);
\t\t\toutputPaths = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/sh;
\t\t\tshellScript = "{script_literal}\\n";
\t\t}};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
{phase(sources_phase, "PBXSourcesBuildPhase", app_source_builds, "Sources")}
{phase(test_sources, "PBXSourcesBuildPhase", test_source_builds, "Sources")}
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
\t\t{dependency} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {app_target} /* WYA */;
\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
{config(project_debug, "Debug", shared + debug_extra)}
{config(project_release, "Release", shared + release_extra)}
{config(app_debug, "Debug", app_common)}
{config(app_release, "Release", app_common)}
{config(test_debug, "Debug", test_common)}
{config(test_release, "Release", test_common)}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{project_list} /* Build configuration list for PBXProject "WYA" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{project_debug} /* Debug */,
\t\t\t\t{project_release} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{app_list} /* Build configuration list for PBXNativeTarget "WYA" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{app_debug} /* Debug */,
\t\t\t\t{app_release} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{test_list} /* Build configuration list for PBXNativeTarget "WYATests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{test_debug} /* Debug */,
\t\t\t\t{test_release} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
\t\t{pkg_ref} /* XCLocalSwiftPackageReference "WYACore" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = WYACore;
\t\t}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
\t\t{pkg_dep_app} /* WYACore */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {pkg_ref} /* XCLocalSwiftPackageReference "WYACore" */;
\t\t\tproductName = WYACore;
\t\t}};
\t\t{pkg_dep_test} /* WYACore */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {pkg_ref} /* XCLocalSwiftPackageReference "WYACore" */;
\t\t\tproductName = WYACore;
\t\t}};
/* End XCSwiftPackageProductDependency section */
\t}};
\trootObject = {project_id} /* Project object */;
}}
"""
    # The tests group has no path, and the file ref uses the full repo-relative path.
    # Support files also use just the filename, but they live at repo root, and the
    # support group has no path, so filenames resolve at the project root. Good.
    # WYATests file ref was forced to the full path. Confirm:
    project_dir = ROOT / "WYA.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    (project_dir / "project.pbxproj").write_text(pbx)
    workspace = project_dir / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""
    )
    scheme_dir = project_dir / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "WYA.app"
               BlueprintName = "WYA"
               ReferencedContainer = "container:WYA.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "WYATests.xctest"
               BlueprintName = "WYATests"
               ReferencedContainer = "container:WYA.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "WYA.app"
            BlueprintName = "WYA"
            ReferencedContainer = "container:WYA.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
      <LocationScenarioReference
         identifier = "../WYA/Resources/UnionSquare.gpx"
         referenceType = "0">
      </LocationScenarioReference>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "WYA.app"
            BlueprintName = "WYA"
            ReferencedContainer = "container:WYA.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    (scheme_dir / "WYA.xcscheme").write_text(scheme)
    print(f"wrote {project_dir / 'project.pbxproj'}")


if __name__ == "__main__":
    main()

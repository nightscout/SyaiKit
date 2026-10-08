#!/usr/bin/env python3
# Copyright (c) 2026 Nightscout Foundation.
# Licensed under the MIT License. See LICENSE in the project root.
"""Generate SyaiKit.xcodeproj/project.pbxproj (objectVersion 77, Xcode 16
synchronized folder groups). Four targets (SyaiKit / SyaiKitUI /
SyaiKitPlugin / SyaiKitTests). LoopKit/LoopKitUI come from BUILT_PRODUCTS_DIR
(i.e. build inside the Trio workspace). Trio's LoopKit bundles the
LoopAlgorithm sources, so there is no standalone LoopAlgorithm.framework to
link."""

import itertools

_counter = itertools.count(1)
def uid():
    return "5741" + format(next(_counter), "020X")

objs = {}   # uid -> text block (already indented with 2 tabs)
def add(u, body):
    objs[u] = body

def arr(items, indent=5):
    pad = "\t" * indent
    return "".join(f"{pad}{i},\n" for i in items)

# ---- external frameworks (from the Trio workspace build products) ----
ext_frameworks = {}   # name -> fileRef uid
for fw in ("LoopKit", "LoopKitUI"):
    u = uid()
    ext_frameworks[fw] = u
    add(u, f'{u} /* {fw}.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; path = {fw}.framework; sourceTree = BUILT_PRODUCTS_DIR; }};')

# ---- product references ----
products = {
    "SyaiKit":       ("SyaiKit.framework", "wrapper.framework"),
    "SyaiKitUI":        ("SyaiKitUI.framework", "wrapper.framework"),
    "SyaiKitPlugin": ("SyaiKitPlugin.loopplugin", "wrapper.framework"),
    "SyaiKitTests":  ("SyaiKitTests.xctest", "wrapper.cfbundle"),
}
product_ref = {}
for tgt, (path, ftype) in products.items():
    u = uid()
    product_ref[tgt] = u
    add(u, f'{u} /* {path} */ = {{isa = PBXFileReference; explicitFileType = {ftype}; includeInIndex = 0; path = {path}; sourceTree = BUILT_PRODUCTS_DIR; }};')

# ---- synchronized root groups (one folder per target) ----
sync_group = {}
for folder in ("SyaiKit", "SyaiKitUI", "SyaiKitPlugin", "SyaiKitTests"):
    sync_group[folder] = uid()

# plugin Info.plist exclusion (don't compile/copy it; used via INFOPLIST_FILE)
plugin_exc = uid()

def sync_group_block(folder, u):
    if folder == "SyaiKitPlugin":
        return (f'{u} /* {folder} */ = {{\n'
                f'\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n'
                f'\t\t\texceptions = (\n\t\t\t\t{plugin_exc} /* Exceptions for "{folder}" folder */,\n\t\t\t);\n'
                f'\t\t\tpath = {folder};\n\t\t\tsourceTree = "<group>";\n\t\t}};')
    return (f'{u} /* {folder} */ = {{\n'
            f'\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n'
            f'\t\t\tpath = {folder};\n\t\t\tsourceTree = "<group>";\n\t\t}};')

# ---- build files (linking) ----
# returns uid of a PBXBuildFile referencing fileRef `ref` in phase `phase`
def build_file(ref, label, embed=False):
    u = uid()
    if embed:
        add(u, f'{u} /* {label} in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {ref} /* {label} */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};')
    else:
        add(u, f'{u} /* {label} in Frameworks */ = {{isa = PBXBuildFile; fileRef = {ref} /* {label} */; }};')
    return u

# target -> list of (fileRef, label) to LINK
link_map = {
    "SyaiKit":       [(ext_frameworks["LoopKit"], "LoopKit.framework"),
                      (ext_frameworks["LoopKitUI"], "LoopKitUI.framework")],
    "SyaiKitUI":        [(product_ref["SyaiKit"], "SyaiKit.framework"),
                      (ext_frameworks["LoopKit"], "LoopKit.framework"),
                      (ext_frameworks["LoopKitUI"], "LoopKitUI.framework")],
    "SyaiKitPlugin": [(product_ref["SyaiKit"], "SyaiKit.framework"),
                      (product_ref["SyaiKitUI"], "SyaiKitUI.framework")],
    "SyaiKitTests":  [(product_ref["SyaiKit"], "SyaiKit.framework")],
}
# plugin embeds
embed_map = {
    "SyaiKitPlugin": [(product_ref["SyaiKit"], "SyaiKit.framework"),
                      (product_ref["SyaiKitUI"], "SyaiKitUI.framework")],
}

frameworks_phase = {}
link_build_files = {}
for tgt, links in link_map.items():
    bfs = [build_file(ref, label) for ref, label in links]
    link_build_files[tgt] = bfs
    u = uid()
    frameworks_phase[tgt] = u
    add(u, f'{u} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{arr(bfs)}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')

embed_phase = {}
for tgt, embeds in embed_map.items():
    bfs = [build_file(ref, label, embed=True) for ref, label in embeds]
    u = uid()
    embed_phase[tgt] = u
    add(u, f'{u} /* Embed Frameworks */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = "";\n\t\t\tdstSubfolderSpec = 10;\n\t\t\tfiles = (\n{arr(bfs)}\t\t\t);\n\t\t\tname = "Embed Frameworks";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')

# ---- empty Sources/Resources/Headers phases per target ----
sources_phase, resources_phase, headers_phase = {}, {}, {}
for tgt in products:
    su = uid(); sources_phase[tgt] = su
    add(su, f'{su} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
    ru = uid(); resources_phase[tgt] = ru
    add(ru, f'{ru} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
    if tgt != "SyaiKitTests":
        hu = uid(); headers_phase[tgt] = hu
        add(hu, f'{hu} /* Headers */ = {{\n\t\t\tisa = PBXHeadersBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')

# ---- dependencies (target + proxy) ----
project_uid = uid()
dep_map = {
    "SyaiKitUI":        ["SyaiKit"],
    "SyaiKitPlugin": ["SyaiKit", "SyaiKitUI"],
    "SyaiKitTests":  ["SyaiKit"],
}
target_uid = {tgt: uid() for tgt in products}
dependency_refs = {tgt: [] for tgt in products}
for tgt, deps in dep_map.items():
    for dep in deps:
        proxy = uid()
        add(proxy, f'{proxy} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {project_uid} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {target_uid[dep]};\n\t\t\tremoteInfo = {dep};\n\t\t}};')
        d = uid()
        add(d, f'{d} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {target_uid[dep]} /* {dep} */;\n\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n\t\t}};')
        dependency_refs[tgt].append(d)

# ---- build configurations ----
COMMON_WARNINGS = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.6;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tVERSIONING_SYSTEM = "apple-generic";
\t\t\t\tVERSION_INFO_PREFIX = "";"""

def project_cfg(name, debug):
    extra = ""
    if debug:
        extra = ('\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n'
                 '\t\t\t\tENABLE_TESTABILITY = YES;\n'
                 '\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n'
                 '\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t);\n'
                 '\t\t\t\tONLY_ACTIVE_ARCH = YES;\n'
                 '\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";\n'
                 '\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";\n')
    else:
        extra = ('\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";\n'
                 '\t\t\t\tENABLE_NS_ASSERTIONS = NO;\n'
                 '\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n'
                 '\t\t\t\tVALIDATE_PRODUCT = YES;\n')
    u = uid()
    add(u, f'{u} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{COMMON_WARNINGS}\n{extra}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};')
    return u

def target_cfg(name, tgt, debug):
    bundle = f"org.loopkit.{tgt}"
    lines = [
        "\t\t\t\tCODE_SIGN_STYLE = Automatic;",
        "\t\t\t\tCURRENT_PROJECT_VERSION = 1;",
        "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t\t\"@loader_path/Frameworks\",\n\t\t\t\t);",
        "\t\t\t\tMARKETING_VERSION = 1.0;",
        f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle};",
        "\t\t\t\tSWIFT_STRICT_CONCURRENCY = targeted;",
        "\t\t\t\tSWIFT_VERSION = 5.0;",
    ]
    if tgt in ("SyaiKit", "SyaiKitUI"):
        lines += [
            "\t\t\t\tDEFINES_MODULE = NO;",
            "\t\t\t\tDYLIB_COMPATIBILITY_VERSION = 1;",
            "\t\t\t\tDYLIB_CURRENT_VERSION = 1;",
            "\t\t\t\tDYLIB_INSTALL_NAME_BASE = \"@rpath\";",
            "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;",
            "\t\t\t\tINSTALL_PATH = \"$(LOCAL_LIBRARY_DIR)/Frameworks\";",
            "\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME:c99extidentifier)\";",
            "\t\t\t\tSKIP_INSTALL = YES;",
            "\t\t\t\tSUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";",
            "\t\t\t\tTARGETED_DEVICE_FAMILY = 1;",
        ]
    elif tgt == "SyaiKitPlugin":
        lines += [
            "\t\t\t\tDYLIB_COMPATIBILITY_VERSION = 1;",
            "\t\t\t\tDYLIB_CURRENT_VERSION = 1;",
            "\t\t\t\tDYLIB_INSTALL_NAME_BASE = \"@rpath\";",
            "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;",
            "\t\t\t\tINFOPLIST_FILE = SyaiKitPlugin/Info.plist;",
            "\t\t\t\tINSTALL_PATH = \"$(LOCAL_LIBRARY_DIR)/Frameworks\";",
            "\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME:c99extidentifier)\";",
            "\t\t\t\tSKIP_INSTALL = YES;",
            "\t\t\t\tSUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";",
            "\t\t\t\tTARGETED_DEVICE_FAMILY = 1;",
            "\t\t\t\tWRAPPER_EXTENSION = loopplugin;",
        ]
    else:  # tests
        lines += [
            "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;",
            "\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";",
            "\t\t\t\tSUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";",
            "\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";",
        ]
    u = uid()
    add(u, f'{u} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n' + "\n".join(lines) + f'\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};')
    return u

def cfg_list(name, debug_u, release_u):
    u = uid()
    add(u, f'{u} /* {name} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{debug_u} /* Debug */,\n\t\t\t\t{release_u} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};')
    return u

proj_dbg = project_cfg("Debug", True)
proj_rel = project_cfg("Release", False)
proj_cfg_list = cfg_list('Build configuration list for PBXProject "SyaiKit"', proj_dbg, proj_rel)

target_cfg_list = {}
for tgt in products:
    d = target_cfg("Debug", tgt, True)
    r = target_cfg("Release", tgt, False)
    target_cfg_list[tgt] = cfg_list(f'Build configuration list for PBXNativeTarget "{tgt}"', d, r)

# ---- native targets ----
for tgt in products:
    phases = []
    if tgt in headers_phase:
        phases.append(f"{headers_phase[tgt]} /* Headers */")
    phases.append(f"{sources_phase[tgt]} /* Sources */")
    phases.append(f"{frameworks_phase[tgt]} /* Frameworks */")
    phases.append(f"{resources_phase[tgt]} /* Resources */")
    if tgt in embed_phase:
        phases.append(f"{embed_phase[tgt]} /* Embed Frameworks */")
    deps = dependency_refs[tgt]
    ptype = "com.apple.product-type.bundle.unit-test" if tgt == "SyaiKitTests" else "com.apple.product-type.framework"
    sync = f"\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{sync_group[tgt]} /* {tgt} */,\n\t\t\t);\n"
    body = (f'{target_uid[tgt]} /* {tgt} */ = {{\n'
            f'\t\t\tisa = PBXNativeTarget;\n'
            f'\t\t\tbuildConfigurationList = {target_cfg_list[tgt]} /* Build configuration list for PBXNativeTarget "{tgt}" */;\n'
            f'\t\t\tbuildPhases = (\n' + arr(phases) + '\t\t\t);\n'
            f'\t\t\tbuildRules = (\n\t\t\t);\n'
            f'\t\t\tdependencies = (\n' + arr([f"{d} /* PBXTargetDependency */" for d in deps]) + '\t\t\t);\n'
            + sync +
            f'\t\t\tname = {tgt};\n'
            f'\t\t\tpackageProductDependencies = (\n\t\t\t);\n'
            f'\t\t\tproductName = {tgt};\n'
            f'\t\t\tproductReference = {product_ref[tgt]} /* {products[tgt][0]} */;\n'
            f'\t\t\tproductType = "{ptype}";\n'
            f'\t\t}};')
    add(target_uid[tgt], body)

# ---- groups ----
frameworks_group = uid()
add(frameworks_group, f'{frameworks_group} /* Frameworks */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + arr([f"{ext_frameworks[f]} /* {f}.framework */" for f in ("LoopKit","LoopKitUI")]) + '\t\t\t);\n\t\t\tname = Frameworks;\n\t\t\tsourceTree = "<group>";\n\t\t}};')

products_group = uid()
add(products_group, f'{products_group} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + arr([f"{product_ref[t]} /* {products[t][0]} */" for t in products]) + '\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};')

main_group = uid()
main_children = [f"{sync_group[f]} /* {f} */" for f in ("SyaiKit","SyaiKitUI","SyaiKitPlugin","SyaiKitTests")]
main_children += [f"{frameworks_group} /* Frameworks */", f"{products_group} /* Products */"]
add(main_group, f'{main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + arr(main_children) + '\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};')

# synced root groups (added after main_group so uids exist; content independent)
for folder, u in sync_group.items():
    add(u, sync_group_block(folder, u))
add(plugin_exc, f'{plugin_exc} /* Exceptions for "SyaiKitPlugin" folder */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n\t\t\tmembershipExceptions = (\n\t\t\t\tInfo.plist,\n\t\t\t);\n\t\t\ttarget = {target_uid["SyaiKitPlugin"]} /* SyaiKitPlugin */;\n\t\t}};')

# ---- project object ----
targets_order = ["SyaiKit", "SyaiKitUI", "SyaiKitPlugin", "SyaiKitTests"]
add(project_uid, f'{project_uid} /* Project object */ = {{\n'
    f'\t\t\tisa = PBXProject;\n'
    f'\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2600;\n\t\t\t\tLastUpgradeCheck = 2600;\n\t\t\t}};\n'
    f'\t\t\tbuildConfigurationList = {proj_cfg_list} /* Build configuration list for PBXProject "SyaiKit" */;\n'
    f'\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n'
    f'\t\t\tmainGroup = {main_group};\n'
    f'\t\t\tminimizedProjectReferenceProxies = 1;\n'
    f'\t\t\tpreferredProjectObjectVersion = 77;\n'
    f'\t\t\tproductRefGroup = {products_group} /* Products */;\n'
    f'\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n'
    f'\t\t\ttargets = (\n' + arr([f"{target_uid[t]} /* {t} */" for t in targets_order]) + '\t\t\t);\n\t\t}};')

# ---- emit ----
out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};",
       "\tobjectVersion = 77;", "\tobjects = {", ""]
for u in sorted(objs):
    out.append("\t\t" + objs[u])
out.append("\t};")
out.append(f"\trootObject = {project_uid} /* Project object */;")
out.append("}")
text = "\n".join(out) + "\n"
# A few group/project blocks closed with a plain-string "}};" (no f-string
# collapse). A valid pbxproj never contains "}};", so normalize safely.
text = text.replace("}};", "};")

import sys
path = sys.argv[1]
with open(path, "w") as f:
    f.write(text)

# ---- self-validation: every referenced uid must be defined ----
import re
defined = set(objs)
referenced = set(re.findall(r"\b(5741[0-9A-F]{20})\b", text))
missing = referenced - defined
print(f"objects: {len(objs)}  referenced-uids: {len(referenced)}  missing: {len(missing)}")
if missing:
    print("MISSING:", missing); sys.exit(1)
print("braces balance:", text.count("{") == text.count("}"), text.count("{"), text.count("}"))
print("parens balance:", text.count("(") == text.count(")"))

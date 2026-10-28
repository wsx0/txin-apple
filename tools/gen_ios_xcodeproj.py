#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_xcodeproj.py -- 扫描 ios/BeautyBox/ 目录，生成 Xcode 15+ 可直接打开的
ios/BeautyBox.xcodeproj/project.pbxproj 与共享 scheme。

用法:
    python tools/gen_xcodeproj.py            # 生成工程
    python tools/gen_xcodeproj.py --verify   # 生成并校验（需要 pip install pbxproj）
    python tools/gen_xcodeproj.py --verify-only

设计要点:
  * objectVersion = 56, 单 app target "BeautyBox", productType application
  * UUID = md5("<purpose>|<key>") 前 24 位十六进制 -> 幂等
  * Swift -> PBXSourcesBuildPhase；资源 -> PBXResourcesBuildPhase
  * 目录结构 1:1 映射为 PBXGroup 层级
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------- 常量

PROJECT_NAME = "TxinApp"
TARGET_NAME = "Txin"
BUNDLE_ID = "com.txin.ios"
DEPLOYMENT_TARGET = "16.0"
MARKETING_VERSION = "1.0.0"
PROJECT_VERSION = "1"
INFOPLIST_REL = "TxinApp/Resources/Info.plist"
OBJ_VERSION = 56
MIN_OBJECTS = 20   # 本工程只有 1 个 target + 14 个源文件，阈值不能照搬大工程
XCODE_COMPAT = "Xcode 14.0"   # 与 objectVersion 56 匹配, Xcode 15 可无损打开

# 目录型资源：整体引用，不递归展开
# 无扩展名但需要整体引用的目录（目录引用 = Xcode 里 blue folder，保留层级）
BUNDLE_DIR_NAMES = {
    "webapp",
}

BUNDLE_DIR_TYPES = {
    ".xcassets": "folder.assetcatalog",
    ".bundle": "folder",
    ".xcdatamodeld": "wrapper.xcdatamodeld",
    ".scnassets": "folder",
    ".atlas": "folder",
}

# 文件型资源 -> lastKnownFileType
RESOURCE_FILE_TYPES = {
    ".xcprivacy": "text.xml",
    ".json": "text.json",
    ".geojson": "text.json",
    ".plist": "text.plist.xml",
    ".strings": "text.plist.strings",
    ".stringsdict": "text.plist.stringsdict",
    ".xcstrings": "text.json.xcstrings",
    ".mp4": "file",
    ".mov": "file",
    ".m4a": "file",
    ".mp3": "file",
    ".wav": "file",
    ".caf": "file",
    ".aiff": "file",
    ".ttf": "file",
    ".otf": "file",
    ".ttc": "file",
    ".png": "image.png",
    ".jpg": "image.jpeg",
    ".jpeg": "image.jpeg",
    ".gif": "image.gif",
    ".pdf": "image.pdf",
    ".svg": "text.xml",
    ".html": "text.html",
    ".css": "text.css",
    ".js": "sourcecode.javascript",
    ".usdz": "file",
    ".reality": "file",
    ".scn": "file",
    ".storyboard": "file.storyboard",
    ".xib": "file.xib",
    ".entitlements": "text.plist.entitlements",
}

SOURCE_EXT = ".swift"

# 生成的 scheme 内 BlueprintIdentifier 由 target UUID 填充

# ---------------------------------------------------------------- UUID


class UuidFactory:
    """md5(用途 + 相对路径) -> 24 位大写十六进制，稳定且可复现。"""

    def __init__(self, namespace: str) -> None:
        self.namespace = namespace
        self.used: dict[str, str] = {}

    def make(self, purpose: str, key: str = "") -> str:
        raw = f"{self.namespace}|{purpose}|{key}".encode("utf-8")
        uid = hashlib.md5(raw).hexdigest()[:24].upper()
        prev = self.used.get(uid)
        if prev is not None and prev != f"{purpose}|{key}":
            raise RuntimeError(
                f"UUID 冲突: {uid} 已被 {prev} 占用，又分配给 {purpose}|{key}"
            )
        self.used[uid] = f"{purpose}|{key}"
        return uid


# ---------------------------------------------------------------- pbxproj 文本


_SAFE = re.compile(r"^[A-Za-z0-9_./$]+$")


def q(value: str) -> str:
    """pbxproj 标量引号化。"""
    if value == "":
        return '""'
    if _SAFE.match(value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def rel_posix(path: Path, base: Path) -> str:
    return path.relative_to(base).as_posix()


# ---------------------------------------------------------------- 扫描


class Item:
    __slots__ = ("rel", "name", "parent", "is_group", "file_type", "purpose", "uuid")

    def __init__(self, rel: str, is_group: bool, file_type: str, purpose: str) -> None:
        self.rel = rel
        self.name = rel.rsplit("/", 1)[-1]
        self.parent = rel.rsplit("/", 1)[0] if "/" in rel else ""
        self.is_group = is_group
        self.file_type = file_type
        self.purpose = purpose
        self.uuid = ""


class Scan:
    """扫描结果：swift 源文件 + 资源文件 + 目录集合。"""

    def __init__(self) -> None:
        self.sources: list[Item] = []
        self.resources: list[Item] = []
        self.dirs: set[str] = set()
        self.skipped: list[str] = []


def classify_file(name: str) -> tuple[str, str] | None:
    lower = name.lower()
    ext = os.path.splitext(lower)[1]
    if ext == SOURCE_EXT:
        return ("source", "sourcecode.swift")
    if name == "Info.plist":
        return None
    if ext in RESOURCE_FILE_TYPES:
        return ("resource", RESOURCE_FILE_TYPES[ext])
    return None


def scan_tree(root: Path) -> Scan:
    result = Scan()
    root = root.resolve()
    for dirpath, dirnames, filenames in os.walk(root):
        here = Path(dirpath)
        kept_dirs: list[str] = []
        for d in sorted(dirnames):
            full = here / d
            rel = rel_posix(full, root.parent)
            if d.startswith("."):
                result.skipped.append(f"{rel}/ (隐藏目录)")
                continue
            ext = os.path.splitext(d.lower())[1]
            if d in BUNDLE_DIR_NAMES:
                result.resources.append(
                    Item(rel, is_group=False, file_type="folder", purpose="resource")
                )
                result.skipped.append(f"{rel}/ (目录引用, 整体拷入 bundle)")
                continue
            if ext in BUNDLE_DIR_TYPES:
                result.resources.append(
                    Item(rel, is_group=False, file_type=BUNDLE_DIR_TYPES[ext], purpose="resource")
                )
                result.skipped.append(f"{rel}/ (整体资源目录, 不展开)")
                continue
            kept_dirs.append(d)
        dirnames[:] = kept_dirs

        for f in sorted(filenames):
            if f.startswith("."):
                continue
            full = here / f
            rel = rel_posix(full, root.parent)
            kind = classify_file(f)
            if kind is None:
                result.skipped.append(f"{rel} (未识别的扩展名, 忽略)")
                continue
            category, file_type = kind
            item = Item(rel, is_group=False, file_type=file_type, purpose=category)
            if category == "source":
                result.sources.append(item)
            else:
                result.resources.append(item)

    for item in result.sources + result.resources:
        parent = item.parent
        while parent:
            result.dirs.add(parent)
            parent = parent.rsplit("/", 1)[0] if "/" in parent else ""
    result.dirs.add(root.name)
    result.sources.sort(key=lambda i: i.rel)
    result.resources.sort(key=lambda i: i.rel)
    return result


# ---------------------------------------------------------------- 工程构建


BUILD_SETTINGS_TARGET_COMMON = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": PROJECT_VERSION,
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": INFOPLIST_REL,
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "MARKETING_VERSION": MARKETING_VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": TARGET_NAME,
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "1,2",
}

BUILD_SETTINGS_PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_COMMA": "YES",
    "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
    "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES",
    "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
    "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
    "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
    "CLANG_WARN_STRICT_PROTOTYPES": "YES",
    "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
    "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "MTL_FAST_MATH": "YES",
    "SDKROOT": "iphoneos",
}

BUILD_SETTINGS_PROJECT_DEBUG = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": '("DEBUG=1", "$(inherited)")',
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}

BUILD_SETTINGS_PROJECT_RELEASE = {
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
    "VALIDATE_PRODUCT": "YES",
}

BUILD_SETTINGS_TARGET_DEBUG = {
    "ENABLE_PREVIEWS": "YES",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}

BUILD_SETTINGS_TARGET_RELEASE = {
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
}


def settings_value(value: str) -> str:
    """buildSettings 值：数组/已引号化的原样输出，其余按需加引号。"""
    if value.startswith("(") or value.startswith('"'):
        return value
    return q(value)


def settings_block(name: str, settings: dict[str, str]) -> str:
    lines = [
        f"\t\t\t\t{key} = {settings_value(value)};"
        for key, value in sorted(settings.items())
    ]
    body = "\n".join(lines)
    return (
        f"\t\t{{uuid}} /* {name} */ = {{\n"
        f"\t\t\tisa = XCBuildConfiguration;\n"
        f"\t\t\tbuildSettings = {{\n{body}\n\t\t\t}};\n"
        f"\t\t\tname = {q(name)};\n"
        f"\t\t}};"
    )


class ProjectBuilder:
    def __init__(self, root: Path, scan: Scan) -> None:
        self.root = root            # ios/BeautyBox
        self.ios_dir = root.parent  # ios
        self.scan = scan
        self.uuids = UuidFactory(namespace=f"{PROJECT_NAME}.xcodeproj")
        self.target_uuid = self.uuids.make("target", TARGET_NAME)
        self.project_uuid = self.uuids.make("project", PROJECT_NAME)
        self.product_ref_uuid = self.uuids.make("product-ref", f"{TARGET_NAME}.app")
        self.main_group_uuid = self.uuids.make("group", "")
        self.products_group_uuid = self.uuids.make("group-products", "Products")
        self.sources_phase_uuid = self.uuids.make("phase", "Sources")
        self.resources_phase_uuid = self.uuids.make("phase", "Resources")
        self.frameworks_phase_uuid = self.uuids.make("phase", "Frameworks")
        self.list_target_uuid = self.uuids.make("configlist", f"target:{TARGET_NAME}")
        self.list_project_uuid = self.uuids.make("configlist", "project")
        self.cfg_target = {
            c: self.uuids.make("config", f"target:{TARGET_NAME}:{c}")
            for c in ("Debug", "Release")
        }
        self.cfg_project = {
            c: self.uuids.make("config", f"project:{c}") for c in ("Debug", "Release")
        }
        self.group_uuid: dict[str, str] = {}
        self._assign_uuids()

    # ---- UUID 分配
    def _assign_uuids(self) -> None:
        for rel in sorted(self.scan.dirs):
            self.group_uuid[rel] = self.uuids.make("group", rel)
        for item in self.scan.sources:
            item.uuid = self.uuids.make("fileref", item.rel)
        for item in self.scan.resources:
            item.uuid = self.uuids.make("fileref", item.rel)

    # ---- group 树
    def _children_of(self, group_rel: str) -> list[tuple[int, str, str, str]]:
        """(排序键, uuid, 注释, 类别)"""
        out: list[tuple[int, str, str, str]] = []
        for rel in self.scan.dirs:
            parent = rel.rsplit("/", 1)[0] if "/" in rel else ""
            if parent != group_rel:
                continue
            out.append((0, self.group_uuid[rel], rel.rsplit("/", 1)[-1], "group"))
        for item in self.scan.sources + self.scan.resources:
            if item.parent != group_rel:
                continue
            out.append((1, item.uuid, item.name, item.purpose))
        out.sort(key=lambda t: (t[0], t[2].lower(), t[2], t[1]))
        return out

    def _emit_group(self, rel: str) -> str:
        children = self._children_of(rel)
        child_lines = "".join(
            f"\t\t\t\t{uuid} /* {name} */,\n" for _, uuid, name, _ in children
        )
        if not child_lines:
            child_lines = ""
        return (
            f"\t\t{self.group_uuid[rel]} /* {rel.rsplit('/', 1)[-1]} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n{child_lines}\t\t\t);\n"
            f"\t\t\tpath = {q(rel.rsplit('/', 1)[-1])};\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )

    # ---- 各 section
    def _build_files(self) -> str:
        lines = []
        for item in self.scan.sources:
            bid = self.uuids.make("buildfile", f"source:{item.rel}")
            lines.append(
                f"\t\t{bid} /* {item.name} in Sources */ = {{isa = PBXBuildFile; "
                f"fileRef = {item.uuid} /* {item.name} */; }};"
            )
        for item in self.scan.resources:
            bid = self.uuids.make("buildfile", f"resource:{item.rel}")
            lines.append(
                f"\t\t{bid} /* {item.name} in Resources */ = {{isa = PBXBuildFile; "
                f"fileRef = {item.uuid} /* {item.name} */; }};"
            )
        return "\n".join(lines)

    def _file_refs(self) -> str:
        lines = [
            f"\t\t{self.product_ref_uuid} /* {TARGET_NAME}.app */ = "
            f"{{isa = PBXFileReference; explicitFileType = wrapper.application; "
            f"includeInIndex = 0; path = {q(TARGET_NAME + '.app')}; "
            f"sourceTree = BUILT_PRODUCTS_DIR; }};"
        ]
        for item in self.scan.sources:
            lines.append(
                f"\t\t{item.uuid} /* {item.name} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = {item.file_type}; path = {q(item.name)}; "
                f"sourceTree = \"<group>\"; }};"
            )
        for item in self.scan.resources:
            lines.append(
                f"\t\t{item.uuid} /* {item.name} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = {item.file_type}; path = {q(item.name)}; "
                f"sourceTree = \"<group>\"; }};"
            )
        return "\n".join(lines)

    def _groups(self) -> str:
        chunks: list[str] = []
        main_children = ""
        for rel in sorted(self.scan.dirs):
            if rel.count("/") > 0:
                continue
            main_children += f"\t\t\t\t{self.group_uuid[rel]} /* {rel} */,\n"
        chunks.append(
            f"\t\t{self.main_group_uuid} = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n"
            f"{main_children}"
            f"\t\t\t\t{self.products_group_uuid} /* Products */,\n"
            f"\t\t\t);\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )
        chunks.append(
            f"\t\t{self.products_group_uuid} /* Products */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n"
            f"\t\t\t\t{self.product_ref_uuid} /* {TARGET_NAME}.app */,\n"
            f"\t\t\t);\n"
            f"\t\t\tname = Products;\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )
        for rel in sorted(self.scan.dirs):
            chunks.append(self._emit_group(rel))
        return "\n".join(chunks)

    def _sources_phase(self) -> str:
        src = "".join(
            f"\t\t\t\t{self.uuids.make('buildfile', 'source:' + i.rel)} /* {i.name} in Sources */,\n"
            for i in self.scan.sources
        )
        return (
            f"\t\t{self.sources_phase_uuid} /* Sources */ = {{\n"
            f"\t\t\tisa = PBXSourcesBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n{src}\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            f"\t\t}};"
        )

    def _frameworks_phase(self) -> str:
        return (
            f"\t\t{self.frameworks_phase_uuid} /* Frameworks */ = {{\n"
            f"\t\t\tisa = PBXFrameworksBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            f"\t\t}};"
        )

    def _resources_phase(self) -> str:
        res = "".join(
            f"\t\t\t\t{self.uuids.make('buildfile', 'resource:' + i.rel)} /* {i.name} in Resources */,\n"
            for i in self.scan.resources
        )
        return (
            f"\t\t{self.resources_phase_uuid} /* Resources */ = {{\n"
            f"\t\t\tisa = PBXResourcesBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n{res}\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            f"\t\t}};"
        )

    def _target(self) -> str:
        return (
            f"\t\t{self.target_uuid} /* {TARGET_NAME} */ = {{\n"
            f"\t\t\tisa = PBXNativeTarget;\n"
            f"\t\t\tbuildConfigurationList = {self.list_target_uuid} "
            f"/* Build configuration list for PBXNativeTarget \"{TARGET_NAME}\" */;\n"
            f"\t\t\tbuildPhases = (\n"
            f"\t\t\t\t{self.sources_phase_uuid} /* Sources */,\n"
            f"\t\t\t\t{self.frameworks_phase_uuid} /* Frameworks */,\n"
            f"\t\t\t\t{self.resources_phase_uuid} /* Resources */,\n"
            f"\t\t\t);\n"
            f"\t\t\tbuildRules = (\n\t\t\t);\n"
            f"\t\t\tdependencies = (\n\t\t\t);\n"
            f"\t\t\tname = {TARGET_NAME};\n"
            f"\t\t\tproductName = {TARGET_NAME};\n"
            f"\t\t\tproductReference = {self.product_ref_uuid} /* {TARGET_NAME}.app */;\n"
            f"\t\t\tproductType = \"com.apple.product-type.application\";\n"
            f"\t\t}};"
        )

    def _project(self) -> str:
        return (
            f"\t\t{self.project_uuid} /* Project object */ = {{\n"
            f"\t\t\tisa = PBXProject;\n"
            f"\t\t\tattributes = {{\n"
            f"\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
            f"\t\t\t\tLastSwiftUpdateCheck = 1500;\n"
            f"\t\t\t\tLastUpgradeCheck = 1500;\n"
            f"\t\t\t\tTargetAttributes = {{\n"
            f"\t\t\t\t\t{self.target_uuid} = {{\n"
            f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
            f"\t\t\t\t\t}};\n"
            f"\t\t\t\t}};\n"
            f"\t\t\t}};\n"
            f"\t\t\tbuildConfigurationList = {self.list_project_uuid} "
            f"/* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;\n"
            f"\t\t\tcompatibilityVersion = \"{XCODE_COMPAT}\";\n"
            f"\t\t\tdevelopmentRegion = en;\n"
            f"\t\t\thasScannedForEncodings = 0;\n"
            f"\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
            f"\t\t\tmainGroup = {self.main_group_uuid};\n"
            f"\t\t\tproductRefGroup = {self.products_group_uuid} /* Products */;\n"
            f"\t\t\tprojectDirPath = \"\";\n"
            f"\t\t\tprojectRoot = \"\";\n"
            f"\t\t\ttargets = (\n"
            f"\t\t\t\t{self.target_uuid} /* {TARGET_NAME} */,\n"
            f"\t\t\t);\n"
            f"\t\t}};"
        )

    def _configs(self) -> str:
        project_common = dict(BUILD_SETTINGS_PROJECT_COMMON)
        target_common = dict(BUILD_SETTINGS_TARGET_COMMON)
        blocks = []
        for cfg in ("Debug", "Release"):
            project_settings = dict(project_common)
            project_settings.update(
                BUILD_SETTINGS_PROJECT_DEBUG if cfg == "Debug" else BUILD_SETTINGS_PROJECT_RELEASE
            )
            blocks.append(
                settings_block(cfg, project_settings).replace(
                    "{uuid}", self.cfg_project[cfg]
                )
            )
        for cfg in ("Debug", "Release"):
            target_settings = dict(target_common)
            target_settings.update(
                BUILD_SETTINGS_TARGET_DEBUG if cfg == "Debug" else BUILD_SETTINGS_TARGET_RELEASE
            )
            blocks.append(
                settings_block(cfg, target_settings).replace(
                    "{uuid}", self.cfg_target[cfg]
                )
            )
        return "\n".join(blocks)

    def _config_lists(self) -> str:
        return "\n".join(
            [
                f"\t\t{self.list_project_uuid} "
                f"/* Build configuration list for PBXProject \"{PROJECT_NAME}\" */ = {{\n"
                f"\t\t\tisa = XCConfigurationList;\n"
                f"\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{self.cfg_project['Debug']} /* Debug */,\n"
                f"\t\t\t\t{self.cfg_project['Release']} /* Release */,\n"
                f"\t\t\t);\n"
                f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
                f"\t\t\tdefaultConfigurationName = Release;\n"
                f"\t\t}};",
                f"\t\t{self.list_target_uuid} "
                f"/* Build configuration list for PBXNativeTarget \"{TARGET_NAME}\" */ = {{\n"
                f"\t\t\tisa = XCConfigurationList;\n"
                f"\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{self.cfg_target['Debug']} /* Debug */,\n"
                f"\t\t\t\t{self.cfg_target['Release']} /* Release */,\n"
                f"\t\t\t);\n"
                f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
                f"\t\t\tdefaultConfigurationName = Release;\n"
                f"\t\t}};",
            ]
        )

    # ---- 汇总
    def render(self) -> str:
        parts = [
            "// !$*UTF8*$!",
            "{",
            "\tarchiveVersion = 1;",
            "\tclasses = {",
            "\t};",
            f"\tobjectVersion = {OBJ_VERSION};",
            "\tobjects = {",
            "",
            "/* Begin PBXBuildFile section */",
            self._build_files(),
            "/* End PBXBuildFile section */",
            "",
            "/* Begin PBXFileReference section */",
            self._file_refs(),
            "/* End PBXFileReference section */",
            "",
            "/* Begin PBXFrameworksBuildPhase section */",
            self._frameworks_phase(),
            "/* End PBXFrameworksBuildPhase section */",
            "",
            "/* Begin PBXGroup section */",
            self._groups(),
            "/* End PBXGroup section */",
            "",
            "/* Begin PBXNativeTarget section */",
            self._target(),
            "/* End PBXNativeTarget section */",
            "",
            "/* Begin PBXProject section */",
            self._project(),
            "/* End PBXProject section */",
            "",
            "/* Begin PBXResourcesBuildPhase section */",
            self._resources_phase(),
            "/* End PBXResourcesBuildPhase section */",
            "",
            "/* Begin PBXSourcesBuildPhase section */",
            self._sources_phase(),
            "/* End PBXSourcesBuildPhase section */",
            "",
            "/* Begin XCBuildConfiguration section */",
            self._configs(),
            "/* End XCBuildConfiguration section */",
            "",
            "/* Begin XCConfigurationList section */",
            self._config_lists(),
            "/* End XCConfigurationList section */",
            "",
            "\t};",
            f"\trootObject = {self.project_uuid} /* Project object */;",
            "}",
            "",
        ]
        return "\n".join(parts)


SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
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
               BlueprintIdentifier = "{target_uuid}"
               BuildableName = "{target}.app"
               BlueprintName = "{target}"
               ReferencedContainer = "container:{project}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
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
            BlueprintIdentifier = "{target_uuid}"
            BuildableName = "{target}.app"
            BlueprintName = "{target}"
            ReferencedContainer = "container:{project}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
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
            BlueprintIdentifier = "{target_uuid}"
            BuildableName = "{target}.app"
            BlueprintName = "{target}"
            ReferencedContainer = "container:{project}.xcodeproj">
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


# ---------------------------------------------------------------- 生成入口


def write_project(ios_dir: Path, root: Path, scan: Scan, verbose: bool = True) -> tuple[Path, int]:
    builder = ProjectBuilder(root, scan)
    pbxproj_text = builder.render()
    proj_dir = ios_dir / f"{PROJECT_NAME}.xcodeproj"
    scheme_dir = proj_dir / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    pbxproj_path = proj_dir / "project.pbxproj"
    data = pbxproj_text.encode("utf-8")
    pbxproj_path.write_bytes(data)
    scheme_path = scheme_dir / f"{TARGET_NAME}.xcscheme"
    scheme_path.write_text(
        SCHEME_TEMPLATE.format(
            target_uuid=builder.target_uuid, target=TARGET_NAME, project=PROJECT_NAME
        ),
        encoding="utf-8",
        newline="\n",
    )
    # 便于 Xcode 识别为工程包
    (proj_dir / "project.xcworkspace").mkdir(exist_ok=True)
    (proj_dir / "project.xcworkspace" / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace version = "1.0">\n'
        '   <FileRef location = "self:">\n'
        "   </FileRef>\n"
        "</Workspace>\n",
        encoding="utf-8",
        newline="\n",
    )
    if verbose:
        print(f"[gen] target 数        : 1 ({TARGET_NAME})")
        print(f"[gen] source 文件数    : {len(scan.sources)}")
        print(f"[gen] resource 文件数  : {len(scan.resources)}")
        print(f"[gen] pbxproj 字节数   : {len(data)}")
        print(f"[gen] 输出              : {pbxproj_path}")
        print(f"[gen] scheme            : {scheme_path}")
    return pbxproj_path, len(data)


# ---------------------------------------------------------------- 校验


def _ensure_pbxproj_lib() -> bool:
    try:
        import pbxproj  # noqa: F401
        return True
    except ImportError:
        print("[verify] 缺少 pbxproj 包，尝试 pip install pbxproj ...")
        cmd_base = [sys.executable, "-m", "pip", "install", "--quiet", "--disable-pip-version-check"]
        for extra in (["--break-system-packages"], ["--user"], []):
            try:
                subprocess.run(cmd_base + extra + ["pbxproj"], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                break
            except Exception:  # noqa: BLE001
                continue
        try:
            import pbxproj  # noqa: F401
            return True
        except ImportError:
            print("[verify] WARN: pbxproj 装不上（受限环境），退化为轻量校验")
            return False


def clean_id(value) -> str:
    """pbxproj 库把注释一起塞进 _id，例如 "ABC... /* X */"，这里剥掉注释。"""
    text = str(value) if value is not None else ""
    if "/*" in text:
        text = text.split("/*", 1)[0]
    return text.strip().strip('"')


def bs_get(settings, key: str):
    """pbxproj 的 PBXGenericObject.get 需要 default 参数，这里统一封装。"""
    if settings is None:
        return None
    try:
        return settings.get(key, None)
    except TypeError:
        pass
    try:
        return getattr(settings, key, None)
    except Exception:  # noqa: BLE001
        return None


def verify_lite(pbxproj_path: Path, scan: Scan) -> int:
    """没有 pbxproj 库时的兜底校验：纯文本断言，够挡住生成不完整。"""
    text = pbxproj_path.read_text(encoding="utf-8")
    failures = []
    objects = text.count("isa = ")
    if objects <= MIN_OBJECTS:
        failures.append(f"对象数 {objects} 不大于 {MIN_OBJECTS}")
    if f"/* {TARGET_NAME} */ = {{" not in text:
        failures.append(f"未找到 target {TARGET_NAME}")
    if "com.apple.product-type.application" not in text:
        failures.append("缺少 com.apple.product-type.application")
    if "PRODUCT_BUNDLE_IDENTIFIER" not in text:
        failures.append("缺少 PRODUCT_BUNDLE_IDENTIFIER")
    missing = [i.name for i in scan.sources if i.name not in text]
    if missing:
        failures.append(f"{len(missing)} 个 swift 未进工程: {missing[:3]}")
    print(f"[verify-lite] object≈{objects} sources={len(scan.sources)} resources={len(scan.resources)}")
    if failures:
        for f in failures:
            print(f"[verify-lite] FAIL: {f}")
        return 1
    print("[verify-lite] OK")
    return 0


def verify(ios_dir: Path, root: Path, scan: Scan) -> int:
    """返回 0 表示全部断言通过。"""
    pbxproj_path = ios_dir / f"{PROJECT_NAME}.xcodeproj" / "project.pbxproj"
    if not pbxproj_path.exists():
        print(f"[verify] FAIL: 工程文件不存在: {pbxproj_path}")
        return 1
    if not _ensure_pbxproj_lib():
        return verify_lite(pbxproj_path, scan)

    from pbxproj import XcodeProject

    project = XcodeProject.load(str(pbxproj_path))
    if project is None:
        print("[verify] FAIL: pbxproj 解析返回 None（文件格式可能损坏）")
        return 1

    failures: list[str] = []
    objects = project.objects
    # 注意：PBXObjects 没有可靠的 __len__（它继承自 dict），必须逐 section 计数
    object_count = 0
    try:
        for section_name in objects.get_sections():
            object_count += len(list(objects.get_objects_in_section(section_name)))
    except Exception:  # noqa: BLE001
        object_count = 0

    def section(name: str) -> list:
        try:
            return list(objects.get_objects_in_section(name))
        except Exception as exc:  # noqa: BLE001
            print(f"[verify] 读取 {name} 失败: {exc}")
            return []

    # 断言 1: 对象数 > MIN_OBJECTS（小工程也合法，只是防止空工程）
    if object_count <= MIN_OBJECTS:
        failures.append(f"对象数 {object_count} 不大于 {MIN_OBJECTS}（工程过小或生成不完整）")

    # 断言 2: BeautyBox target 存在且类型正确
    targets = section("PBXNativeTarget")
    target_objs = [t for t in targets if getattr(t, "name", None) == TARGET_NAME]
    if not target_objs:
        failures.append(f"未找到名为 {TARGET_NAME} 的 PBXNativeTarget（现有: "
                        f"{[getattr(t, 'name', '?') for t in targets]}）")
    else:
        ptype = getattr(target_objs[0], "productType", "")
        if ptype != "com.apple.product-type.application":
            failures.append(
                f"target {TARGET_NAME} 的 productType = {ptype!r}，"
                f"期望 com.apple.product-type.application"
            )

    # 断言 3: 每个 swift 文件都出现在某个 PBXBuildFile 里
    refs = {clean_id(getattr(r, "_id", None)): r for r in section("PBXFileReference")}
    groups = section("PBXGroup")
    parent_of: dict[str, str] = {}
    for g in groups:
        gid = clean_id(getattr(g, "_id", None))
        for child in getattr(g, "children", []) or []:
            parent_of[clean_id(child)] = gid

    path_by_id: dict[str, str] = {}
    for rid, robj in refs.items():
        p = getattr(robj, "path", None)
        if p:
            path_by_id[rid] = str(p)
    for grp in groups:
        p = getattr(grp, "path", None)
        if p:
            path_by_id[clean_id(getattr(grp, "_id", None))] = str(p)

    def resolve(ref_id: str) -> str:
        parts: list[str] = []
        cur = clean_id(ref_id)
        guard = 0
        while cur and guard < 64:
            guard += 1
            p = path_by_id.get(cur)
            if p:
                parts.append(p)
            parent = parent_of.get(cur)
            if not parent:
                break
            cur = parent
        return "/".join(reversed(parts))

    built: set[str] = set()
    for bf in section("PBXBuildFile"):
        ref_id = getattr(bf, "fileRef", None)
        if ref_id is None:
            continue
        built.add(resolve(ref_id))

    expected = {item.rel for item in scan.sources}
    missing = sorted(expected - built)
    if missing:
        failures.append(
            "以下 swift 文件没有出现在任何 PBXBuildFile 中: " + ", ".join(missing)
        )

    # 断言 4: PRODUCT_BUNDLE_IDENTIFIER 正确（target 级 Debug/Release 都要对）
    cfg_ids: list[str] = []
    if target_objs:
        list_id = clean_id(getattr(target_objs[0], "buildConfigurationList", None))
        for cl in section("XCConfigurationList"):
            if clean_id(getattr(cl, "_id", "")) == list_id:
                cfg_ids = [
                    clean_id(x) for x in (getattr(cl, "buildConfigurations", []) or [])
                ]
                break
    configs = {clean_id(getattr(c, "_id", "")): c for c in section("XCBuildConfiguration")}
    seen_cfgs = 0
    for cid in cfg_ids:
        cfg = configs.get(cid)
        if cfg is None:
            failures.append(f"target 引用的配置对象 {cid} 不存在")
            continue
        seen_cfgs += 1
        settings = getattr(cfg, "buildSettings", None)
        value = bs_get(settings, "PRODUCT_BUNDLE_IDENTIFIER")
        if value != BUNDLE_ID:
            failures.append(
                f"配置 {getattr(cfg, 'name', cid)} 的 PRODUCT_BUNDLE_IDENTIFIER = {value!r}，"
                f"期望 {BUNDLE_ID!r}"
            )
        for required in ("INFOPLIST_FILE", "SWIFT_VERSION", "IPHONEOS_DEPLOYMENT_TARGET",
                         "GENERATE_INFOPLIST_FILE", "ASSETCATALOG_COMPILER_APPICON_NAME",
                         "ENABLE_USER_SCRIPT_SANDBOXING", "TARGETED_DEVICE_FAMILY",
                         "MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
            if bs_get(settings, required) is None:
                failures.append(f"配置 {getattr(cfg, 'name', cid)} 缺少 {required}")
    if not cfg_ids:
        failures.append(f"target {TARGET_NAME} 没有 XCConfigurationList")

    # 附加：引用完整性（所有 24 位 UUID 引用都必须有定义）
    text = pbxproj_path.read_text(encoding="utf-8", errors="replace")
    defined = {
        m.group(1)
        for m in re.finditer(r"^\t\t([0-9A-F]{24})\b.*?= \{", text, re.MULTILINE)
    }
    referenced = set(re.findall(r"\b([0-9A-F]{24})\b", text))
    dangling = sorted(referenced - defined)
    if dangling:
        failures.append(f"存在未定义对象的 UUID 引用: {', '.join(dangling[:10])}")

    # 附加：scheme 存在
    scheme_path = (
        ios_dir / f"{PROJECT_NAME}.xcodeproj" / "xcshareddata" / "xcschemes"
        / f"{TARGET_NAME}.xcscheme"
    )
    if not scheme_path.exists():
        failures.append(f"共享 scheme 不存在: {scheme_path}")

    if failures:
        print("[verify] FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("[verify] OK")
    print(f"  object 数            : {object_count}")
    print(f"  target               : {TARGET_NAME} (com.apple.product-type.application)")
    print(f"  swift 全部进入 Sources: {len(expected)}/{len(expected)}")
    print(f"  PRODUCT_BUNDLE_IDENTIFIER: {BUNDLE_ID}（Debug/Release 共 {seen_cfgs} 份配置）")
    return 0


# ---------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
            sys.stderr.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass

    here = Path(__file__).resolve().parent
    default_ios = here.parent / "ios"

    parser = argparse.ArgumentParser(
        description="生成 Xcode 15 工程（BeautyBox）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--ios-dir", default=str(default_ios), help="ios 目录（默认 <repo>/ios）")
    parser.add_argument("--verify", action="store_true", help="生成后立刻用 pbxproj 解析校验")
    parser.add_argument("--verify-only", action="store_true", help="只校验已存在的工程")
    parser.add_argument("--quiet", action="store_true", help="只打印统计")
    args = parser.parse_args(argv)

    ios_dir = Path(args.ios_dir).resolve()
    root = ios_dir / PROJECT_NAME

    if args.verify_only:
        if not root.is_dir():
            print(f"[gen] FAIL: 源目录不存在: {root}")
            return 1
        scan = scan_tree(root)
        return verify(ios_dir, root, scan)

    if not root.is_dir():
        print(f"[gen] FAIL: 源目录不存在: {root}")
        print(f"[gen]        先准备 {root}（例如 BeautyBox/App/BeautyBoxApp.swift）后重跑。")
        return 1

    scan = scan_tree(root)
    if not scan.sources:
        print(f"[gen] 警告: {root} 下没有 .swift 文件，Sources 阶段将为空")

    pbxproj_path, size = write_project(ios_dir, root, scan, verbose=not args.quiet)
    print(
        f"[gen] 统计: targets=1 sources={len(scan.sources)} "
        f"resources={len(scan.resources)} pbxproj_bytes={size}"
    )

    if args.verify:
        return verify(ios_dir, root, scan)
    return 0


if __name__ == "__main__":
    sys.exit(main())

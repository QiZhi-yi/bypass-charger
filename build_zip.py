#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
打包自动旁路供电模块为 Magisk / KernelSU 可安装的 zip。

用法:
    python build_zip.py

输出:
    自动旁路供电_v<版本>.zip

注意:
    zip 内路径必须用正斜杠。Windows 的 Compress-Archive 会写成反斜杠，
    Android 端解压时会被当成单个文件名，导致模块安装失败。
"""

import os
import sys
import zipfile

BASE = os.path.dirname(os.path.abspath(__file__))

# (zip 内路径, 仓库内相对路径候选列表)
FILES = [
    ("META-INF/com/google/android/update-binary", [
        "stage/META-INF/com/google/android/update-binary",
        "META-INF/com/google/android/update-binary",
    ]),
    ("META-INF/com/google/android/updater-script", [
        "stage/META-INF/com/google/android/updater-script",
        "META-INF/com/google/android/updater-script",
    ]),
    ("module.prop",        ["module.prop"]),
    ("customize.sh",       ["customize.sh"]),
    ("service.sh",         ["service.sh"]),
    ("auto_bypass.sh",     ["auto_bypass.sh"]),
    ("webui.sh",           ["webui.sh"]),
    ("webroot/index.html", ["webroot/index.html"]),
]

EXEC_EXT = (".sh",)


def read_version():
    """从 module.prop 读取版本号"""
    path = os.path.join(BASE, "module.prop")
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("version="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return "dev"


def resolve(candidates):
    for rel in candidates:
        p = os.path.join(BASE, rel.replace("/", os.sep))
        if os.path.isfile(p):
            return p
    return None


def main():
    version = read_version()
    out = os.path.join(BASE, "自动旁路供电_%s.zip" % version)

    entries = []
    for arc, candidates in FILES:
        src = resolve(candidates)
        if src is None:
            print("缺少文件: %s" % candidates[0], file=sys.stderr)
            return 1
        entries.append((arc, src))

    if os.path.exists(out):
        os.remove(out)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for arc, src in entries:
            zi = zipfile.ZipInfo(arc)          # 正斜杠，Linux 端解压正常
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (0o755 if arc.endswith(EXEC_EXT) else 0o644) << 16
            zi.create_system = 3               # Unix，让权限位生效
            with open(src, "rb") as f:
                z.writestr(zi, f.read())

    print("打包完成: %s" % os.path.basename(out))
    print("大小: %d 字节" % os.path.getsize(out))
    for arc, src in entries:
        print("  %-46s %7d" % (arc, os.path.getsize(src)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

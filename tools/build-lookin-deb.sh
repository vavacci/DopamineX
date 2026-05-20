#!/usr/bin/env bash
# build-lookin-deb.sh — 在 macOS 上构建 LookinRootless 的 fat (arm64 + arm64e) .deb，
# 直接产出到 preload-input/60-lookin/lookin.deb。
#
# 为什么要在 Mac 上跑：
#   arm64e 切片只有 Apple 的 ld64 能产出，Linux 的 lld 不支持。
#   没有 arm64e 切片的 tweak 注不进系统 app（SpringBoard / 设置 / 自带应用
#   在 A12+ 设备上是 arm64e 进程）。本机 Linux 之前只能出 arm64-only。
#
# 这个脚本会自动：
#   1. clone DargonLee/LookinRootless 源码
#   2. 修 control 里上游笔误的 Architecture (iphoneos-arm → iphoneos-arm64)
#   3. 强制 ARCHS = arm64 arm64e（出 fat）
#   4. 对 LookinServer.framework 二进制做 ad-hoc 签名（上游 commit 的是未签名的，
#      不签 AMFI 会拒 dlopen）
#   5. theos 打包，把 lookin.deb 落到 preload-input/60-lookin/
#
# 用法（在 Mac 上、DopamineX 仓库内）：
#   ./tools/build-lookin-deb.sh
#
# 前置：
#   - macOS + Xcode 命令行工具
#   - theos（https://theos.dev/docs/installation）。脚本会自动找 $THEOS 或 ~/theos。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DEST_DIR="$ROOT/preload-input/60-lookin"
DEST_DEB="$DEST_DIR/lookin.deb"
WORK_DIR="$ROOT/build/lookin-build"
SRC_DIR="$WORK_DIR/LookinRootless"
REPO_URL="https://github.com/DargonLee/LookinRootless"

# ─── 环境检查 ────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: 这个脚本必须在 macOS 上跑（arm64e 链接需要 Apple 工具链）。" >&2
    echo "       Linux 上只能出 arm64-only，注不进系统 app。" >&2
    exit 1
fi

THEOS="${THEOS:-$HOME/theos}"
if [[ ! -f "$THEOS/makefiles/common.mk" ]]; then
    echo "ERROR: 找不到 theos（查了 \$THEOS 和 ~/theos）。" >&2
    echo "       安装：bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)\"" >&2
    echo "       或设环境变量：export THEOS=/path/to/theos" >&2
    exit 1
fi
export THEOS
echo "[env] THEOS = $THEOS"

# 找一个 ad-hoc 签名工具：优先 theos 自带 ldid，其次 PATH 上的 ldid，最后 codesign
SIGN_TOOL=""
if [[ -x "$THEOS/bin/ldid" ]]; then
    SIGN_TOOL="$THEOS/bin/ldid"
elif command -v ldid >/dev/null 2>&1; then
    SIGN_TOOL="$(command -v ldid)"
elif command -v codesign >/dev/null 2>&1; then
    SIGN_TOOL="codesign"
else
    echo "ERROR: 找不到 ldid 也找不到 codesign，无法给 framework 签名。" >&2
    exit 1
fi
echo "[env] 签名工具 = $SIGN_TOOL"

if [[ ! -d "$DEST_DIR" ]]; then
    echo "ERROR: $DEST_DIR 不存在 —— 你是不是没在 DopamineX 仓库根目录下跑？" >&2
    exit 1
fi

# ─── 1. 获取源码 ─────────────────────────────────────────────────
mkdir -p "$WORK_DIR"
if [[ -d "$SRC_DIR/.git" ]]; then
    echo "[src] 已有 clone，更新中…"
    git -C "$SRC_DIR" fetch --depth 1 origin >/dev/null 2>&1
    git -C "$SRC_DIR" reset --hard origin/HEAD >/dev/null 2>&1
    git -C "$SRC_DIR" clean -fdx >/dev/null 2>&1
else
    echo "[src] clone $REPO_URL …"
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1
fi

cd "$SRC_DIR"

# ─── 2. 修 control 的 Architecture 笔误 ──────────────────────────
if grep -q '^Architecture: iphoneos-arm$' control 2>/dev/null; then
    echo "[fix] control: Architecture iphoneos-arm → iphoneos-arm64"
    sed -i '' 's/^Architecture: iphoneos-arm$/Architecture: iphoneos-arm64/' control
fi

# ─── 3. 强制 ARCHS = arm64 arm64e ───────────────────────────────
# 出 fat：arm64 给三方 app，arm64e 给系统 app（SpringBoard / 自带应用）。
if grep -qE '^ARCHS\s*=' Makefile; then
    echo "[fix] Makefile: ARCHS = arm64 arm64e"
    sed -i '' -E 's/^ARCHS[[:space:]]*=.*/ARCHS = arm64 arm64e/' Makefile
else
    echo "ARCHS = arm64 arm64e" >> Makefile
fi

# ─── 4. 给 LookinServer.framework 二进制 ad-hoc 签名 ─────────────
FW="layout/Library/Application Support/LookinLoader/LookinServer.framework/LookinServer"
if [[ ! -f "$FW" ]]; then
    echo "ERROR: 找不到 framework 二进制：$FW" >&2
    echo "       上游仓库结构可能变了，需要手动排查。" >&2
    exit 1
fi
echo "[sign] ad-hoc 签名 $FW"
if [[ "$(basename "$SIGN_TOOL")" == "codesign" ]]; then
    codesign --remove-signature "$FW" >/dev/null 2>&1 || true
    codesign -f -s - "$FW"
else
    "$SIGN_TOOL" -S "$FW"
fi

# ─── 5. theos 打包 ──────────────────────────────────────────────
echo "[build] make package FINALPACKAGE=1 …"
make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1

# theos 把 deb 落在 ./packages/；取非 +debug 的那个
BUILT_DEB="$(find packages -maxdepth 1 -name 'com.yourcompany.lookinloaderrootless_*_iphoneos-arm64.deb' \
    ! -name '*+debug*' -type f 2>/dev/null | sort | tail -1)"
if [[ -z "$BUILT_DEB" ]]; then
    echo "ERROR: theos 没产出 deb，检查上面的 make 输出。" >&2
    exit 1
fi
echo "[build] 产物: $BUILT_DEB"

# ─── 6. 验证 fat + 签名，然后落到 preload-input ──────────────────
VERIFY_DIR="$WORK_DIR/verify"
rm -rf "$VERIFY_DIR"; mkdir -p "$VERIFY_DIR"
dpkg-deb -x "$BUILT_DEB" "$VERIFY_DIR"
TW_OUT="$VERIFY_DIR/var/jb/Library/MobileSubstrate/DynamicLibraries/LookinLoaderRootless.dylib"
FW_OUT="$VERIFY_DIR/var/jb/Library/Application Support/LookinLoader/LookinServer.framework/LookinServer"

echo
echo "==================== verify ===================="
if command -v lipo >/dev/null 2>&1; then
    echo "tweak  dylib 架构: $(lipo -archs "$TW_OUT" 2>/dev/null)"
    echo "Lookin frmwk 架构: $(lipo -archs "$FW_OUT" 2>/dev/null)"
    if ! lipo -archs "$TW_OUT" 2>/dev/null | grep -q arm64e; then
        echo "WARN: tweak dylib 没有 arm64e 切片 —— 系统 app 仍注不进。检查 theos 工具链。" >&2
    fi
fi
if command -v codesign >/dev/null 2>&1; then
    codesign -dv "$FW_OUT" >/dev/null 2>&1 \
        && echo "Lookin frmwk 签名: OK" \
        || echo "WARN: Lookin framework 仍无签名" >&2
fi

cp -a "$BUILT_DEB" "$DEST_DEB"
echo
echo "✅ 已写入 $DEST_DEB"
echo
echo "下一步："
echo "  1. bash tools/build-preload-debs.sh      # 重生成 Resources/ + header"
echo "  2. git add preload-input/60-lookin/lookin.deb && git commit && git push"
echo "  3. make -C Application                   # 出新 .tipa"
echo "  装机后系统 app 也能在 LookinLoader 面板里勾选并注入。"

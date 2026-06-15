#!/usr/bin/env bash
# build-roothide.sh — 一键生成 roothide 版 Dopamine2.tipa。
#
# 与 upstream 的 ./tools/macos-build.sh 是【两个独立入口】：
#   upstream 版：  ./tools/macos-build.sh
#   roothide 版：  ./tools/build-roothide.sh   ← 本脚本
#
# 它做两件事：
#   1) 确保 Dopamine2-roothide/ 树存在且已打 preload patch（没有就自动跑 setup-roothide-tree.sh）
#   2) 以 TARGET=roothide 复用 macos-build.sh 的构建引擎。
#
# 【现代化说明】本脚本不再切换 Xcode，直接用你当前的 Xcode（含 Xcode 26）本地编译。
#   roothide 工具链对新 SDK 的两处适配已就位：
#     - BaseBin/Makefile 在 iOS 17.4+ SDK 上自动改用 SDK 自带 xpc（私有 SPI 走 xpc_private.h）；
#     - roothidehooks/cfprefsd.x 用 dlsym 取 xpc_connection_get_pid，绕开新 SDK 的 unavailable 标记。
#   若将来遇到别的 “新 SDK 标 unavailable” 报错，按同样思路（dlsym / -Wno-availability）逐个修。
#
# 透传 macos-build.sh 的环境变量：SKIP_PRELOAD / SKIP_BOOTSTRAP / JOBS
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TREE="$ROOT/Dopamine2-roothide"
DOB="$TREE/Application/Dopamine/Jailbreak/DOBootstrapper.m"
CFPREFSD="$TREE/BaseBin/roothidehooks/cfprefsd.x"

log()  { printf '\033[1;35m==> [roothide] %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m!! [roothide] %s\033[0m\n' "$*" >&2; exit 1; }

# 1. 树未就位 / 未打 preload patch / 未打 modernize patch → 跑 setup（幂等）
if [[ ! -d "$TREE/Application/Dopamine" ]] \
   || ! grep -q "BEGIN preload" "$DOB" 2>/dev/null \
   || ! grep -q "roothide_xpc_connection_get_pid" "$CFPREFSD" 2>/dev/null; then
    log "roothide 树未就位 / 未打 preload 或 modernize patch，先运行 setup-roothide-tree.sh"
    "$HERE/setup-roothide-tree.sh"
fi

# 2. 复用构建引擎（当前 Xcode，不切换）
SDK_VER="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo '?')"
log "using current Xcode (iOS SDK ${SDK_VER}); starting roothide build (TARGET=roothide)"
TARGET=roothide "$HERE/macos-build.sh" "$@"
log "roothide build finished"

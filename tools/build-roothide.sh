#!/usr/bin/env bash
# build-roothide.sh — 一键生成 roothide 版 Dopamine2.tipa。
#
# 与 upstream 的 ./tools/macos-build.sh 是【两个独立入口】：
#   upstream 版：  ./tools/macos-build.sh
#   roothide 版：  ./tools/build-roothide.sh   ← 本脚本
#
# 它做两件事：
#   1) 确保 Dopamine2-roothide/ 树存在且已打 preload patch（没有就自动跑 setup-roothide-tree.sh）
#   2) 以 TARGET=roothide 复用 macos-build.sh 的构建引擎（同一套 bootstrap/preload/gmake 流程，
#      只是锁定 roothide 树）——保证 roothide 版和 upstream 版除了"哪棵树"以外行为完全一致。
#
# 透传 macos-build.sh 的环境变量：SKIP_PRELOAD / SKIP_BOOTSTRAP / JOBS
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TREE="$ROOT/Dopamine2-roothide"
DOB="$TREE/Application/Dopamine/Jailbreak/DOBootstrapper.m"

log() { printf '\033[1;35m==> [roothide] %s\033[0m\n' "$*"; }

# 1. 树未就位 / 未打 patch → 先跑 setup
if [[ ! -d "$TREE/Application/Dopamine" ]] || ! grep -q "BEGIN preload" "$DOB" 2>/dev/null; then
    log "roothide 树未就位或未打 preload patch，先运行 setup-roothide-tree.sh"
    "$HERE/setup-roothide-tree.sh"
fi

# 2. 锁定 TARGET=roothide，复用构建引擎
log "starting roothide build (TARGET=roothide)"
exec env TARGET=roothide "$HERE/macos-build.sh" "$@"

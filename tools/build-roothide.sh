#!/usr/bin/env bash
# build-roothide.sh — 一键生成 roothide 版 Dopamine2.tipa。
#
# 与 upstream 的 ./tools/macos-build.sh 是【两个独立入口】：
#   upstream 版：  ./tools/macos-build.sh
#   roothide 版：  ./tools/build-roothide.sh   ← 本脚本
#
# 它做三件事：
#   1) 确保 Dopamine2-roothide/ 树存在且已打 preload patch（没有就自动跑 setup-roothide-tree.sh）
#   2) 若当前 Xcode 太新（iOS SDK >= 26，roothide 工具链编不过），临时切到老版 Xcode，
#      构建结束（含失败/中断）用 trap 自动切回原来的 Xcode。
#   3) 以 TARGET=roothide 复用 macos-build.sh 的构建引擎。
#
# 指定老版 Xcode（按优先级）：
#   - 环境变量 ROOTHIDE_XCODE=/Applications/Xcode_16.app
#   - 否则自动在 /Applications/Xcode*.app 里找一个 iphoneos SDK 主版本 < 26 的
#
# 透传 macos-build.sh 的环境变量：SKIP_PRELOAD / SKIP_BOOTSTRAP / JOBS
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TREE="$ROOT/Dopamine2-roothide"
DOB="$TREE/Application/Dopamine/Jailbreak/DOBootstrapper.m"

log()  { printf '\033[1;35m==> [roothide] %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m!! [roothide] %s\033[0m\n' "$*" >&2; exit 1; }

# 1. 树未就位 / 未打 patch → 先跑 setup
if [[ ! -d "$TREE/Application/Dopamine" ]] || ! grep -q "BEGIN preload" "$DOB" 2>/dev/null; then
    log "roothide 树未就位或未打 preload patch，先运行 setup-roothide-tree.sh"
    "$HERE/setup-roothide-tree.sh"
fi

# 2. Xcode 版本处理 ----------------------------------------------------------
sdk_major() { local v; v="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo 0)"; echo "${v%%.*}"; }
ORIG_DEV=""; SWITCHED=""
restore_xcode() {
    [[ -n "$SWITCHED" && -n "$ORIG_DEV" ]] || return 0
    log "restoring Xcode → $ORIG_DEV"
    sudo xcode-select -s "$ORIG_DEV" || printf '!! 切回 Xcode 失败，请手动：sudo xcode-select -s %q\n' "$ORIG_DEV" >&2
}

CUR_MAJOR="$(sdk_major)"
if [[ "${CUR_MAJOR:-0}" -ge 26 ]]; then
    log "当前 Xcode iOS SDK 主版本=$CUR_MAJOR，对 roothide 工具链太新，需切老版 Xcode"

    # 选老版 Xcode
    OLD_XCODE="${ROOTHIDE_XCODE:-}"
    if [[ -z "$OLD_XCODE" ]]; then
        best=""; best_ver=0
        for app in /Applications/Xcode*.app; do
            [[ -d "$app/Contents/Developer" ]] || continue
            v="$(DEVELOPER_DIR="$app/Contents/Developer" xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo 0)"
            maj="${v%%.*}"
            # 取主版本 < 26 里最高的那个（最接近、最兼容）
            if [[ "${maj:-0}" -lt 26 && "${maj:-0}" -ge 14 ]]; then
                if [[ "${maj:-0}" -gt "$best_ver" ]]; then best_ver="$maj"; best="$app"; fi
            fi
        done
        OLD_XCODE="$best"
    fi

    [[ -n "$OLD_XCODE" && -d "$OLD_XCODE/Contents/Developer" ]] || fail \
"找不到可用的老版 Xcode（iOS SDK < 26）。
   请装一个 Xcode 16/15 后用环境变量指定，例如：
     ROOTHIDE_XCODE=/Applications/Xcode_16.app ./tools/build-roothide.sh"

    ORIG_DEV="$(xcode-select -p 2>/dev/null || true)"
    log "切到老版 Xcode：$OLD_XCODE（需要 sudo；结束后自动切回 $ORIG_DEV）"
    sudo xcode-select -s "$OLD_XCODE/Contents/Developer"
    SWITCHED=1
    trap restore_xcode EXIT INT TERM
    log "现在 iOS SDK = $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)"
else
    log "当前 Xcode iOS SDK 主版本=$CUR_MAJOR，对 roothide 可用，不切换"
fi

# 3. 复用构建引擎（不能 exec，否则上面的 trap 切回逻辑不会执行）
log "starting roothide build (TARGET=roothide)"
TARGET=roothide "$HERE/macos-build.sh" "$@"
log "roothide build finished"

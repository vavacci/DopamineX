#!/usr/bin/env bash
# macos-build.sh — 在 macOS 上 build 整个 DopamineX，产物 Application/Dopamine.tipa。
#
# 前置条件：先跑过 tools/macos-setup.sh 装好工具链。
#
# 执行：
#   source .macos-build-env                  # 或者你自己把 PATH/THEOS 写进 ~/.zshrc
#   ./tools/macos-build.sh
#
# 可选参数（环境变量）：
#   SKIP_PRELOAD=1      跳过 preload-*.deb 打包步骤（你没改 preload-input 时）
#   SKIP_BOOTSTRAP=1    跳过 download_bootstraps.sh（bootstrap_*.tar.zst 已下好）
#   JOBS=N              并行数（默认 = CPU 核数）
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────
# 0. 环境检查
# ─────────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || fail "macOS only"

# 自动 source .macos-build-env（如果还没 source）
if [[ -z "${THEOS:-}" ]] && [[ -f "$ROOT/.macos-build-env" ]]; then
    log "auto-loading .macos-build-env"
    # shellcheck disable=SC1091
    source "$ROOT/.macos-build-env"
fi

[[ -n "${THEOS:-}" && -d "$THEOS" ]] || fail "THEOS not set or invalid; run tools/macos-setup.sh first"
[[ -d "$THEOS/sdks/iPhoneOS16.5.sdk" ]] || fail "iPhoneOS16.5.sdk missing in $THEOS/sdks/"

command -v gmake >/dev/null    || fail "gmake not found (brew install make? PATH set?)"
command -v ldid >/dev/null     || fail "ldid not found (Procursus?)"
command -v xcodebuild >/dev/null || fail "xcodebuild not found"
command -v trustcache >/dev/null || fail "trustcache not found (in /opt/procursus/bin?)"
command -v dpkg-deb >/dev/null  || fail "dpkg-deb not found (brew install dpkg)"

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"
log "build environment OK (THEOS=$THEOS, jobs=$JOBS)"

# ─────────────────────────────────────────────────────────────────
# 1. 子模块
# ─────────────────────────────────────────────────────────────────
log "[1/5] git submodule update --init --recursive"
git submodule update --init --recursive

# ─────────────────────────────────────────────────────────────────
# 2. Bootstraps
# ─────────────────────────────────────────────────────────────────
if [[ "${SKIP_BOOTSTRAP:-}" == "1" ]]; then
    log "[2/5] skipping bootstrap download (SKIP_BOOTSTRAP=1)"
else
    BS_DIR="Application/Dopamine/Resources"
    if [[ -f "$BS_DIR/bootstrap_1800.tar.zst" && -f "$BS_DIR/bootstrap_1900.tar.zst" ]]; then
        log "[2/5] bootstraps already present, skipping"
    else
        log "[2/5] downloading bootstrap_*.tar.zst (~400MB total)"
        pushd "$BS_DIR" >/dev/null
        bash ./download_bootstraps.sh
        popd >/dev/null
    fi
fi

# ─────────────────────────────────────────────────────────────────
# 3. 预加载 deb 打包（修改 preload-input/ 后才需要重新跑）
# ─────────────────────────────────────────────────────────────────
if [[ "${SKIP_PRELOAD:-}" == "1" ]]; then
    log "[3/5] skipping preload deb build (SKIP_PRELOAD=1)"
elif [[ -d preload-input ]] && [[ -x tools/build-preload-debs.sh ]]; then
    log "[3/5] building preload-*.deb from preload-input/"
    ./tools/build-preload-debs.sh
else
    log "[3/5] no preload-input/ directory, skipping"
fi

# ─────────────────────────────────────────────────────────────────
# 4. 主 Makefile
# ─────────────────────────────────────────────────────────────────
log "[4/5] gmake -j$JOBS NIGHTLY=1 (this takes 20–40 minutes)"
gmake -j"$JOBS" NIGHTLY=1

# ─────────────────────────────────────────────────────────────────
# 5. 产物
# ─────────────────────────────────────────────────────────────────
if [[ -f Application/Dopamine.ipa ]]; then
    cp Application/Dopamine.ipa Application/Dopamine.tipa
    log "[5/5] output ready"
    ls -lh Application/Dopamine.ipa Application/Dopamine.tipa
    echo
    printf '\033[1;32mAirdrop Application/Dopamine.tipa to your iPhone → TrollStore Install.\033[0m\n'
else
    fail "Build failed: Application/Dopamine.ipa not found"
fi

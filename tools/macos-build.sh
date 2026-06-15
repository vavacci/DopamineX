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
#   TARGET=upstream|roothide   选构建哪棵树（默认 upstream，保留旧行为）
#                              upstream → $ROOT/Application 或 $ROOT/Dopamine-upstream/
#                              roothide → $ROOT/Dopamine2-roothide/
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
# target / tree 选择（与 tools/build-preload-debs.sh 的解析逻辑一致）
# ─────────────────────────────────────────────────────────────────
TARGET="${TARGET:-upstream}"
case "$TARGET" in
    upstream)
        if   [[ -d "$ROOT/Application/Dopamine" ]];                   then TREE="$ROOT"
        elif [[ -d "$ROOT/Dopamine-upstream/Application/Dopamine" ]]; then TREE="$ROOT/Dopamine-upstream"
        else fail "TARGET=upstream 但找不到 Application/Dopamine（查过 \$ROOT 和 \$ROOT/Dopamine-upstream）"
        fi ;;
    roothide)
        if   [[ -d "$ROOT/Dopamine2-roothide/Application/Dopamine" ]]; then TREE="$ROOT/Dopamine2-roothide"
        elif [[ -d "$ROOT/Application/Dopamine" ]] && grep -qi roothide "$ROOT/README.md" 2>/dev/null; then TREE="$ROOT"
        else fail "TARGET=roothide 但找不到 Dopamine2-roothide/Application/Dopamine"
        fi ;;
    *)  fail "未知 TARGET=${TARGET}（valid: upstream | roothide）" ;;
esac
log "TARGET=$TARGET  TREE=$TREE"

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
log "[1/5] git submodule update --init --recursive ($TREE)"
git -C "$TREE" submodule update --init --recursive

# ─────────────────────────────────────────────────────────────────
# 2. Bootstraps
# ─────────────────────────────────────────────────────────────────
if [[ "${SKIP_BOOTSTRAP:-}" == "1" ]]; then
    log "[2/5] skipping bootstrap download (SKIP_BOOTSTRAP=1)"
else
    BS_DIR="$TREE/Application/Dopamine/Resources"
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
#    build-preload-debs.sh 自己按 --target 解析并写对应树的 Resources/ + header
# ─────────────────────────────────────────────────────────────────
if [[ "${SKIP_PRELOAD:-}" == "1" ]]; then
    log "[3/5] skipping preload deb build (SKIP_PRELOAD=1)"
elif [[ -d "$ROOT/preload-input" ]] && [[ -x "$ROOT/tools/build-preload-debs.sh" ]]; then
    log "[3/5] building preload-*.deb from preload-input/ (--target=$TARGET)"
    "$ROOT/tools/build-preload-debs.sh" --target="$TARGET"
else
    log "[3/5] no preload-input/ directory, skipping"
fi

# ─────────────────────────────────────────────────────────────────
# 4. 主 Makefile（在所选树内构建）
# ─────────────────────────────────────────────────────────────────

# 4a. 清 clang 模块缓存：避免 ".include/bsm/audit.h has been modified since the
#     module file" 这类 ModuleCache mtime 失效报错（BaseBin 每次重拷头会刷新 mtime）。
CACHE_DIR="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)clang/ModuleCache"
if [[ -d "$CACHE_DIR" ]]; then
    log "[4/5] clearing clang ModuleCache ($CACHE_DIR)"
    rm -rf "$CACHE_DIR" 2>/dev/null || true
fi

# 4b. xpc 头兼容：新 Xcode SDK(26+) 把 xpc_connection_get_pid 等标为 unavailable，
#     导致 BaseBin 编译失败。roothide 官方做法是移除 Xcode SDK 的 xpc 头，让编译回退到
#     仓库自带的 _external/include/xpc。这里【临时移走 + 构建后用 trap 恢复】，
#     避免长期破坏普通 App 工程的 XPC 编译。需要 sudo（改 Xcode.app 下的 SDK）。
SDKP="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
XPC_STASH="${TMPDIR:-/tmp}/dopaminex-xpc-stash"
restore_xpc() {
    [[ -n "${SDKP:-}" && -d "$XPC_STASH/xpc" ]] || { rm -rf "$XPC_STASH" 2>/dev/null || true; return 0; }
    [[ -e "$SDKP/usr/include/xpc" ]]           || sudo mv "$XPC_STASH/xpc" "$SDKP/usr/include/xpc"
    if [[ -f "$XPC_STASH/xpc.modulemap" && ! -e "$SDKP/usr/include/xpc.modulemap" ]]; then
        sudo mv "$XPC_STASH/xpc.modulemap" "$SDKP/usr/include/xpc.modulemap"
    fi
    rm -rf "$XPC_STASH" 2>/dev/null || true
    log "restored Xcode SDK xpc headers"
}
restore_xpc   # 先清理上次异常退出可能残留的 stash，保证状态干净
if [[ -n "$SDKP" && -d "$SDKP/usr/include/xpc" ]]; then
    log "moving Xcode SDK xpc headers aside (auto-restored after build; needs sudo)"
    mkdir -p "$XPC_STASH"
    sudo mv "$SDKP/usr/include/xpc" "$XPC_STASH/xpc"
    [[ -f "$SDKP/usr/include/xpc.modulemap" ]] && sudo mv "$SDKP/usr/include/xpc.modulemap" "$XPC_STASH/xpc.modulemap"
    trap restore_xpc EXIT INT TERM
fi

log "[4/5] gmake -j$JOBS NIGHTLY=1 in $TREE (this takes 20–40 minutes)"
( cd "$TREE" && gmake -j"$JOBS" NIGHTLY=1 )

# ─────────────────────────────────────────────────────────────────
# 5. 产物
# ─────────────────────────────────────────────────────────────────
if [[ -f "$TREE/Application/Dopamine.ipa" ]]; then
    cp "$TREE/Application/Dopamine.ipa" "$TREE/Application/Dopamine.tipa"
    log "[5/5] output ready ($TARGET)"
    ls -lh "$TREE/Application/Dopamine.ipa" "$TREE/Application/Dopamine.tipa"
    echo
    printf '\033[1;32mAirdrop %s/Application/Dopamine.tipa to your iPhone → TrollStore Install.\033[0m\n' "$TREE"
else
    fail "Build failed: $TREE/Application/Dopamine.ipa not found"
fi

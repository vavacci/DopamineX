#!/usr/bin/env bash
# setup-roothide-tree.sh — 把 roothide 树 vendoring 进本仓库的 Dopamine2-roothide/ 子目录，
# 并打上 preload 预装 patch。一次性运行；幂等（已克隆/已 patch 会跳过）。
#
# 可选环境变量：
#   ROOTHIDE_REPO=<url>      roothide 源（默认官方；可换成你的 fork）
#   ROOTHIDE_COMMIT=<sha>    锁定 commit（默认 = patch 的基线，保证 patch 能套上）
#   VENDOR=1                 克隆后删掉子树 .git，真正并进本仓库一个 repo
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TREE="$ROOT/Dopamine2-roothide"
REPO="${ROOTHIDE_REPO:-https://github.com/roothide/Dopamine2-roothide.git}"
PIN="${ROOTHIDE_COMMIT:-57ffae093c96d0fa6690661bc816b4978e3bd518}"
PATCH="$HERE/roothide-preload.patch"
MODERNIZE_PATCH="$HERE/roothide-modernize.patch"
CUSTOMIZE_PATCH="$HERE/roothide-customize.patch"
DOB="Application/Dopamine/Jailbreak/DOBootstrapper.m"
CFPREFSD="BaseBin/roothidehooks/cfprefsd.x"
PALERA1N_MK="Application/Dopamine/Exploits/palera1n/Makefile"
PKGPICKER="Application/Dopamine/UI/PkgManagers/DOPkgManagerPickerView.m"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$PATCH" ]] || fail "缺少 patch 文件：$PATCH"

# 1. 克隆 roothide 树（若缺）
if [[ ! -d "$TREE/Application/Dopamine" ]]; then
    log "cloning roothide → Dopamine2-roothide/  (pin ${PIN:0:10})"
    git clone "$REPO" "$TREE"
    git -C "$TREE" checkout "$PIN"
    git -C "$TREE" submodule update --init --recursive
else
    log "roothide 树已存在：$TREE"
fi

# 2. 应用 preload patch（幂等）
if grep -q "BEGIN preload" "$TREE/$DOB" 2>/dev/null; then
    log "preload patch 已应用，跳过"
else
    log "applying roothide-preload.patch"
    patch -p1 -d "$TREE" < "$PATCH" \
        || fail "patch 套用失败（基线 commit 对不上？用 ROOTHIDE_COMMIT 指定，或手动改 ${DOB}）"
fi

# 2b. 应用 modernize patch（幂等）——让 roothide 能在现代 Xcode(含 26) 本地编过。
#     该 patch 会随迭代增长（目前含两处）：
#       - cfprefsd.x：dlsym 取 xpc_connection_get_pid，绕开新 SDK 的 unavailable 标记
#         （xpc 头本身由 BaseBin/Makefile 在 iOS17.4+ 自动改用 SDK 自带的，无需额外处理）
#       - palera1n/Makefile：加 -not_for_dyld_shared_cache，绕开 Xcode26 新链接器
#         "eligible dylib cannot link to ineligible dylib" 报错
#     幂等做法：先按"标记"判断是否已全部应用；否则 patch --forward（已应用的 hunk 自动跳过，
#     新 hunk 照常套上），再按标记复核——所以已有的树也能增量补打后续新增的修复。
modernize_applied() {
    grep -q "roothide_xpc_connection_get_pid" "$TREE/$CFPREFSD" 2>/dev/null \
    && grep -q "not_for_dyld_shared_cache"    "$TREE/$PALERA1N_MK" 2>/dev/null
}
if [[ -f "$MODERNIZE_PATCH" ]]; then
    if modernize_applied; then
        log "modernize patch 已全部应用，跳过"
    else
        log "applying roothide-modernize.patch (--forward, 幂等; 已应用的 hunk 会被跳过)"
        patch -p1 --forward -d "$TREE" < "$MODERNIZE_PATCH" || true
        modernize_applied \
            || fail "modernize patch 套用后仍缺改动（基线 commit 对不上？用 ROOTHIDE_COMMIT 指定，或手动改 ${CFPREFSD} / ${PALERA1N_MK}）"
    fi
else
    log "WARN: 缺少 $MODERNIZE_PATCH，跳过 modernize（新 Xcode 可能编不过）"
fi

# 2c. 应用 customize patch（幂等）——roothide 行为定制（与"能否编过"无关）：
#       - DOPkgManagerPickerView.m：允许不选任何包管理器直接继续（不装 Sileo/Zebra）
#     幂等同 2b：按标记判断 + patch --forward。
customize_applied() {
    grep -q "roothide-customize" "$TREE/$PKGPICKER" 2>/dev/null
}
if [[ -f "$CUSTOMIZE_PATCH" ]]; then
    if customize_applied; then
        log "customize patch 已全部应用，跳过"
    else
        log "applying roothide-customize.patch (--forward, 幂等)"
        patch -p1 --forward -d "$TREE" < "$CUSTOMIZE_PATCH" || true
        customize_applied \
            || fail "customize patch 套用后仍缺改动（基线 commit 对不上？用 ROOTHIDE_COMMIT 指定，或手动改 ${PKGPICKER}）"
    fi
else
    log "WARN: 缺少 $CUSTOMIZE_PATCH，跳过 customize"
fi

# 3. vendoring（可选）：删掉子树 .git，让本仓库直接 track 这些文件
if [[ "${VENDOR:-}" == "1" && -d "$TREE/.git" ]]; then
    log "VENDOR=1 → 移除 Dopamine2-roothide/.git，并入本仓库"
    rm -rf "$TREE/.git"
    log "现在可：git add Dopamine2-roothide && git commit -m 'vendor roothide + preload patch'"
elif [[ -d "$TREE/.git" ]]; then
    cat <<EOF

[提示] roothide 树自带 .git（独立历史）。要真正并进 DopamineX 一个 repo，跑：
    VENDOR=1 $0
  或手动： rm -rf "$TREE/.git" && git add Dopamine2-roothide && git commit
（不删也能 build，只是 git 会把它当未跟踪的嵌入仓库。）
EOF
fi

log "done. 现在跑： ./tools/build-roothide.sh"

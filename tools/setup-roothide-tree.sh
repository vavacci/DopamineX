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
DOB="Application/Dopamine/Jailbreak/DOBootstrapper.m"

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

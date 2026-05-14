#!/usr/bin/env bash
# macos-setup.sh — 在 macOS 上一次性安装 DopamineX 构建所需的全套工具链。
#
# 必须在 macOS 上跑（Linux/Windows 都跑不了 iOS 工具链）。
# 跑完后再用 tools/macos-build.sh 出 .tipa。
#
# 大致 30–45 分钟（取决于网络与 SDK 下载速度），约占用 5GB 磁盘。
#
# 执行：
#   chmod +x tools/macos-setup.sh
#   ./tools/macos-setup.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────
# 0. 基础检查
# ─────────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || fail "此脚本仅 macOS 可用，你在 $(uname) 上"

log "[0/8] sanity checks"
xcode-select -p &>/dev/null || fail "Xcode 未装。先到 App Store 装 Xcode，再跑 sudo xcode-select --install && sudo xcodebuild -license accept"

# Apple Silicon vs Intel
if [[ "$(uname -m)" == "arm64" ]]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi
log "    Mac arch: $(uname -m)  brew prefix: $BREW_PREFIX"

# ─────────────────────────────────────────────────────────────────
# 1. Homebrew
# ─────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    log "[1/8] Installing Homebrew (will ask for password)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$($BREW_PREFIX/bin/brew shellenv)"
else
    log "[1/8] Homebrew already installed: $(brew --version | head -1)"
fi

# ─────────────────────────────────────────────────────────────────
# 2. Procursus 工具链（提供 ldid / trustcache 必备的 Linux 风格工具）
# ─────────────────────────────────────────────────────────────────
if [[ ! -d /opt/procursus ]]; then
    log "[2/8] Installing Procursus toolchain (asks for sudo)"
    curl -fsSL https://raw.githubusercontent.com/ProcursusTeam/Procursus/main/bootstrap.sh -o /tmp/procursus-bootstrap.sh
    sudo bash /tmp/procursus-bootstrap.sh
    rm -f /tmp/procursus-bootstrap.sh
else
    log "[2/8] Procursus already at /opt/procursus"
fi

log "    Updating Procursus apt index..."
sudo /opt/procursus/bin/apt-get -y update >/dev/null

log "    Installing Procursus packages: ldid findutils sed coreutils make"
sudo /opt/procursus/bin/apt-get install -y ldid findutils sed coreutils make libarchive

# ─────────────────────────────────────────────────────────────────
# 3. brew 包：GNU make / openssl / libarchive
# ─────────────────────────────────────────────────────────────────
log "[3/8] brew install make openssl libarchive"
brew list make &>/dev/null      || brew install make
brew list openssl &>/dev/null   || brew install openssl
brew list libarchive &>/dev/null || brew install libarchive

# ─────────────────────────────────────────────────────────────────
# 4. THEOS
# ─────────────────────────────────────────────────────────────────
export THEOS="${THEOS:-$HOME/theos}"
if [[ ! -d "$THEOS" ]]; then
    log "[4/8] Cloning theos to $THEOS"
    git clone --recursive https://github.com/theos/theos.git "$THEOS"
else
    log "[4/8] THEOS exists at $THEOS, updating"
    git -C "$THEOS" pull --recurse-submodules
fi

# ─────────────────────────────────────────────────────────────────
# 5. iPhoneOS SDK
# ─────────────────────────────────────────────────────────────────
SDK_NAME="iPhoneOS16.5.sdk"
if [[ ! -d "$THEOS/sdks/$SDK_NAME" ]]; then
    log "[5/8] Downloading $SDK_NAME (~250MB)"
    mkdir -p "$THEOS/sdks"
    curl -fL "https://github.com/theos/sdks/releases/latest/download/${SDK_NAME}.tar.xz" \
         -o "$THEOS/sdks/${SDK_NAME}.tar.xz"
    tar -xf "$THEOS/sdks/${SDK_NAME}.tar.xz" -C "$THEOS/sdks"
    rm "$THEOS/sdks/${SDK_NAME}.tar.xz"
else
    log "[5/8] $SDK_NAME already installed"
fi

# ─────────────────────────────────────────────────────────────────
# 6. trustcache 工具（不在 Procursus 仓库里，自编自装）
# ─────────────────────────────────────────────────────────────────
if [[ ! -x /opt/procursus/bin/trustcache ]]; then
    log "[6/8] Building trustcache from source"
    TC_DIR=$(mktemp -d)
    git clone https://github.com/CRKatri/trustcache "$TC_DIR"
    pushd "$TC_DIR" >/dev/null
    export CFLAGS="-I$(brew --prefix openssl)/include -arch arm64"
    export LDFLAGS="-L$(brew --prefix openssl)/lib -arch arm64"
    "$(brew --prefix make)/libexec/gnubin/make" -j"$(sysctl -n hw.logicalcpu)" OPENSSL=1
    sudo cp trustcache /opt/procursus/bin/
    popd >/dev/null
    rm -rf "$TC_DIR"
else
    log "[6/8] trustcache already installed at /opt/procursus/bin/trustcache"
fi

# ─────────────────────────────────────────────────────────────────
# 7. dpkg-deb（用于打 preload-*.deb；macOS 自带 brew 装）
# ─────────────────────────────────────────────────────────────────
if ! command -v dpkg-deb >/dev/null; then
    log "[7/8] Installing dpkg via Homebrew"
    brew install dpkg
else
    log "[7/8] dpkg-deb already available: $(which dpkg-deb)"
fi

# ─────────────────────────────────────────────────────────────────
# 8. 写 PATH 提示
# ─────────────────────────────────────────────────────────────────
log "[8/8] writing convenience env file"

ENV_FILE="$ROOT/.macos-build-env"
cat > "$ENV_FILE" <<EOF
# DopamineX macOS build environment — source this before running macos-build.sh
# Auto-generated by tools/macos-setup.sh

export THEOS="$THEOS"
export PATH="$(brew --prefix make)/libexec/gnubin:/opt/procursus/bin:\$PATH"
EOF
chmod 644 "$ENV_FILE"

cat <<EOF

\033[1;32m===== setup complete =====\033[0m

Next step:
  source $ENV_FILE
  ./tools/macos-build.sh

Or do it permanently by appending these lines to ~/.zshrc:
  export THEOS="$THEOS"
  export PATH="$(brew --prefix make)/libexec/gnubin:/opt/procursus/bin:\$PATH"
EOF

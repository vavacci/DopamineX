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
if [[ ! -f /opt/procursus/.procursus_strapped ]]; then
    log "[2/8] Installing Procursus toolchain (asks for sudo)"

    # 选 arch: Apple Silicon → arm64, Intel → amd64
    if [[ "$(uname -m)" == "arm64" ]]; then
        PROC_ARCH="arm64"
    else
        PROC_ARCH="amd64"
    fi
    PROC_SUITE="big_sur"      # Procursus 当前只发这一个 macOS suite，覆盖 macOS 11+

    # 2.1 装 zstd（解压 bootstrap tarball 需要）
    command -v zstdcat >/dev/null || brew install zstd

    # 2.2 下 + 解压到 /
    log "    fetching bootstrap-darwin-$PROC_ARCH.tar.zst ..."
    TARBALL_URL="https://apt.procurs.us/bootstraps/$PROC_SUITE/bootstrap-darwin-$PROC_ARCH.tar.zst"
    curl -fL "$TARBALL_URL" | zstdcat - | sudo tar -xpkf - -C / || \
        fail "Procursus bootstrap install failed (curl/zstd/tar). URL: $TARBALL_URL"

    # 2.3 创建 _apt 用户（apt 沙箱需要）
    # 注意: id 找不到该用户 ≠ record 不存在；可能存在 partial record（其它工具装过 / setup 跑半途死过）
    # 用 dscl read 检查 record 存在性，存在但缺 UniqueID 则先 delete 再 create
    if id _apt &>/dev/null; then
        log "    _apt user already exists with UniqueID, skipping"
    else
        if sudo dscl . -read /Users/_apt &>/dev/null; then
            log "    found partial _apt record (no UniqueID), deleting before recreating"
            sudo dscl . -delete /Users/_apt 2>/dev/null || true
        fi

        log "    creating _apt user (apt sandbox)"
        # 找一个未占用的 UniqueID < 499
        APT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -ugr | awk '$1 < 499 {print $1+1; exit}')
        [[ -z "$APT_UID" ]] && APT_UID=498
        sudo dscl . -create /Users/_apt UserShell /usr/bin/false
        sudo dscl . -create /Users/_apt NSFHomeDirectory /var/empty
        sudo dscl . -create /Users/_apt PrimaryGroupID -1
        sudo dscl . -create /Users/_apt UniqueID "$APT_UID"
        sudo dscl . -create /Users/_apt RealName "APT Sandbox User"
    fi

    # 2.4 写 sources.list
    log "    configuring apt sources"
    sudo mkdir -p /opt/procursus/etc/apt/sources.list.d
    sudo tee /opt/procursus/etc/apt/sources.list.d/procursus.sources >/dev/null <<EOF
Types: deb
URIs: https://apt.procurs.us
Suites: $PROC_SUITE
Components: main
EOF
else
    log "[2/8] Procursus already at /opt/procursus"
fi

# 把 Procursus PATH 加进当前 shell（apt 等需要）
export PATH="/opt/procursus/bin:/opt/procursus/sbin:/opt/procursus/local/bin:$PATH"

log "    Updating Procursus apt index..."
sudo /opt/procursus/bin/apt-get -y update >/dev/null

log "    Installing Procursus packages: ldid findutils sed coreutils make"
sudo /opt/procursus/bin/apt-get install -y -o Dpkg::Options::="--force-confdef" \
    ldid findutils sed coreutils make libarchive

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

# 在 macOS 上构建 DopamineX

> 配套阅读：
> - [PRELOAD_HOWTO.md](./PRELOAD_HOWTO.md) — preload-deb 流程
> - [SIGNING_AND_DEPLOYMENT.md](./SIGNING_AND_DEPLOYMENT.md) — `.tipa` / TrollStore 总览

## 前置条件

| 项 | 要求 |
| --- | --- |
| OS | macOS 12+（Apple Silicon 或 Intel 都行） |
| Xcode | 14+ |
| 磁盘 | ≥10 GB 空闲（含 Xcode、Procursus、THEOS、SDK、submodule 编译产物） |
| 网络 | 首次构建需下 GitHub / theos sdks / Procursus，约 1.5 GB |
| 时间 | 首次：60 分钟左右；后续增量：5–10 分钟 |

## 一次性环境配置

```sh
# 1. clone（含子模块）
git clone --recursive https://github.com/vavacci/DopamineX.git
cd DopamineX

# 2. 跑环境配置脚本（会装 brew / Procursus / THEOS / SDK / trustcache）
chmod +x tools/macos-setup.sh tools/macos-build.sh
./tools/macos-setup.sh
```

脚本会引导你输入 sudo 密码（安装 Procursus 与 trustcache 需要）。

## 出包

```sh
# 加载环境变量（每个新终端都要 source 一次，或写进 ~/.zshrc 永久生效）
source .macos-build-env

# 出包（首次 30–60 min，后续 5–10 min）
./tools/macos-build.sh
```

产物：

```
Application/Dopamine.ipa      ← xcodebuild 出的原始产物
Application/Dopamine.tipa     ← 别名，便于识别
```

AirDrop / iCloud Drive / HTTP 把 `Dopamine.tipa` 送到 iPhone → Files App → 长按 →
Share → **TrollStore** → Install。

## 脚本做了什么

### `tools/macos-setup.sh`（一次性）

| 步骤 | 内容 |
| --- | --- |
| 1 | 装 Homebrew（如未装） |
| 2 | 装 Procursus 工具链 → `/opt/procursus/`，再 apt-get 装 ldid / findutils / sed / coreutils / make / libarchive |
| 3 | brew install make / openssl / libarchive |
| 4 | clone theos 到 `~/theos`（可改 `$THEOS` 环境变量） |
| 5 | 下 iPhoneOS16.5.sdk 到 `$THEOS/sdks/`（~250 MB） |
| 6 | 编译 trustcache 二进制并装到 `/opt/procursus/bin/` |
| 7 | brew install dpkg（提供 dpkg-deb，preload-debs 用） |
| 8 | 生成 `.macos-build-env` 方便后续 `source` |

幂等的——已装过会自动跳过。

### `tools/macos-build.sh`（每次出包）

| 步骤 | 内容 |
| --- | --- |
| 0 | 环境检查（gmake / ldid / xcodebuild / trustcache / dpkg-deb 都在） |
| 1 | `git submodule update --init --recursive` |
| 2 | 下 bootstrap_*.tar.zst（首次 ~400 MB；已有则跳） |
| 3 | 跑 `tools/build-preload-debs.sh` 打 `preload-*.deb` 并塞进 Resources/ |
| 4 | `gmake -j$JOBS NIGHTLY=1`（主构建，最耗时） |
| 5 | 拷贝产物为 `.tipa` |

### 可调环境变量

```sh
# 只 build 主 App，跳过 preload 重打（你只改 OC 代码时）
SKIP_PRELOAD=1 ./tools/macos-build.sh

# 跳过 bootstrap 下载（你已下过、且没动 Resources/download_bootstraps.sh）
SKIP_BOOTSTRAP=1 ./tools/macos-build.sh

# 控制并行度
JOBS=4 ./tools/macos-build.sh
```

## 排错

### `gmake: command not found`

`.macos-build-env` 没 source。重新跑：

```sh
source .macos-build-env
./tools/macos-build.sh
```

或确认 `~/.zshrc` 已经永久写入：

```sh
export PATH="$(brew --prefix make)/libexec/gnubin:/opt/procursus/bin:$PATH"
```

### `THEOS not set or invalid`

同上，source `.macos-build-env`，或手动 `export THEOS=$HOME/theos`。

### `xcodebuild: error: SDK "iphoneos" cannot be located`

Xcode CLT 没装好：

```sh
sudo xcode-select --install
sudo xcodebuild -license accept
```

### `ldid: cannot execute binary file` 或 `Killed: 9`

Procursus 装的 ldid 是 ARM64-only；Intel Mac 上跑不了。改用 brew 版：

```sh
sudo /opt/procursus/bin/apt-get remove -y ldid
brew install ldid
```

### `BaseBin/ChOma/Makefile: No such file`

子模块没拉全。重跑：

```sh
git submodule update --init --recursive
```

### Procursus apt-get 报 "Could not get lock"

之前的 apt 进程还在；等几分钟或：

```sh
sudo rm -f /opt/procursus/var/lib/dpkg/lock-frontend /opt/procursus/var/lib/dpkg/lock
```

### `Build failed: Application/Dopamine.ipa not found`

最后阶段失败。看 gmake 输出最后 100 行：

```sh
gmake -j1 NIGHTLY=1 2>&1 | tee build.log
tail -100 build.log
```

`-j1` 串行跑，错误信息不会被并行输出搅乱。

## 完整一行命令清单（首次构建）

```sh
# 跟着上往下复制粘贴：
git clone --recursive https://github.com/vavacci/DopamineX.git
cd DopamineX
chmod +x tools/macos-setup.sh tools/macos-build.sh
./tools/macos-setup.sh
source .macos-build-env
./tools/macos-build.sh
ls -lh Application/Dopamine.tipa     # ← 这就是你的 .tipa
```

后续重 build 只要：

```sh
cd DopamineX
git pull
source .macos-build-env
./tools/macos-build.sh
```

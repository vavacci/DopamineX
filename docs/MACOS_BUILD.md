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

### `BaseBin/ChOma/Makefile: No such file` / `gmake[2]: *** ChOma: No such file or directory.`

`ChOma` / `XPF` / `opainject` / `litehook` / `kfd` 都是 **git submodule**，
clone 时漏 `--recursive` 就只有空目录。按下面 4 步**依次**处理。

#### Step 1 — 首选修复：用正确参数重跑

最常见的根因是漏了 `--init`：单独 `git submodule update` 不会 clone 新 submodule。
**第一次必须带 `--init`**：

```sh
cd /path/to/DopamineX
git submodule update --init --recursive --progress
```

`--progress` 强制实时输出，方便观察是否卡在某个 submodule。

跑完用 `ls BaseBin/ChOma/Makefile` 验证——能看到文件就 ✅。

#### Step 2 — 收集完整诊断输出（Step 1 失败时）

一次性贴下面这段到终端：

```sh
cd /path/to/DopamineX

echo "===== 1. submodule status ====="
git submodule status

echo
echo "===== 2. submodule paths (是否为 git 仓库 / 是否空目录) ====="
for p in BaseBin/ChOma BaseBin/XPF BaseBin/opainject \
         BaseBin/_external/modules/litehook \
         Application/Dopamine/Dopamine/Exploits/kfd/kfd; do
    echo "--- $p ---"
    ls -la "$p" 2>&1 | head -5
done

echo
echo "===== 3. .gitmodules ====="
cat .gitmodules

echo
echo "===== 4. git submodule config ====="
git config --get-regexp '^submodule\.' 2>&1

echo
echo "===== 5. verbose attempt ====="
git submodule update --init --recursive --progress 2>&1 | tail -30

echo
echo "===== 6. network reachability ====="
curl -sI https://github.com/opa334/ChOma.git/info/refs 2>&1 | head -3
```

#### Step 3 — 按 `git submodule status` 输出对症下药

| 输出特征 | 含义 | 处理 |
| --- | --- | --- |
| 空白（无输出） | submodule 未注册（`.gitmodules` 异常或 git 状态损坏） | 重 clone：`rm -rf DopamineX && git clone --recursive ...` |
| 每行前 `-`（如 `-abc... path`） | 未初始化 | `git submodule update --init --recursive`（即 Step 1） |
| 每行前空格 + commit hash | 已初始化但 update 没拉文件 | 走 Step 4 的"坑 1"或"坑 2" |
| 每行前 `+` | 有本地未提交改动 | `git submodule update --force --init --recursive` |

#### Step 4 — 三类常见坑分别修复

##### 坑 1：submodule 路径已存在但**不是 git 仓库**

如果 `BaseBin/ChOma/` 是空目录、或里头有杂文件但不是 git repo（之前 clone 出错残留），
`git submodule update` 不会强制覆盖。修复：

```sh
rm -rf BaseBin/ChOma \
       BaseBin/XPF \
       BaseBin/opainject \
       BaseBin/_external/modules/litehook \
       Application/Dopamine/Dopamine/Exploits/kfd/kfd
git submodule update --init --recursive --progress
```

##### 坑 2：网络拉不动 GitHub（国内限速 / 防火墙）

临时给所有 submodule URL 加镜像前缀（以 `ghproxy.com` 为例，其它代理同理）：

```sh
git config submodule.BaseBin/ChOma.url       https://ghproxy.com/https://github.com/opa334/ChOma
git config submodule.BaseBin/XPF.url         https://ghproxy.com/https://github.com/opa334/XPF
git config submodule.BaseBin/opainject.url   https://ghproxy.com/https://github.com/opa334/opainject
git config submodule.BaseBin/_external/modules/litehook.url \
                                              https://ghproxy.com/https://github.com/opa334/litehook
git config submodule.Exploits/kfd/src/kfd.url \
                                              https://ghproxy.com/https://github.com/opa334/kfd

git submodule update --init --recursive --progress

# 拉完后改回正式 URL（不然以后 push 会失败）
git submodule sync
```

或全局让 git 走 HTTP 代理（如本机 Clash/V2ray 在 7890 端口）：

```sh
git config --global http.https://github.com.proxy http://127.0.0.1:7890
git submodule update --init --recursive --progress
git config --global --unset http.https://github.com.proxy   # 拉完撤回
```

##### 坑 3：`.gitmodules` 与 `.git/config` 不同步

如果 `git submodule status` 输出**根本没列出某些 submodule**（与 `.gitmodules` 不匹配），
说明 git 状态损坏。重新注册：

```sh
git submodule init                          # 把 .gitmodules 同步到 .git/config
git submodule update --recursive --progress
```

#### 一句话预防

以后 clone 别忘 `--recursive`：

```sh
git clone --recursive https://github.com/vavacci/DopamineX.git
```

`./tools/macos-build.sh` 第 [1/5] 步会自动跑 `git submodule update --init --recursive`，
**如果你走 macos-build.sh 而不是裸 `gmake`，submodule 缺失会被自动处理**。

### Procursus apt-get 报 "Could not get lock"

之前的 apt 进程还在；等几分钟或：

```sh
sudo rm -f /opt/procursus/var/lib/dpkg/lock-frontend /opt/procursus/var/lib/dpkg/lock
```

### Procursus 下载 404 / `curl: (56)`

`tools/macos-setup.sh` 在 [2/8] 报错。这一步走的是
`https://apt.procurs.us/bootstraps/big_sur/bootstrap-darwin-{amd64|arm64}.tar.zst`
（Procursus 官方 tarball，不是源码里的 bootstrap.sh）。如果失败：

1. 检查 https://apt.procurs.us 服务是否在线
2. 手工跑：
   ```sh
   ARCH=$(uname -m); [[ "$ARCH" == "arm64" ]] || ARCH=amd64
   curl -fI "https://apt.procurs.us/bootstraps/big_sur/bootstrap-darwin-$ARCH.tar.zst"
   ```
   期望 HTTP 200
3. 如果你 mac 版本极新（macOS 16+ 之类），Procursus 可能尚未更新 suite。降级方法：用 Rosetta 装 amd64 版（在 setup 脚本里把 `PROC_ARCH` 强制改 `amd64`）

### `eDSRecordAlreadyExists` 创建 _apt 用户失败

之前 setup 跑到一半失败、或别的 iOS 工具链装过部分组件，**`/Users/_apt` 这个
record 在 Directory Service 里残留了一些属性**（但缺 UniqueID，所以 `id _apt`
找不到）。新版 setup 脚本已经做了"先 delete 再 create"的逻辑——如果你拿的是
旧版脚本踩坑的，手动一行修复：

```sh
sudo dscl . -delete /Users/_apt 2>/dev/null
./tools/macos-setup.sh                   # 重新跑
```

### Procursus 装好但 `apt-get install ldid` 报 `Unable to locate package ldid`

bootstrap tarball 只含基础环境，包仓库需要先 `apt-get update`。setup 脚本已经做了这步，
但如果你手工装过出错：

```sh
sudo /opt/procursus/bin/apt-get update
sudo /opt/procursus/bin/apt-get install -y ldid
```

如果 `apt-get update` 报错"sources.list.d/procursus.sources not found"，重新写：

```sh
sudo tee /opt/procursus/etc/apt/sources.list.d/procursus.sources <<EOF
Types: deb
URIs: https://apt.procurs.us
Suites: big_sur
Components: main
EOF
sudo /opt/procursus/bin/apt-get update
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

# Dopamine 预加载改造 — 使用指引

> 上游 opa334 Dopamine 已被改造为支持「随 .tipa 携带任意预装 .deb」。本文档给
> 你后续整套使用流程。设计依据见
> [PRELOAD_FEASIBILITY.md](./PRELOAD_FEASIBILITY.md) 和
> [PRELOAD_VANILLA_DOPAMINE.md](./PRELOAD_VANILLA_DOPAMINE.md)。

## 目录速览

```
dopamine/
├── Dopamine-upstream/                # 上游 opa334/Dopamine（已 git clone）
│   ├── Application/Makefile          ✏️ 已改：build 末尾自动把 preload-*.deb 拷进 Dopamine.app/
│   └── Application/Dopamine/Jailbreak/
│       ├── DOBootstrapper.m          ✏️ 已改：加 import + finalizeBootstrap 中循环安装 preload deb
│       └── preinstalled_debs.h       🤖 由打包脚本自动覆盖（DO NOT EDIT）
├── preload-input/                    👈 你在这里投放原始文件
│   ├── README.md                     约定与示例
│   └── _example/                     模板（下划线开头，会被脚本跳过）
├── tools/
│   └── build-preload-debs.sh         打包脚本
├── build/preload-debs/               脚本中间产物（gitignore 友好）
└── PRELOAD_HOWTO.md                  本文档
```

## 第一次：放文件 → 打包 → 出 .tipa

### Step 1 — 把文件按规则放进 `preload-input/`

约定见 [preload-input/README.md](./preload-input/README.md)。简要：

```
preload-input/
├── 10-acme-runtime/                  ← 数字前缀决定安装顺序；越小越先装
│   ├── control.yaml                  ← 元数据；缺省可省
│   ├── usr/local/bin/helloworld      ← 你已 ldid -S 签好的二进制
│   ├── Library/LaunchDaemons/com.acme.helloworld.plist
│   └── DEBIAN/postinst               ← 可选，dpkg 安装后自动跑
├── 20-acme-spbhook/
│   ├── control.yaml
│   └── Library/MobileSubstrate/DynamicLibraries/
│       ├── com.acme.spbhook.dylib
│       └── com.acme.spbhook.plist    ← 必须同名；ellekit Filter
└── _example/                         （保留示例，不打包）
```

注意：

- 文件按目标 jbroot 内的**相对路径**放（**不要**带 `/var/jb/` 前缀）。
- `control.yaml` 可写依赖：`depends: ["ellekit (>= 1.0.0)"]`。Dopamine 默认就会
  装 Sileo 或 Zebra（看用户偏好），但**不会**默认装 ellekit；如果你的 dylib 依赖
  ellekit，建议**把 ellekit.deb 也放进 preload-input 优先安装**（用"直通模式"，
  把 ellekit.deb 单独丢进 `preload-input/00-ellekit/`）。
- 二进制必须**事先 ldid -S 签好**，脚本不重签。
- 自动打包的 Architecture 为 `iphoneos-arm64`（Dopamine 2 rootless 默认）。**直通模式
  下脚本不修改原 deb；若原 deb arch 不是 iphoneos-arm64 / all，会发出警告**——
  Dopamine 2 上的 dpkg 不接受其它 arch（例如 `iphoneos-arm` 是旧版 rootful 时代的
  arch，会安装失败）。

### Step 2 — 跑打包脚本

```sh
cd /home/coder/workspace/mx/dopamine
./tools/build-preload-debs.sh
```

脚本会：

1. 把每个 `preload-input/NN-xxx/` 打成 `preload-NN-xxx.deb`；
2. 把 `.deb` 拷到 `Dopamine-upstream/Application/Dopamine/Resources/`；
3. 重写 `Dopamine-upstream/Application/Dopamine/Jailbreak/preinstalled_debs.h`
   把 deb 列表（按目录名字典序）固化进去；
4. 末尾打印"将随首次越狱安装"的列表给你检查。

**示例输出：**
```
[build] 10-acme-runtime → preload-10-acme-runtime.deb  (Package=com.acme.runtime Version=1.0.0)
[build] 20-acme-spbhook → preload-20-acme-spbhook.deb  (Package=com.acme.spbhook Version=1.0.0)

==================== summary ====================
Will be installed in this order during finalizeBootstrap:
   1. preload-10-acme-runtime.deb
   2. preload-20-acme-spbhook.deb
```

### Step 3 — 出 .tipa（macOS 上）

iOS 交叉编译需要 Xcode，**这一步必须在 macOS 跑**：

```sh
cd /path/to/Dopamine-upstream
# 首次：把 bootstrap_*.tar.zst 下下来
bash Application/Dopamine/Resources/download_bootstraps.sh

# 出包
make -C Application
# 产物：Application/Dopamine.tipa
```

通过 TrollStore 安装该 .tipa 即可。在首次越狱时，`finalizeBootstrap` 阶段你的
`preload-*.deb` 会按数组顺序被 `dpkg -i` 安装。

## 后续：增减预加载文件

随时改 `preload-input/`，再跑一次脚本 → 重新 `make -C Application`。脚本会自动
**清空** Resources 里旧的 `preload-*.deb`（其他 deb 不动），并重写头文件。

## 改了什么？（给做 code review 的人）

一共三处源码改动，**全在 Dopamine-upstream/Application 内**，不涉及 BaseBin：

### 1. `Application/Makefile`
在 `xcodebuild` 之后加一行，把 `Dopamine/Resources/preload-*.deb` 拷进 `Dopamine.app`。
非 preload 命名的 .deb（sileo / zebra / libroot 等上游自带的）不受影响。

### 2. `Application/Dopamine/Jailbreak/DOBootstrapper.m`
- 顶部 `#import "preinstalled_debs.h"`；
- `finalizeBootstrap` 内、`installPackageManagers` 之后，添加循环按数组顺序
  `[self installPackage:debPath]`，失败立即返回错误并打日志。

### 3. 新增 `Application/Dopamine/Jailbreak/preinstalled_debs.h`
脚本生成的 const 数组 + count。零项时退化为 `count=0` 的占位数组，循环不会进入。
**该文件不需要在 .xcodeproj 中显式引用**——它与 DOBootstrapper.m 同目录，预处理器
自动找到。

## 注意事项

### a. 签名必须用 ldid -S（ad-hoc）

ChOma 风格的 fake-signed Mach-O 在 Dopamine 上同样 work，但裸 Mach-O（无
LC_CODE_SIGNATURE）会被 AMFI 拒绝。如果不确定：
```sh
codesign -d --verbose=4 your-binary  # macOS
otool -l your-binary | grep CODE_SIG  # 跨平台
```

### b. dylib + Filter plist 必须同名

ellekit/MobileSubstrate 用 stem 匹配：`com.acme.foo.dylib` 配 `com.acme.foo.plist`。
脚本不会校验，**漏了不会报错但运行时不注入**。

### c. 依赖顺序

`preinstalledDebs` 数组**不解算依赖图**，按你给的目录序逐个 dpkg -i。所以：
- ellekit 之类底层依赖 → `10-` 前缀；
- 业务 dylib → `20-` 之后；
- 已经在 bootstrap_*.tar.zst 里的 Procursus 基础包（apt/dpkg/sh 之类）不需要你管。

### d. plist 路径

Launch daemon plist 里的可执行路径写 jbroot 相对，比如：
```xml
<key>ProgramArguments</key>
<array>
    <string>/usr/local/bin/helloworld</string>
</array>
```
不要写 `/var/jb/usr/local/bin/...`。jbroot-aware launchctl 自动加前缀。

### e. userspace reboot

新装的 daemon 在 `jbctl startup` 末段会被 launchctl bootstrap 一次。如果你在已
越狱设备上更新 .tipa（jbupdate 流程）替换 daemon，需要走 userspace reboot 才能
彻底刷新。

### f. 失败诊断

`finalizeBootstrap` 失败时 DOUIManager 日志会写明哪一个 deb 安装失败、dpkg 返回
码是多少。常见原因：
- 依赖未满足：检查 `depends:` 与目录前缀顺序；
- 文件冲突：deb 试图覆盖 bootstrap 或其它已装包的文件；
- postinst 返回非零：你的脚本里某条命令失败了，set -e 之类导致整体 fail。

## 我要回滚

```sh
cd /home/coder/workspace/mx/dopamine/Dopamine-upstream
git diff --stat                # 看改了哪些
git checkout -- Application    # 撤销 Application 下全部改动
rm -f Application/Dopamine/Jailbreak/preinstalled_debs.h
rm -f Application/Dopamine/Resources/preload-*.deb
```

## 一句话总结

把 Mach-O / dylib / plist 按目标 jbroot 路径放进 `preload-input/<NN-name>/`，跑
`./tools/build-preload-debs.sh`，再去 macOS 上 `make -C Application` —— 就能得到
一个**首次越狱后自动安装并生效**的 Dopamine .tipa。

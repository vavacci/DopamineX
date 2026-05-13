# preload-input/ 投放约定

把要预加载的文件按下面的规则放进来，跑 `../tools/build-preload-debs.sh` 即可
打包并注入到 `Dopamine-upstream/` 源码树。

## 目录结构

每个直接子目录 = 一个 `.deb` 包。**目录名前缀的数字决定安装顺序**（小→大），
后半部分会作为默认包名（除非 `control.yaml` 里覆盖）。

```
preload-input/
├── README.md                        # 本文件
├── 10-acme-runtime/                 # → 生成 acme-runtime.deb，先装
│   ├── control.yaml                 # 元数据（可选）
│   ├── usr/local/bin/helloworld     # 任意原样路径，会被原样落盘到 jbroot 下
│   ├── usr/local/lib/libfoo.dylib
│   ├── Library/LaunchDaemons/
│   │   └── com.acme.helloworld.plist
│   └── DEBIAN/postinst              # 可选，dpkg 安装后立即跑
├── 20-acme-tweaks/                  # → 生成 acme-tweaks.deb
│   ├── control.yaml
│   └── Library/MobileSubstrate/DynamicLibraries/
│       ├── com.acme.spbhook.dylib
│       └── com.acme.spbhook.plist   # ellekit Filter，必须同名
└── _example/                        # 下划线开头 = 跳过（参考模板）
```

> **下划线开头的子目录被脚本忽略**，方便保留模板。

## 两种工作模式

### 模式 A — 「从目录树打包」（默认）

按下面"文件放置规则"投放原始文件，脚本用 dpkg-deb 自动生成 control 与 .deb。
打出的包 Architecture 固定为 `iphoneos-arm64`（Dopamine 2 rootless 默认）。

### 模式 B — 「现成 .deb 直通」

如果某子目录下**只有一个 `.deb` 文件**（且没有其它实质文件，README 除外），
脚本会跳过重打包，直接把该 .deb 拷到 Resources/。适合塞 ellekit、libroot、
社区现成的 tweak deb 之类。例如：

```
preload-input/00-ellekit/ellekit.deb   ← 直通，原样塞进 .tipa
```

直通模式下脚本会读出原 deb 的 Package/Version/Architecture 显示在 summary 里，
并对非 `iphoneos-arm64` / `all` 的 arch 发出警告（**Dopamine 2 拒绝非 arm64 的
deb**）。

## 文件放置规则

| 目标产物 | 放进子目录的相对路径 | 落盘到 |
| --- | --- | --- |
| 可执行 CLI / daemon 二进制 | `usr/local/bin/<name>` 或 `usr/bin/<name>` | `/var/jb/usr/local/bin/<name>` |
| Launch daemon plist | `Library/LaunchDaemons/<label>.plist` | `/var/jb/Library/LaunchDaemons/<label>.plist`（系统重启时由 launchdhook 直接加载） |
| 注入 dylib + Filter | `Library/MobileSubstrate/DynamicLibraries/<name>.{dylib,plist}` | ellekit/TweakLoader 自动扫描 |
| 任意普通文件 | 按目标 jbroot 路径直接镜像 | dpkg 原样安装 |
| 安装后脚本 | `DEBIAN/postinst`（须可执行） | dpkg 自动调用 |

注意路径里**不要**包含 `/var/jb` 前缀——dpkg 在 jbroot 内执行，根就是 jbroot。

## control.yaml（可选）

```yaml
package: com.acme.runtime           # 默认 = 目录名去前缀后加 com.local. 前缀
name: ACME Runtime                  # 默认 = 包名
version: 1.0.0                      # 默认 = 1.0.0
description: ACME preload runtime
depends: ["ellekit (>= 1.0.0)"]     # 可选；ellekit 一般在已装列表
section: Tweaks
maintainer: you <you@example.com>
```

字段全可选；脚本会按目录名 + 缺省值兜底。

## 签名要求

- 你提供的所有 Mach-O **必须已经 `ldid -S` ad-hoc 签好**（脚本不重签）。
- daemon 如果需要 entitlements，需自己 `ldid -SEnt.plist` 处理后再丢进来。

## 跑一遍

```sh
cd /home/coder/workspace/mx/dopamine
./tools/build-preload-debs.sh
```

脚本会：
1. 扫 `preload-input/*/`，按数字前缀排序；
2. 用 `dpkg-deb -Zzstd` 打包；
3. 把 `.deb` 拷到 `Dopamine-upstream/Application/Dopamine/Resources/`；
4. 重写 `Dopamine-upstream/Application/Dopamine/Jailbreak/preinstalled_debs.h`
   把数组按顺序写进去（DOBootstrapper.m 已 `#import` 该头文件）；
5. 打印一份"将随首次越狱安装"清单。

然后在 macOS 上 `make -C Application` 出 `.tipa`。

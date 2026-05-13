# iOS 应用签名与 TrollStore 部署

> 把 ad-hoc 签名、TrollStore 工作原理、`.tipa` 文件本质、自定义 App 打包流程
> 以及与 DopamineX preload 三种部署路径的关系系统性整理在一处。
>
> 配套阅读：
> - [PRELOAD_HOWTO.md](./PRELOAD_HOWTO.md) — preload-deb pipeline 使用指引
> - [PRELOAD_FEASIBILITY.md](./PRELOAD_FEASIBILITY.md) — 改造可行性论证（roothide 分支）
> - [PRELOAD_VANILLA_DOPAMINE.md](./PRELOAD_VANILLA_DOPAMINE.md) — 上游 Dopamine 改造差异

---

## 0. 术语速查表

| 术语 | 一句话定义 |
| --- | --- |
| **Mach-O** | iOS/macOS 可执行二进制格式 |
| **LC_CODE_SIGNATURE** | Mach-O 内的 load command，指向签名 blob |
| **SuperBlob** | 签名 blob 容器（含 CodeDirectory、Entitlements、Requirements、CMS signature 等多个 slot） |
| **CodeDirectory** | 把 Mach-O 各页 hash 串成 Merkle 树的结构，最终摘要即 cdhash |
| **cdhash** | 整段 CodeDirectory 的哈希，签名身份的"指纹" |
| **ad-hoc 签名** | SuperBlob 结构齐全但 CMS 签名为空的签名形态 |
| **AMFI** | Apple Mobile File Integrity，内核态签名检查策略模块 |
| **CoreTrust** | iOS 用户态签名验证 framework（TrollStore 利用其 bug） |
| **`.ipa`** | 标准 iOS 安装包，本质是 `Payload/X.app/` 目录结构的 zip |
| **`.tipa`** | "trolled IPA"，与 `.ipa` 内部结构完全相同，仅后缀习惯 |
| **TrollStore** | 利用 CoreTrust bug 把 ad-hoc 签名 App 当作 Apple 系统签名 App 安装的工具 |
| **trustcache** | 内核维护的 cdhash 白名单；越狱后由 Dopamine 写入 |

---

## 1. ad-hoc 签名详解

### 1.1 与 Apple Developer 签名的结构对比

```
正常签名 (Apple Developer):              ad-hoc 签名:
┌──────────────────────────┐            ┌──────────────────────────┐
│ CodeDirectory (cdhash)   │            │ CodeDirectory (cdhash)   │  ← 仍计算
│ Requirements             │            │ Requirements             │  ← 仍写入
│ Entitlements             │            │ Entitlements             │  ← 仍写入
│ SignatureSlot ★          │            │ SignatureSlot: (empty)   │  ← 唯一区别
│   └─ CMS PKCS#7 signature│            │                          │
│       └─ leaf certificate│            │                          │
│           ↓              │            │                          │
│         Apple Root CA    │            │                          │
└──────────────────────────┘            └──────────────────────────┘
```

**SuperBlob 结构是完整的**——cdhash 照算、entitlements 照写。差别只在 CMS
slot 是空的，即没有"由谁签发"的证据。

### 1.2 工具

| 工具 | 平台 | 用法 |
| --- | --- | --- |
| `ldid -S` | Linux / macOS | ad-hoc 签当前文件 |
| `ldid -SEnt.plist` | Linux / macOS | ad-hoc 签 + 注入 entitlements |
| `ldid -s <file_or_dir>` | Linux / macOS | 递归签整个目录 |
| `codesign -s -` | 仅 macOS | Apple 自带，等价 |

`ldid` 是 Procursus 维护的开源工具（`apt install ldid` 或从 ChariZ 仓库安装），
**纯本地操作**，无需联网、无需账号。

### 1.3 "能不能签 / 能不能装" 矩阵

| 操作 | 需要的前提 |
| --- | --- |
| **生成 ad-hoc 签名** | 只要 ldid（无账号、无网络） |
| **装到普通 iOS** | ❌ AMFI 拒绝（找不到证书链到 Apple Root CA） |
| **装到越狱设备** | ✅ cdhash 进 trustcache 即可（dpkg 装的 deb 由 systemhook 自动 trustcache） |
| **通过 TrollStore 装** | ✅ CoreTrust bug 让 ad-hoc 被当作系统签名接受 |

---

## 2. TrollStore 工作原理

### 2.1 CoreTrust 0day（核心机制）

```
正常流程:        Apple 颁发证书 → 开发者签名 → CoreTrust 验 leaf cert chain → 通过则装
                                                ^^^^^^^^^^^^^^^^^^^^^^^^^^
                                                这里有 bug

TrollStore 利用: 任意 ad-hoc 签名 → CoreTrust 错把它当作 Apple 系统级签名 → 装为 platform-app
```

CoreTrust 在校验 cdhash 签名时漏算了一步：**任何带 SuperBlob 的 Mach-O**——
不论 CMS slot 是否为空、是否能验证证书链——都会被当成"Apple 自己签的系统组件"。

被 TrollStore 装上的 App 在 iOS 视角等同于系统二进制，**不存在"证书过期"概念**。

### 2.2 "永久" 的精确边界

| 维度 | 是否永久 |
| --- | --- |
| ✅ 不依赖证书续签 | 跟普通 sideload 7 天 / 1 年掉签无关 |
| ✅ 重启不掉签 | App 一旦装上，cdhash 已被系统接受 |
| ✅ 不需要 Apple Developer 账号 | — |
| ❌ iOS 升级即失效 | Apple 修复了 CoreTrust bug 的版本会拒绝 ad-hoc |
| ❌ 用户手动删 TrollStore 后不能再装新 App | 已装的仍能跑 |

### 2.3 当前支持版本（截至 2025 年观察）

| iOS 版本 | TrollStore |
| --- | --- |
| 14.0 – 14.8.1 | ✅ |
| 15.0 – 15.7.x | ✅ |
| 16.0 – 16.6.1 | ✅ |
| 16.7+ | ❌ |
| 17.0（部分 build） | 部分 ✅ |
| 17.1+ | ❌ |

确切支持矩阵以 [TrollStore 项目页](https://github.com/opa334/TrollStore) 为准。

### 2.4 Persistence Helper

TrollStore 自身一旦设备重启后**也会"半失效"**——能用网页 manual install
URL 重新触发，但流程繁琐。

**Persistence Helper** 是把 TrollStore 注入到某个系统 App entitlements 链里
的小技巧（如 `Tips`、`asset-cache`），让 TrollStore 能跨重启保持启动能力。
强烈建议安装。已装的 App **不受 Persistence Helper 状态影响**。

---

## 3. `.tipa` 文件本质

### 3.1 内部结构

```
MyApp.tipa  (= zip 容器)
└── Payload/
    └── MyApp.app/
        ├── MyApp                       Mach-O 主二进制（ldid -S 签好）
        ├── Info.plist
        ├── embedded.mobileprovision    TrollStore 不需要，可省
        ├── Frameworks/
        │   └── *.framework             递归签
        └── PlugIns/
            └── *.appex                 扩展（含独立 Mach-O，需签）
```

### 3.2 与 `.ipa` 的关系

**完全一样的文件格式**。`.tipa` 后缀只是社区约定，用来标识"这个 IPA 准备
好走 TrollStore 安装"。TrollStore 同时接受 `.ipa` 和 `.tipa`。

### 3.3 与 Dopamine 的关系

Dopamine 也是以 `.tipa` 形式发布，由用户通过 TrollStore 装到设备上。
[Application/Makefile:14] 完成 `make Dopamine.tipa = cp Dopamine.ipa Dopamine.tipa`
后缀别名。

---

## 4. 自己开发 App 打 `.tipa` 完整流程

### 4.1 Xcode 构建（关掉 Apple 签名）

```sh
xcodebuild -scheme MyApp \
    -derivedDataPath build \
    -destination 'generic/platform=iOS' \
    -sdk iphoneos \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO

APP=build/Build/Products/Release-iphoneos/MyApp.app
```

或在 Xcode GUI：Target → Signing & Capabilities → 取消 "Automatically manage
signing"，Provisioning Profile 选 None。

### 4.2 entitlements 模板

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 把 App 标识为 platform，TrollStore 安装时会保留 -->
    <key>platform-application</key>
    <true/>

    <!-- 跳出 iOS 应用沙箱（读其它 App 数据） -->
    <key>com.apple.private.security.no-container</key>
    <true/>

    <!-- 想要的任意 entitlement，TrollStore 会保留绝大多数 -->
    <!-- 例: <key>com.apple.springboard.launchapplications</key><true/> -->
</dict>
</plist>
```

### 4.3 签名

```sh
xattr -rc "$APP"                          # 清 macOS 扩展属性
ldid -Sentitlements.plist "$APP/MyApp"    # 主二进制带 entitlements 签
ldid -s "$APP"                            # 递归签所有 dylib / framework / appex
```

### 4.4 打 `.tipa`

```sh
rm -rf Payload MyApp.tipa MyApp.ipa
mkdir Payload
cp -r "$APP" Payload/
zip -r MyApp.ipa Payload
cp MyApp.ipa MyApp.tipa                   # 别名
rm -rf Payload
```

### 4.5 投递

- **AirDrop** 到设备 → Files 里看到 → 长按 → "Share" → "TrollStore"
- 或 HTTP 服务器托管 → TrollStore 内 URL install
- 或 `ideviceinstaller -i MyApp.tipa`

---

## 5. TrollStore App 实际拿到的权限

✅ **能做**：
- 读写自己 App 容器 (`/var/mobile/Containers/Data/Application/<UUID>/`)
- **读其它 App 容器**（普通 sideload 做不到）
- 读写 `/var/mobile/Media` 全盘
- 调用部分 SPI / private framework
- 后台无限驻留（不受常规 jetsam 限制）
- 启动其它 App、模拟 home button（若 entitlements 声明）

❌ **不能做**（这些需要真正越狱）：
- `ptrace` / `task_for_pid` 其它进程
- 改 `/`（rootfs 是 read-only volume，与 root user 权限无关）
- 内核 kalloc / kread / kwrite
- 注入 dylib 到任意进程（要靠 Dopamine systemhook + ellekit）

---

## 6. 与 DopamineX preload 的对比

DopamineX 的"预加载"机制可以承载三种交付物，它们与 TrollStore .tipa 是
互补关系，不是替代：

| 形态 | 加载方式 | 何时生效 | 落盘路径 | 适用场景 |
| --- | --- | --- | --- | --- |
| **TrollStore `.tipa`** | 用户点桌面图标 | 立即、永久（iOS 不升级前提下） | `/private/var/containers/Bundle/Application/<UUID>/` | 独立 App，**未越狱也能跑**；需要 platform 权限的工具型 App |
| **ellekit tweak (`.dylib + .plist`)** | 目标进程 spawn 时 TweakLoader dlopen | **越狱激活后**才生效 | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` | 注入式 hook（如 Facehugger） |
| **jbroot 普通 App (`/var/jb/Applications/MyApp.app/`)** | SpringBoard 启动 | 越狱激活后 | `/var/jb/Applications/` | 越狱专属 GUI 工具 |
| **jbroot CLI / daemon** | shell 或 launchd | 越狱激活后（daemon 由 launchdhook 加载） | `/var/jb/usr/local/bin/`、`/var/jb/Library/LaunchDaemons/` | 后台服务、命令行工具 |

### 6.1 选择决策树

```
你的交付物是什么？
├─ 一个有 UI 的独立 App（不依赖越狱也要能跑）
│  └─→ 打 .tipa，单独通过 TrollStore 装
│
├─ 一个有 UI 的越狱专属 App
│  └─→ 放进 preload-input/<N>-myapp/Applications/MyApp.app，越狱激活后桌面出现
│
├─ 一个注入式 hook (dylib + Filter plist)
│  └─→ 放进 preload-input/<N>-hook/Library/MobileSubstrate/DynamicLibraries/
│
└─ 一个后台 daemon / CLI 工具
   └─→ 放进 preload-input/<N>-tool/{usr/local/bin/, Library/LaunchDaemons/}
```

### 6.2 何时考虑"两条路径都走"

如果你的工具想：

- **未越狱时**：以 TrollStore App 形态提供基础功能（读其它 App 数据、读全盘）
- **越狱时**：通过同一份 dylib 跨进程注入，获得 ptrace / 内核能力

可以把核心逻辑做成 **dylib**，再写两层壳：
1. TrollStore App 主程序 dlopen 它（在自身进程内调用）
2. ellekit Filter 把它注入到 SpringBoard / 目标 App

两份发布物共用同一份 dylib 源码。

---

## 7. 常见误区

### 误区 1：「TrollStore 永久 = 任何时候都能用」

❌ iOS 升级会失效。升级前先确认目标版本仍在 TrollStore 支持列表内。

### 误区 2：「ad-hoc 签名不安全 / 容易被检测」

ad-hoc 签名**不是漏洞**，它是 Apple 自己定义的合法签名类型，macOS 系统二进制
有些就是 ad-hoc 签的。"被检测"指的是越狱检测脚本扫 `/var/jb` 之类路径；
跟签名形态无关。

### 误区 3：「自己开发的 App 要先在 Apple Developer 注册 bundle ID」

❌ ad-hoc + TrollStore 不走 App Store，无需任何 Apple 侧注册。bundle ID 只需
不与系统 App / 已装 App 冲突，可以瞎写如 `com.local.foo`。

### 误区 4：「`.tipa` 必须跟 `.ipa` 不一样」

二者文件格式完全相同。改后缀只是社区约定。

### 误区 5：「TrollStore 装的 App 等于越狱」

❌ TrollStore App 拿到的是 **platform-level 权限**，比普通 App 强很多但比越狱
弱。无法 `task_for_pid`、无法跨进程注入、无法改 rootfs。真正的越狱能力靠
Dopamine。

### 误区 6：「entitlements 写啥都行」

声明 entitlement ≠ 内核会授予能力。但 **TrollStore 把 App 标为
platform-application** 后，绝大多数私有 entitlement 实际生效——这正是
TrollStore 强大的地方。

### 误区 7：「越狱后 dpkg 装的 dylib 自动被信任」

不会自动；由 **systemhook 的 spawn 钩子** 在新进程 exec 时检测路径并调
`systemwide_trust_file_by_path` 把 cdhash 写入 trustcache。Dopamine 越狱激活
状态下这一切是自动的；**越狱失活时 dylib 落盘但不会被注入**。

---

## 8. 参考资料

- TrollStore 项目：<https://github.com/opa334/TrollStore>
- Dopamine 项目：<https://github.com/opa334/Dopamine>
- Procursus（Dopamine 用的 rootless bootstrap 上游）：<https://github.com/ProcursusTeam>
- ldid（开源 ad-hoc 签名工具）：<https://github.com/ProcursusTeam/ldid>
- ChOma（Dopamine 用的 Mach-O 库，含 ad-hoc 签名实现）：<https://github.com/opa334/ChOma>
- ellekit（Substrate 替代品，提供 TweakLoader）：<https://ellekit.space>

---

## 9. 一句话总结

- **ad-hoc 签名** = 有 SuperBlob 没 CMS slot，纯本地用 ldid 即可生成
- **TrollStore** 把 ad-hoc 当 Apple 签接受，**不签 Apple 证书也能装上 iOS 且永久不掉签**（前提：iOS 版本在支持列表内）
- **`.tipa`** 本质是 `.ipa`，结构相同
- 自己开发的 App **完全可以** 走 `xcodebuild → ldid -S → zip 成 .tipa → TrollStore` 流程
- DopamineX 的 **preload 机制是补充**：用于跨越狱激活把 dylib/二进制/daemon 一次性预装到 jbroot

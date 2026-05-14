# App Extension 与 Entitlements 在 ad-hoc / TrollStore 流程下的处理

> 配套阅读：
> - [SIGNING_AND_DEPLOYMENT.md](./SIGNING_AND_DEPLOYMENT.md) — ad-hoc / TrollStore / `.tipa` 总览
> - [PRELOAD_HOWTO.md](./PRELOAD_HOWTO.md) — DopamineX preload-deb pipeline

> **现成模板**：`docs/templates/` 下有 `build.sh` / `Makefile` /
> `trollstore.xcconfig` / `sign-tipa.sh` / `Entitlements/*.entitlements` 全套
> 可直接 `cp -r docs/templates/* /path/to/MyApp/` 到你的 App 项目根使用，
> 不必从本文档复制粘贴。

含 App Extension 的 iOS 项目走 ad-hoc + TrollStore 安装时，会被 Xcode 的
**Capability Validation** 阶段拦下，最典型的报错就是：

```
"ScreenBroadcastExtension" requires a provisioning profile with the App Groups feature.
Select a provisioning profile in the Signing & Capabilities editor.
```

本文档把绕过流程系统化整理，**可直接套用到任何含 Extension 或带 capability
key 的 entitlements 项目**（App Groups / Push Notifications / Broadcast Services
/ Inter-App Audio / HealthKit / Associated Domains 等同理）。

---

## 0. 速查决策树

```
项目含 *.appex 或 entitlements 里有 com.apple.*.* / com.apple.security.* key？
│
├─ 否 → 用 SIGNING_AND_DEPLOYMENT.md §4 标准流程即可
│
└─ 是 → 是否真的需要这些 capability 的功能？
    │
    ├─ 不需要（只是模板默认带的）
    │  └─→ Xcode → Signing & Capabilities → (-) 删除 capability → 标准流程
    │
    └─ 需要保留功能
        └─→ 走"xcconfig 清空 entitlements + ldid 后注入"流程（本文档主体）
```

---

## 1. 报错的根本原因

Xcode 的 build pipeline 含两套独立校验：

| 阶段 | 控制开关 | 校验内容 |
| --- | --- | --- |
| **Code Signing** | `CODE_SIGN_IDENTITY` / `CODE_SIGNING_REQUIRED` | 是否签 Apple 证书；用哪个 identity |
| **Capability Validation** | `CODE_SIGN_ENTITLEMENTS` / `ENTITLEMENTS_REQUIRED` | 静态分析 entitlements 文件，看 key 是否被 provisioning profile 授权 |

`SIGNING_AND_DEPLOYMENT.md` §4.1 介绍的 `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
**只关掉第一套**；只要 entitlements 文件还在 build 流程里、且含 `com.apple.security.application-groups`
之类的 key，第二套校验仍会触发并要求 provisioning profile。

**核心思路**：让 Xcode build 期间**完全看不到** entitlements 文件
（`CODE_SIGN_ENTITLEMENTS=""`），build 完后用 `ldid` 手动把 entitlements 注入
Mach-O。Xcode capability validator 没东西可校验，所以不报错。

---

## 2. 推荐方案：xcconfig 全局覆盖 + ldid 后注入

### 2.1 创建 `trollstore.xcconfig`

放在项目根目录或单独的 `Config/` 子目录：

```xcconfig
// trollstore.xcconfig — disable all signing + entitlements validation
// Applies to all targets and all configurations (Debug/Release).

// Code Signing
CODE_SIGN_IDENTITY =
CODE_SIGNING_REQUIRED = NO
CODE_SIGNING_ALLOWED = NO
DEVELOPMENT_TEAM =
PROVISIONING_PROFILE_SPECIFIER =
PROVISIONING_PROFILE =

// Capability Validation —— 关键的两行
CODE_SIGN_ENTITLEMENTS =
ENTITLEMENTS_REQUIRED = NO

// 历史包袱
ENABLE_BITCODE = NO

// 可选：避免 Xcode 把 Swift Runtime 重新签
ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES
```

### 2.2 构建时挂载

```sh
xcodebuild -scheme MyApp \
    -derivedDataPath build \
    -destination 'generic/platform=iOS' \
    -sdk iphoneos \
    -configuration Release \
    -xcconfig trollstore.xcconfig
```

`-xcconfig` 会**叠加在所有 target 与所有 configuration 之上**，含 App / Extension
/ Frameworks，所以一份配置覆盖整个项目。

### 2.3 写好"真实"的 entitlements 文件（build 流程之外）

这些文件**不放进 Xcode 的 `Code Sign Entitlements` 字段**，而是放在源码树
随便一个地方（比如 `Entitlements/`），仅供 ldid 后处理使用。

**主 App** — `Entitlements/MyApp.entitlements`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key>
    <true/>

    <!-- App Groups: group ID 任意起；不需 Apple Developer Portal 注册 -->
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.local.myapp</string>
    </array>

    <!-- 想要的其它 entitlements 全写这里，TrollStore 会保留绝大部分 -->
</dict>
</plist>
```

**Extension** — `Entitlements/ScreenBroadcastExtension.entitlements`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key>
    <true/>

    <!-- 必须与主 App 完全一致，否则容器找不到 -->
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.local.myapp</string>
    </array>

    <!-- ReplayKit broadcast extension 常用 -->
    <key>com.apple.developer.broadcast-services</key>
    <true/>
</dict>
</plist>
```

> **关键约束**：所有共用 App Group 的 target（主 App、所有 extensions），
> `com.apple.security.application-groups` 数组里的 string **必须完全字面一致**，
> 连大小写都要。运行时 `containerURLForSecurityApplicationGroupIdentifier:`
> 才能定位到同一个 group container。

### 2.4 编写后处理签名脚本

`scripts/sign-tipa.sh`（建议放进 repo）：

```sh
#!/usr/bin/env bash
set -euo pipefail

APP="${1:-build/Build/Products/Release-iphoneos/MyApp.app}"
APP_ENTS="Entitlements/MyApp.entitlements"
EXT_ENTS="Entitlements/ScreenBroadcastExtension.entitlements"
EXT_NAME="ScreenBroadcastExtension"

if [[ ! -d "$APP" ]]; then
    echo "App bundle not found: $APP" >&2
    exit 1
fi

# 1. 清除 macOS 扩展属性（quarantine 等）
xattr -rc "$APP"

# 2. 主 App 二进制带 entitlements ad-hoc 签
ldid -S"$APP_ENTS" "$APP/$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")"

# 3. 每个 Extension 单独带自己的 entitlements
for ext in "$APP/PlugIns/"*.appex; do
    [[ -d "$ext" ]] || continue
    ext_name=$(basename "$ext" .appex)
    ext_bin=$(plutil -extract CFBundleExecutable raw "$ext/Info.plist")
    ents="Entitlements/${ext_name}.entitlements"
    if [[ -f "$ents" ]]; then
        echo "[ext] $ext_name ← $ents"
        ldid -S"$ents" "$ext/$ext_bin"
    else
        echo "[ext] $ext_name has no custom entitlements, ad-hoc only"
        ldid -S "$ext/$ext_bin"
    fi
done

# 4. 兜底：递归 ad-hoc 签所有剩余 Mach-O（Frameworks / dylib 等）
ldid -s "$APP"

# 5. 验证
echo
echo "===== verification ====="
codesign -dvv "$APP/$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")" 2>&1 | head -8
echo
echo "App entitlements:"
ldid -e "$APP/$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")"
echo
for ext in "$APP/PlugIns/"*.appex; do
    [[ -d "$ext" ]] || continue
    ext_bin=$(plutil -extract CFBundleExecutable raw "$ext/Info.plist")
    echo "Extension $(basename "$ext") entitlements:"
    ldid -e "$ext/$ext_bin"
    echo
done
```

加可执行权限：`chmod +x scripts/sign-tipa.sh`。

### 2.5 完整 Makefile 模板

```makefile
APP_NAME       = MyApp
SCHEME         = MyApp
DERIVED        = build
APP            = $(DERIVED)/Build/Products/Release-iphoneos/$(APP_NAME).app

.PHONY: all build sign tipa clean

all: tipa

build:
	xcodebuild -scheme $(SCHEME) \
	    -derivedDataPath $(DERIVED) \
	    -destination 'generic/platform=iOS' \
	    -sdk iphoneos \
	    -configuration Release \
	    -xcconfig trollstore.xcconfig

sign: build
	./scripts/sign-tipa.sh $(APP)

tipa: sign
	rm -rf Payload $(APP_NAME).ipa $(APP_NAME).tipa
	mkdir Payload
	cp -r $(APP) Payload/
	zip -r $(APP_NAME).ipa Payload
	cp $(APP_NAME).ipa $(APP_NAME).tipa
	rm -rf Payload
	@echo
	@echo "==> $(APP_NAME).tipa ready"

clean:
	rm -rf $(DERIVED) Payload $(APP_NAME).ipa $(APP_NAME).tipa
```

一条命令出 `.tipa`：

```sh
make
```

### 2.6 等价的纯 shell 一键脚本（不依赖 make）

如果你不想用 `make`，下面这份 `build.sh` 把整条流水线串成纯 shell。
**两种选一即可，功能完全等价**。

```sh
#!/usr/bin/env bash
# 一键出 .tipa：xcodebuild → ldid → zip
# 用法：cd 到项目根 → ./build.sh
set -euo pipefail

cd "$(dirname "$0")"                                 # 切到脚本所在目录（= 项目根）

APP_NAME="MyApp"                                     # ← 改成你的 App 名字
SCHEME="MyApp"                                       # ← Xcode scheme（通常与 App 同名）
DERIVED="build"
APP="$DERIVED/Build/Products/Release-iphoneos/${APP_NAME}.app"

# 1. 前置依赖
if ! command -v ldid >/dev/null; then
    echo "ldid not found. Install via: brew install ldid" >&2
    exit 1
fi

# 2. xcodebuild —— 关键就是 -xcconfig 那一行把 trollstore.xcconfig 挂上去
echo "==> [1/3] xcodebuild"
xcodebuild \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED" \
    -destination 'generic/platform=iOS' \
    -sdk iphoneos \
    -configuration Release \
    -xcconfig trollstore.xcconfig

if [[ ! -d "$APP" ]]; then
    echo "App bundle not built: $APP" >&2
    exit 2
fi

# 3. ldid 后处理：清扩展属性 → 注入 entitlements → 兜底递归签
echo
echo "==> [2/3] ldid sign + inject entitlements"
xattr -rc "$APP"

# 3a. 主 App
APP_BIN=$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")
ldid -SEntitlements/${APP_NAME}.entitlements "$APP/$APP_BIN"
echo "  [app] $APP_BIN ← Entitlements/${APP_NAME}.entitlements"

# 3b. 所有 Extension：每个 *.appex 都尝试匹配同名 .entitlements 文件
for ext in "$APP/PlugIns/"*.appex; do
    [[ -d "$ext" ]] || continue
    ext_name=$(basename "$ext" .appex)
    ext_bin=$(plutil -extract CFBundleExecutable raw "$ext/Info.plist")
    ext_ents="Entitlements/${ext_name}.entitlements"
    if [[ -f "$ext_ents" ]]; then
        ldid -S"$ext_ents" "$ext/$ext_bin"
        echo "  [ext] $ext_name ← $ext_ents"
    else
        ldid -S "$ext/$ext_bin"
        echo "  [ext] $ext_name ← (ad-hoc only, no entitlements file)"
    fi
done

# 3c. 兜底：递归 ad-hoc 签 Frameworks / 其它 dylib
ldid -s "$APP"

# 4. 打 .tipa（其实就是 .ipa 改后缀）
echo
echo "==> [3/3] pack .tipa"
rm -rf Payload "${APP_NAME}.ipa" "${APP_NAME}.tipa"
mkdir Payload
cp -r "$APP" Payload/
zip -qr "${APP_NAME}.ipa" Payload
cp "${APP_NAME}.ipa" "${APP_NAME}.tipa"
rm -rf Payload

# 5. 校验
echo
echo "==> verify"
echo "App entitlements (head):"
ldid -e "$APP/$APP_BIN" | head -15
echo
echo "Output: ${APP_NAME}.tipa ($(du -h "${APP_NAME}.tipa" | cut -f1))"
```

落盘并赋可执行权限：

```sh
chmod +x build.sh
./build.sh
```

### 2.7 Makefile vs shell vs Run Script Phase 怎么选

| 场景 | 推荐 |
| --- | --- |
| 大多数时间 Xcode GUI 调试，偶尔出包 | **§2.6 `build.sh`** —— 需要出包时切终端一行命令 |
| 习惯 `make` / 要接 CI（GitHub Actions、Jenkins）| **§2.5 `Makefile`** —— `make tipa` 接到任何流水线 |
| 想点 Xcode "Build" 按钮就自动跑 ldid | **Xcode → TARGETS → Build Phases → New Run Script Phase**（见下） |

#### 可选：在 Xcode GUI 内挂 Run Script Phase

如果想点 Xcode "Build" 按钮就连带 ldid 后处理（仅签名，**不出 .tipa**）：

```
TARGETS → 主 App → Build Phases tab → 左上角 + → New Run Script Phase
→ 把新 phase 拖到所有 phase 的最末尾
→ Shell: /bin/sh
→ Script:
```

```sh
set -e
APP="${CODESIGNING_FOLDER_PATH}"
ENTS_DIR="${SRCROOT}/Entitlements"

xattr -rc "$APP"

APP_BIN=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist")
# 注意：Run Script Phase 不走 user PATH，必须用 ldid 绝对路径
/opt/homebrew/bin/ldid -S"${ENTS_DIR}/$(basename "$APP" .app).entitlements" "$APP/$APP_BIN"

for ext in "$APP/PlugIns/"*.appex; do
    [ -d "$ext" ] || continue
    ext_name=$(basename "$ext" .appex)
    ext_bin=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$ext/Info.plist")
    ents="${ENTS_DIR}/${ext_name}.entitlements"
    if [ -f "$ents" ]; then
        /opt/homebrew/bin/ldid -S"$ents" "$ext/$ext_bin"
    else
        /opt/homebrew/bin/ldid -S "$ext/$ext_bin"
    fi
done

/opt/homebrew/bin/ldid -s "$APP"
```

> **Apple Silicon Mac**：ldid 路径 `/opt/homebrew/bin/ldid`
> **Intel Mac**：ldid 路径 `/usr/local/bin/ldid`
>
> Run Script Phase 只完成 sign，不打 `.tipa`——出包仍需 `build.sh` / `make` /
> 手工 zip 那一步。所以这条路一般只在"Xcode GUI 内部 build 调试"时用，
> 正经出 .tipa 仍走 §2.5 / §2.6。

---

## 3. 替代方案对比

| 方案 | 是否动 `.xcodeproj` | 适合 |
| --- | --- | --- |
| **xcconfig + ldid 后注入**（本文档主体） | ❌ | 推荐。可入 Git、CI 友好 |
| GUI 删 extension 的 App Groups capability | ✅ | 你**不真需要**跨进程共享数据时（功能会丢） |
| GUI 改每个 target 的 `Code Sign Entitlements` 字段清空 | ✅ | 不想用 xcconfig 时；要逐 target 改 |
| 整个 extension target 设 `CODE_SIGNING_ALLOWED=NO` | ✅ | 仅个别 target 微调 |

xcconfig 方案的优势：

- **零侵入 `.xcodeproj`**——团队里有用 Apple 证书出 App Store 包的同事可以共用同一份项目
- **可入 Git**——`trollstore.xcconfig` 是普通文本
- **CI 友好**——构建命令只多一个 `-xcconfig` 参数

---

## 4. 常见 capability 的 entitlements 模板

把这些 key 直接拼到上面的 `MyApp.entitlements` 里即可，**不需要** Apple
Developer Portal 注册。

### 4.1 App Groups

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.local.myapp</string>
</array>
```

### 4.2 Push Notifications

```xml
<key>aps-environment</key>
<string>production</string>
```

> 普通 sideload 无法收到真实 push（需要 APNs token + 服务器），TrollStore 装的
> App 也一样——但本地 `UNUserNotificationCenter` 通知功能可用，不需要这个
> entitlement。

### 4.3 Broadcast Services (ReplayKit Broadcast Extension)

```xml
<key>com.apple.developer.broadcast-services</key>
<true/>
```

### 4.4 Inter-App Audio

```xml
<key>inter-app-audio</key>
<true/>
```

### 4.5 HealthKit

```xml
<key>com.apple.developer.healthkit</key>
<true/>
<key>com.apple.developer.healthkit.access</key>
<array/>
```

### 4.6 Associated Domains（Universal Links）

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:example.com</string>
</array>
```

> Associated Domains 即便 entitlement 写进去，也需要 example.com 的
> `.well-known/apple-app-site-association` 文件配合。TrollStore 不影响这部分。

### 4.7 SystemUI / Private Bypass（仅 TrollStore 有效）

```xml
<key>com.apple.private.security.no-container</key>
<true/>

<key>com.apple.private.security.container-required</key>
<false/>

<key>com.apple.springboard.launchapplications</key>
<true/>
```

这些 `com.apple.private.*` key 在普通 sideload 完全无效；TrollStore 装的
platform-app 实际生效，是 TrollStore App 强权的核心来源。

---

## 5. 验证脚本与排错清单

### 5.1 检验 entitlements 落对位置

```sh
APP=build/Build/Products/Release-iphoneos/MyApp.app

# 主 App
ldid -e "$APP/MyApp"

# Extension
ldid -e "$APP/PlugIns/ScreenBroadcastExtension.appex/ScreenBroadcastExtension"
```

期望输出含 `<key>com.apple.security.application-groups</key>` 等键。

### 5.2 检验签名形态

```sh
codesign -dvv "$APP/MyApp" 2>&1 | grep -E "Signature|Identifier|Authority"
```

期望：
```
Signature=adhoc
Identifier=com.your.app
```

**绝对不能出现** `Authority=Apple Development: ...`。

### 5.3 报错对照表

| 报错 | 原因 | 修复 |
| --- | --- | --- |
| `requires a provisioning profile with the X feature` | xcconfig 没生效或 `CODE_SIGN_ENTITLEMENTS` 没清空 | 检查 `xcodebuild -xcconfig` 路径；确认 build log 显示 `CODE_SIGN_ENTITLEMENTS = `（空） |
| `invalid entitlements plist` | ldid 解析失败，xml 格式有问题 | `plutil -lint MyApp.entitlements` 校验；删掉非法注释 |
| App 装上后崩溃在启动 | 主 App / Extension entitlements 不一致 | `ldid -e` 对比两边 group ID 是否完全字面一致 |
| Extension 不能跨进程读 group container | group ID 不一致或没写 | 重新对照 §2.3 |
| `Authority=Apple Development: ...` 仍出现 | Xcode 仍在签 Apple cert | 检查 `Build Settings` 里 `CODE_SIGN_IDENTITY` 是否真的被 xcconfig 覆盖；用 `xcodebuild -showBuildSettings` 看 effective value |
| 安装 .tipa 时 TrollStore 报 "Failed to install: -402620394" | entitlements 含 TrollStore 黑名单 key（极少见） | 移除可疑 entitlement，重打 |
| `ldid.cpp(3335): _assert(): flag_S` | **ldid 旧版本递归签** `*.app` **目录时遇到含 entitlements 的子二进制 assert** | 详见 §5.4 |

### 5.4 `ldid -s` 递归签 `*.app` 时 assert（flag_S）

#### 现象

`build.sh` 跑到第 3c 步 `ldid -s "$APP"` 兜底递归签时**直接 die**，最后一行
是：

```
ldid.cpp(3335): _assert(): flag_S
```

`set -euo pipefail` 让脚本立刻退出，**第 4 步打 .tipa 根本没跑**，项目根
目录不会出现 `*.tipa` 文件。

#### 根因

ldid 在递归处理 `*.app` 目录时，对**已经被注入 entitlements** 的子 binary
（例如刚才用 `ldid -S<file>.entitlements` 签的主 App / Extension Mach-O）做
"`-s`（不带 entitlements 重签）"逻辑判断时触发内部 assertion。这是 ldid 较旧
版本（≤ 2.1.x 系列某些 build）的设计 bug——issue tracker 上有讨论。

#### 修复（已合入 build.sh / sign-tipa.sh）

最新 build.sh / sign-tipa.sh 已把这一行：

```sh
ldid -s "$APP"
```

改成容错版本：

```sh
if ! ldid -s "$APP" 2>/dev/null; then
    echo "  ldid -s recursive failed (likely old ldid + entitled child binary)"
    echo "  falling back to per-dylib signing"
    while IFS= read -r f; do
        ldid -S "$f" 2>/dev/null || true
    done < <(find "$APP" -type f \( -name "*.dylib" -o -name "*.so" \))
fi
```

行为：

1. 先尝试 `ldid -s` 递归签
2. 失败则降级为**逐文件**`-S` 重签 Frameworks 下所有 `*.dylib` / `*.so`
3. 即便都失败也不阻断流程——Xcode 在 `CODE_SIGNING_ALLOWED=NO` 下通常已经
   替我们 ad-hoc 签好了 Frameworks

#### 应急：手工补 .tipa

如果脚本已经死在此处但前两步签名已成功，直接手工跑打包：

```sh
APP_NAME=YourAppName                                # ← 改成你的
APP=build/Build/Products/Release-iphoneos/${APP_NAME}.app

rm -rf Payload "${APP_NAME}.ipa" "${APP_NAME}.tipa"
mkdir Payload && cp -r "$APP" Payload/
zip -qr "${APP_NAME}.ipa" Payload
cp "${APP_NAME}.ipa" "${APP_NAME}.tipa"
rm -rf Payload
ls -lh "${APP_NAME}.tipa"
```

立即得到可用 `.tipa`。

#### 验证 Frameworks 是否已被 Xcode 自动签

如果你担心跳过递归签会导致 AMFI 拒载，跑这段：

```sh
APP=build/Build/Products/Release-iphoneos/YourAppName.app
find "$APP/Frameworks" -name "*.dylib" -type f 2>/dev/null | while read -r f; do
    if codesign -dv "$f" 2>&1 | grep -q "Signature"; then
        echo "  ✓ $(basename "$f")"
    else
        echo "  ✗ $(basename "$f")  ← 没签名"
    fi
done
```

- 全 `✓` → `.tipa` 直接可装
- 任意 `✗` → 逐个补签：
  ```sh
  find "$APP" -type f \( -name "*.dylib" -o -name "*.so" \) | while read -r f; do
      codesign -dv "$f" 2>/dev/null | grep -q Signature || ldid -S "$f"
  done
  # 然后重新跑上一节的"应急手工补 .tipa"
  ```

#### 长期解决：升级 ldid

```sh
brew uninstall ldid 2>/dev/null
brew install ldid                # Procursus 维护，主线最新
ldid 2>&1 | head -1              # 看 banner 确认版本
```

升级后 fallback 分支大概率根本不会触发。

### 5.5 用 `-showBuildSettings` 验证 xcconfig 生效

```sh
xcodebuild -scheme MyApp \
    -sdk iphoneos \
    -xcconfig trollstore.xcconfig \
    -showBuildSettings | grep -E "CODE_SIGN|ENTITLEMENTS|PROVISIONING"
```

期望看到的 effective value：

```
CODE_SIGN_ENTITLEMENTS = 
CODE_SIGN_IDENTITY = 
CODE_SIGNING_ALLOWED = NO
CODE_SIGNING_REQUIRED = NO
ENTITLEMENTS_REQUIRED = NO
PROVISIONING_PROFILE_SPECIFIER = 
```

如果其中某项**不是**空 / NO，说明 .xcodeproj 里的 build setting 优先级压过了
xcconfig（少数情况下 Xcode 把 setting 写死在 target 配置里），需要回 GUI
Build Settings 里手动清空那一项。

---

## 6. 跟 DopamineX preload 的关系

含 Extension 的 `.tipa` 在 DopamineX 的视角下有两种部署形态：

| 部署形态 | 适合 | 流程 |
| --- | --- | --- |
| **通过 TrollStore 单独装 .tipa** | 独立 App + Extension，不依赖越狱 | 见本文档 + SIGNING_AND_DEPLOYMENT.md §4 |
| **作为 preload deb 装进 jbroot** | 越狱专属 App | 把整个 `MyApp.app` 放进 `preload-input/<N>-myapp/Applications/MyApp.app/`，跑 `build-preload-debs.sh` |

注意：

- **TrollStore 路径**：Extension 跟随主 App 自动注册到系统，无需越狱
- **preload deb 路径**：Extension 同样会被 dpkg 落盘，但 SpringBoard 必须重启
  （`killall SpringBoard` 或重启设备）才能发现新 extension；越狱激活态下
  jbctl startup 会自动跑 `uicache -a`，包含 extension 注册

两条路径对 entitlements 的处理**完全相同**——上面的 xcconfig + ldid 流程
都适用。唯一差别是产物：一个是 `.tipa`（zip 容器），一个是 `.deb`（dpkg
容器，里面是 `var/jb/Applications/MyApp.app/` 这种 jbroot 内路径布局）。

如要走 preload deb 路径，把 sign 完的 `MyApp.app` 这样组织：

```
preload-input/30-myapp/
├── control.yaml
└── Applications/
    └── MyApp.app/            ← sign-tipa.sh 后的产物，整个目录
        ├── MyApp
        ├── PlugIns/ScreenBroadcastExtension.appex/
        └── ...
```

跑 `./tools/build-preload-debs.sh`，产物 `preload-30-myapp.deb` 会被 dpkg
装到 `/var/jb/Applications/MyApp.app/`，越狱激活后 SpringBoard 出图标。

---

## 7. 一句话总结

**Capability Validation 是独立于 Code Signing 的 Xcode 校验阶段**。要绕过
"requires a provisioning profile with X feature"，**关键是让 Xcode build 期间
看不到 entitlements 文件**（用 xcconfig 设 `CODE_SIGN_ENTITLEMENTS=""`），build
完用 `ldid -SEnt.plist` 手动注入。TrollStore 装的 App 因 platform-app 通配，
几乎所有 entitlement（含 `com.apple.private.*`）都实际生效。

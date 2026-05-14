# livestream — TrollStore .tipa 构建模板（预填版）

派生自 [`../../docs/templates/`](../../docs/templates/) 通用模板，已为
`livestream` + `ScreenBroadcastExtension` 项目预先填好所有变量。

## 项目元数据（已固化进各文件）

| 项 | 值 | 来自 |
| --- | --- | --- |
| 主 App target / scheme | `livestream` | `xcodebuild -list` |
| Extension target | `ScreenBroadcastExtension` | `xcodebuild -list` |
| 主 App Bundle ID | `com.xxx.livestream` | `project.pbxproj` |
| Extension Bundle ID | `com.xxx.livestream.ScreenBroadcastExtension` | `project.pbxproj` |
| App Group ID | `group.com.xxx.livestream` | 现有 `*.entitlements` |
| Extension 类型 | Broadcast Upload Extension (推测) | ScreenBroadcastExtension 命名 |
| Entitlements 范围 | 仅 App Groups（未含 platform-application / broadcast-services） | 原项目就这样，保持不变 |

## 用法

> 前提：macOS + Xcode 已装；`brew install ldid`。

```sh
# 1. 把本目录全部内容拷到你的 livestream 项目根（与 livestream.xcodeproj 同级）
cp -r /path/to/DopamineX/examples/livestream/* /path/to/livestream/
cp -r /path/to/DopamineX/examples/livestream/.gitignore /path/to/livestream/ 2>/dev/null || true

cd /path/to/livestream

# 2. 如果 "xxx" 不是真实公司前缀，全文件一次性替换
sed -i '' 's/com\.xxx\.livestream/com.YOURCORP.livestream/g' \
    Entitlements/*.entitlements

# 3. 出包
chmod +x build.sh sign-tipa.sh
./build.sh                          # 或：make
```

完成后项目根目录会出现 `livestream.tipa`。

## 文件清单

| 文件 | 已预填的内容 |
| --- | --- |
| `build.sh` | `APP_NAME="livestream"` `SCHEME="livestream"` |
| `Makefile` | `APP_NAME = livestream` `SCHEME = livestream` |
| `sign-tipa.sh` | 通用脚本，自动识别 `*.appex` |
| `trollstore.xcconfig` | 通用，无项目特定值 |
| `Entitlements/livestream.entitlements` | 与你项目里的同名文件**逐字相同** |
| `Entitlements/ScreenBroadcastExtension.entitlements` | 同上 |

## 关键约定

### 1. 不擅自添加 entitlement

你原项目的两份 `.entitlements` 文件**只声明了 App Groups 一项**——本模板
**严格照搬**，没有自动加上 `platform-application` 或
`com.apple.developer.broadcast-services` 之类。

如果你后续发现 Broadcast 跑不起来缺权限，再单独加。

### 2. group ID 必须字面一致

主 App 和 Extension 的 `<string>group.com.xxx.livestream</string>` 必须**完全
字面一致**，连大小写都要——否则 `containerURLForSecurityApplicationGroupIdentifier:`
返回 nil。

如果你 sed 替换了，**两边都替换**。

### 3. 不修改 .xcodeproj

本流程完全靠 `-xcconfig trollstore.xcconfig` 覆盖 build settings，**不动**
你的 `livestream.xcodeproj/project.pbxproj`。同事用 Apple 证书出商店包不受
影响（不挂 xcconfig 即可）。

### 4. 出包后立即验证

```sh
# 验签名形态
codesign -dvv build/Build/Products/Release-iphoneos/livestream.app/livestream \
    2>&1 | grep -E "Signature|Authority"
# 期望 Signature=adhoc；绝对不能出现 Authority=Apple Development:

# 验主 App entitlements
ldid -e build/Build/Products/Release-iphoneos/livestream.app/livestream

# 验 Extension entitlements
ldid -e "build/Build/Products/Release-iphoneos/livestream.app/PlugIns/ScreenBroadcastExtension.appex/ScreenBroadcastExtension"
```

两个 entitlements 输出里 `<string>group.com.xxx.livestream</string>` 必须完
全相同。

## 部署到设备

把生成的 `livestream.tipa` 通过 AirDrop / iCloud Drive / HTTP 送到 iPhone，
Files App 找到它 → 长按 → Share → TrollStore → Install。

完成后桌面出现 `livestream` 图标，点开即用——**永久驻留**（iOS 版本不变前
提下）。

## 排错

见 [../../docs/EXTENSIONS_AND_ENTITLEMENTS.md §5](../../docs/EXTENSIONS_AND_ENTITLEMENTS.md)
排错清单。最常见的几个：

| 报错 | 修复 |
| --- | --- |
| `requires a provisioning profile with the App Groups feature` | 确认 `xcodebuild` 命令带了 `-xcconfig trollstore.xcconfig` |
| `Authority=Apple Development: ...` 出现在 codesign 输出 | xcconfig 没生效——`xcodebuild -showBuildSettings -xcconfig trollstore.xcconfig` 检查 |
| Broadcast extension 选不到 / 启动崩溃 | 通常是 group ID 不一致——`ldid -e` 对比两边 |

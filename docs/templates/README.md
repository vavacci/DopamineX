# TrollStore App 项目模板

这套模板对应 [../EXTENSIONS_AND_ENTITLEMENTS.md](../EXTENSIONS_AND_ENTITLEMENTS.md)
讲的 ad-hoc + TrollStore 构建流程，可直接拷到你的 iOS App 项目根目录使用。

## 文件清单

| 文件 | 作用 |
| --- | --- |
| `build.sh` | 一键脚本：xcodebuild → ldid → zip。修改头部 APP_NAME / SCHEME 后 `./build.sh` 出 .tipa |
| `Makefile` | 与 build.sh 等价的 make 版本（`make tipa` / `make clean`） |
| `sign-tipa.sh` | 给 Makefile 用的签名 helper；build.sh 自带签名逻辑无需用它 |
| `trollstore.xcconfig` | xcodebuild 的 build settings 覆盖（关闭签名 + 跳过 entitlements 校验） |
| `Entitlements/MyApp.entitlements` | 主 App entitlements 模板（含 App Groups 示例） |
| `Entitlements/ScreenBroadcastExtension.entitlements` | Extension entitlements 模板（与主 App 共享 group） |

## 用法

```sh
# 1. 拷贝到你的 iOS App 项目根（与 .xcodeproj 同级）
cp -r docs/templates/* /path/to/MyApp/

# 2. 改 build.sh / Makefile 顶部的 APP_NAME / SCHEME
# 3. 改 Entitlements/*.entitlements 内容（写真实的 capabilities）
# 4. 把 Entitlements/MyApp.entitlements 改名为 Entitlements/<你的App名>.entitlements
# 5. 同理重命名 ScreenBroadcastExtension.entitlements 为 <你的Extension名>.entitlements

# 6. 出包
brew install ldid              # 一次性依赖
cd /path/to/MyApp
chmod +x build.sh sign-tipa.sh
./build.sh                     # 或：make
```

完成后项目根目录会出现 `MyApp.tipa`，AirDrop 给设备 → 长按 → Share → TrollStore。

## 用 build.sh 还是 Makefile？

二选一，功能完全等价：

- 习惯命令行 / Bash 脚本 → `build.sh`
- 习惯 `make` / 要接 GitHub Actions → `Makefile` + `sign-tipa.sh`

## 排错

见 [../EXTENSIONS_AND_ENTITLEMENTS.md §5 验证脚本与排错清单](../EXTENSIONS_AND_ENTITLEMENTS.md)。

最常用的一条：

```sh
xcodebuild -scheme MyApp -sdk iphoneos -xcconfig trollstore.xcconfig \
    -showBuildSettings | grep -iE "CODE_SIGN|ENTITLEMENTS"
```

期望：
```
CODE_SIGN_ENTITLEMENTS = 
CODE_SIGN_IDENTITY = 
CODE_SIGNING_ALLOWED = NO
CODE_SIGNING_REQUIRED = NO
ENTITLEMENTS_REQUIRED = NO
```

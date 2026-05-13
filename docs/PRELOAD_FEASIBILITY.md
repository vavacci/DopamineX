# Dopamine (roothide) 预加载自定义 dylib / plist / 二进制 可行性研究

> 目标：在 Dopamine 2 (roothide) 越狱流程中，把开发者自己的 dylib、launch daemon
> plist、CLI/服务端二进制直接打包进 .tipa，越狱完成后无需用户再单独安装
> 即可生效（开机注入、自动启动、可被用户/脚本调用）。

本文档基于 `/home/coder/workspace/mx/dopamine/Dopamine2-roothide` 源码树的静态阅读
得出，所有引用位置都在仓库内可验证。

---

## 1. 结论速览

**完全可行**。Dopamine roothide 的"基础 bin"`basebin.tar`、其 trustcache 子系统、
launchd 钩子、systemhook/TweakLoader 注入链都给预加载留了清晰的切入点。常见三类
诉求都能解决：

| 诉求 | 推荐切入点 | 是否需要改源码 |
| --- | --- | --- |
| 自启动 daemon（plist + 二进制） | `BaseBin/_external/basebin/LaunchDaemons/*.plist` + 二进制丢到 `BaseBin/_external/basebin/` | 否（仅加文件） |
| 系统级注入 dylib（注入到所有进程/SpringBoard/特定 App） | 标准 ellekit 风格 `MobileSubstrate/DynamicLibraries/x.dylib + x.plist`，用 `.deb` 打包丢 `Application/Dopamine/Resources/` | 改 `DOBootstrapper.m` 一行（加到 `preinstalledDebs`） |
| CLI 工具，越狱后用户可调用 | 同上 deb；或丢 `BaseBin/_external/basebin/` 顺带托管 | 同上 |
| 一次性"安装时跑一遍"的脚本/动作 | 在 `DOBootstrapper.finalizeBootstrap` 末尾插入步骤 | 改源码 |

整体只新增/替换文件就能实现预加载；只在需要"自动调用 dpkg 装 deb"或"安装时执行
脚本"时才需要修改 Objective‑C 源码（改动很小）。

---

## 2. 关键链路（必须先理解的事实）

### 2.1 `basebin.tar` 是越狱后写入 `<jbroot>/basebin/` 的核心包

`BaseBin/Makefile`:

- `all: basebin.tar`
- `.build` 目录是 `cp -r _external/basebin/*` 后再叠加各子工程产物（libchoma、systemhook、launchdhook、jbctl、idownloadd、jailbreakd …）
- `basebin.tc: subprojects` → `trustcache create .build/basebin.tc .build`
  会把 `.build` 下**所有文件**的 cdhash 写入一个 trustcache。
- `basebin.tar` 把整个 `.build/` 重命名为 `basebin/` 后打包。

也就是说：**只要把文件放进 `BaseBin/_external/basebin/` 任意子目录或者让某个子
工程把额外产物 `cp` 进 `.build/`，它就会自动出现在最终的 `<jbroot>/basebin/` 中，
并且 cdhash 自动进 `basebin.tc`。**

### 2.2 `basebin.tc` 在 Dopamine 2.x（roothide）里被替换成"运行时 randomize 后再加载"

`BaseBin/libjailbreak/src/roothider/common.m:550 randomizeAndLoadBasebinTrustcache()`：
> 递归枚举 `<jbroot>/basebin/`，对每个文件 `ensure_randomized_cdhash()`，再
> `trustcache_file_upload_with_uuid(...)` 上传到内核动态 trustcache。

调用方：
- App 端 `DOJailbreaker.loadBasebinTrustcache`（首次越狱时）
- `BaseBin/launchdhook/src/update.m:45`（jbupdate 流程）

结论：**只要文件出现在 `<jbroot>/basebin/` 下，越狱激活时它的 cdhash 一定会被
入信任缓存，无需开发者手工 sign / 维护 cdhash 列表**。文件本身仍需要有可解析的
代码签名（`ldid -S` ad‑hoc 即可），因为 `ensure_randomized_cdhash` 会读取并改写
LC_CODE_SIGNATURE。

`Application/Dopamine/Jailbreak/DOBootstrapper.m:499` 在装完 basebin.tar 之后立刻
`removeItemAtPath:.../basebin.tc` —— `.tc` 文件被弃用，运行时重算 cdhash 才是事实。

### 2.3 launchd 在每次 userspace boot 时都会加载 `basebin/LaunchDaemons/*.plist`

`BaseBin/launchdhook/src/daemon_hook.m:38-44`：
```objc
if (!strcmp(key, "LaunchDaemons")) {
    if (xpc_get_type(origXvalue) == XPC_TYPE_DICTIONARY) {
        for (NSString *daemonPlistName in [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:JBROOT_PATH(@"/basebin/LaunchDaemons") error:nil]) {
            if ([daemonPlistName.pathExtension isEqualToString:@"plist"]) {
                xpc_dictionary_add_launch_daemon_plist_at_path(origXvalue, ...);
            }
        }
    }
}
```

launchdhook 通过 `MSHookFunction(xpc_dictionary_get_value)` 在 launchd 解析自身
plist 数据库时**注入** `<jbroot>/basebin/LaunchDaemons/*.plist`。比 `/Library/LaunchDaemons`
更早，并且 launchd 进程内被 systemhook 替代后路径不依赖 / 的可写性。

另外 `Application/Dopamine/Jailbreak/DOBootstrapper.m:316 patchBasebinDaemonPlists`
会扫描并把所有 `ProgramArguments` 里的 `@JBROOT@` 占位符替换成真实 jbroot —
**这意味着 plist 在源码中可以用 `@JBROOT@` 直接表达，不需要在打包时知道随机化的 jbroot**。

### 2.4 `/Library/LaunchDaemons`（jbroot 内）由 `jbctl startup` 加载

`BaseBin/jbctl/src/internal.m:191`：
```c
exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "bootstrap", "system", "/Library/LaunchDaemons", NULL);
```

这是 Procursus 修改过的 jbroot‑aware launchctl；任何放在
`<jbroot>/Library/LaunchDaemons/` 的 plist（通常由 deb 安装产生）会在越狱启动末段
被加载。要预先放置，最稳妥的办法是把它打到一个自带的 .deb 里（见 §3.3）。

### 2.5 用户态进程注入由 `systemhook.dylib` + `TweakLoader.dylib`(ellekit) 完成

`BaseBin/systemhook/src/main.c:432-441`：
```c
const char *tweakLoaderPath = JBROOT_PATH("/usr/lib/TweakLoader.dylib");
if (access(tweakLoaderPath, F_OK) == 0) {
    void *tweakLoaderHandle = dlopen(tweakLoaderPath, RTLD_NOW);
    ...
}
```

`TweakLoader.dylib` 来自 `ellekit.deb`（已在 `preinstalledDebs` 里），它会扫描
`<jbroot>/Library/MobileSubstrate/DynamicLibraries/*.plist`，按 Filter 字段
（Bundles/Executables）匹配后 dlopen 同名 `.dylib`。
**这就是开发者自己的注入式 dylib 应该走的标准路径。** 任何符合该规范的 dylib +
plist 都能"开机就生效"。

### 2.6 资源进入 `.tipa` 的入口

`Application/Makefile:26`：
```make
cp -a Dopamine/Resources/*.deb build/Build/Products/Debug-iphoneos/Dopamine.app/
```

也就是说 **`Application/Dopamine/Resources/*.deb` 会被原样拷入 `Dopamine.app/`，
最终落到 `<mainBundle>.bundlePath` 下**。`basebin.tar`、`bootstrap_1800.tar.zst`、
`bootstrap_1900.tar.zst` 同样靠 mainBundle 寻址。

`DOBootstrapper.m:1287` 已有的 `preinstalledDebs` 数组就是"按依赖顺序自动 dpkg -i
安装"列表，把自定义 deb 加进去就完成 90% 工作。

---

## 3. 三套可选改造方案

### 3.1 方案 A：把文件塞进 `basebin.tar`（适合体积小、版本随 Dopamine 走的资源）

**步骤：**

1. 在 `BaseBin/_external/basebin/` 下放置文件。建议按用途建子目录：
   - `BaseBin/_external/basebin/preload/bin/<my-tool>`（CLI 二进制）
   - `BaseBin/_external/basebin/preload/lib/<my.dylib>`（任意 dylib）
   - `BaseBin/_external/basebin/LaunchDaemons/com.acme.foo.plist`（启动 daemon）
2. 所有可执行 Mach‑O 在打包前先 ad‑hoc 签名一次：
   ```sh
   ldid -S BaseBin/_external/basebin/preload/bin/my-tool
   ```
   （后续 `randomizeAndLoadBasebinTrustcache` 会再改 cdhash，但 LC_CODE_SIGNATURE
   段必须存在，否则 ensure_randomized_cdhash 失败。）
3. plist 路径里凡是要写 jbroot 的，使用 `@JBROOT@` 字面量，例如：
   ```xml
   <key>ProgramArguments</key>
   <array>
       <string>@JBROOT@/basebin/preload/bin/my-tool</string>
       <string>--config</string>
       <string>@JBROOT@/etc/my-tool.conf</string>
   </array>
   ```
   `patchBasebinDaemonPlists` 会在 extract 后立即把 `@JBROOT@` 替换成真实 jbroot。
4. `make -C BaseBin basebin.tar` 重新构建；`make -C Application` 重新出 .tipa。

**优点：** 文件 100% 自动 trustcache；零源码改动；userspace reboot 后立即生效；
`make update-basebin` 支持热更新（不用重装 App）。

**缺点：** 体积全打进 basebin.tar，每次越狱启动都参与 trustcache 计算；不便管理
版本/卸载；plist 注入逻辑只看 `basebin/LaunchDaemons/`，深层子目录里的 plist 不会
被 launchdhook 扫到（详见 §4.3）。

### 3.2 方案 B：把文件塞进 bootstrap 或 `Library/LaunchDaemons`（适合"普通用户态文件"）

bootstrap_1800/1900 是 Procursus 上游产物，**不建议直接改**（每次升级要重打）。

正确做法是把 LaunchDaemon 装到 `<jbroot>/Library/LaunchDaemons/`：

- 写一个 .deb，其中 `usr/local/bin/foo` 是二进制、`Library/LaunchDaemons/com.acme.foo.plist`
  是 plist；
- 用 `dpkg-deb -b` 打包后丢 `Application/Dopamine/Resources/foo.deb`；
- 走方案 C。

注意：plist 中的路径如果写绝对路径要写**相对 jbroot 的**形式，例如
`/usr/local/bin/foo`，jbroot‑aware launchctl 会自动加 jbroot 前缀。**不要**在
deb 里硬编 `/var/jb/...` 或 `/var/containers/.../.jbroot-XXXX/...`，这会因为
roothide 的随机化路径而失效。

### 3.3 方案 C：以 .deb 形式打包，注册到 `preinstalledDebs`（推荐做法）

这是最干净的方式。Dopamine 已经用同一个机制预装 ellekit / curl / openssh：

1. **离线构建你的 .deb**。最简单的目录结构：
   ```
   mypkg/
     DEBIAN/
       control                # 必须的 dpkg control 文件，Architecture: iphoneos-arm
       postinst               # 可选：装完跑一遍的 sh 脚本
     usr/local/bin/foo        # 你的二进制（ldid -S 后再打包）
     Library/LaunchDaemons/com.acme.foo.plist
     Library/MobileSubstrate/DynamicLibraries/myhook.dylib
     Library/MobileSubstrate/DynamicLibraries/myhook.plist
   ```
   然后 `dpkg-deb -b mypkg mypkg.deb`。
2. 放到 `Application/Dopamine/Resources/mypkg.deb` —— Application Makefile 的
   `cp -a Dopamine/Resources/*.deb` 通配会自动收进 .tipa。
3. 修改 `Application/Dopamine/Jailbreak/DOBootstrapper.m:1287` 的 `preinstalledDebs`：
   ```objc
   NSArray<NSString *> *preinstalledDebs = @[
       @"ellekit.deb",
       ...
       @"openssh.deb",
       @"mypkg.deb",           // ← 新增（按依赖顺序）
   ];
   ```
4. 如果 deb 的依赖在 Procursus 仓库已经满足、并且 Dopamine 已经先装好 ellekit，
   直接 `dpkg -i` 不会缺依赖；否则把依赖 deb 一并打进 Resources 并排在前面。

**优点：**

- 路径正确性 100% 交给 dpkg（自动处理 jbroot prefix、postinst、文件权限）；
- 所有可执行文件经 `dpkg` 落盘后，会被 systemhook 的 `posix_spawn` 钩子触发的
  `systemwide_trust_file_by_path` 自动 trustcache（见 `launchdhook/src/spawn_hook.c:20`
  和 `jbserver/jbdomain_systemwide.c:239`），不需要手工调 `jbctl trustcache add`；
- 后续可以通过 Sileo/Zebra 升级或卸载；
- 注入式 dylib 直接落到 ellekit 的扫描目录 `Library/MobileSubstrate/DynamicLibraries/`
  即可全局生效。

**缺点：**

- 需要 dpkg 打包脚本（一次性投入）；
- 首次越狱必须完整跑完 `finalizeBootstrap` 才会装上，普通启动不会重装（这正好
  也是优点）。

### 3.4 综合建议

90% 的"预加载"需求用 **方案 C** 解决；只有以下情况偏向 **方案 A**：

- 体积小且与 jb 内部组件紧耦合的工具（例如自定义的 jbctl 扩展、自定义 systemhook
  的旁挂 dylib）；
- 需要在 `/Library/LaunchDaemons` 还没 bootstrap 之前就跑起来（即依赖 launchdhook
  的早期注入路径）；
- 想跟 basebin 一起原子化更新（`make update-basebin` 一条命令）。

---

## 4. 已识别的坑与边界条件

### 4.1 代码签名

- 任何要被 trustcache 的 Mach‑O 必须**有**代码签名段（哪怕是 ldid -S 的 ad‑hoc）。
  ChOma/`ensure_randomized_cdhash` 解析失败会让 trustcache 静默漏掉该文件，进程
  spawn 时 AMFI 拒绝。
- entitlements：root daemon 需要的话在 plist 之外的 binary 自身 `ldid -SEnt.plist`
  打包；roothide 的随机化 cdhash 也会保留 entitlements blob。
- 用户态注入的 .dylib 不需要 entitlements，但需要 ad‑hoc 签名。

### 4.2 必须 userspace reboot 才生效

- 方案 A：写入 basebin/LaunchDaemons 后，旧 launchd 不会重新读取它；
  `jbctl reboot_userspace` 或 `make update-basebin`（内部触发 RB2_USERREBOOT）后生效。
- 方案 B/C：装完 deb 后 jbctl startup 还要再跑 `launchctl bootstrap system`；首次
  越狱的 `finalizeBootstrap` 流程末段已经会走到，所以**首次越狱即生效**；后续
  更新则需要重启 daemon 或 userspace reboot。

### 4.3 `basebin/LaunchDaemons` 仅扫描该目录顶层

`daemon_hook.m:40` 用的是 `contentsOfDirectoryAtPath:`（非递归），所以你的 plist
必须直接放在 `BaseBin/_external/basebin/LaunchDaemons/` 顶层，不能再嵌目录。

### 4.4 dpkg 依赖

`preinstalledDebs` 列表是按顺序 `dpkg -i` 的，**不会自动解算依赖图**。如果你的
deb 依赖 ellekit/libroot/libcurl4 等，要么排在它们之后，要么把缺的依赖 deb 一并
丢进 Resources。

### 4.5 文件路径不要硬编 jbroot

roothide 把 jbroot 放在 `/var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX/`
并且 hash 是**每次安装重新随机**的，参考 `DOBootstrapper.m:962-1010`。一切跨进程
路径都要：

- 在 launchd plist 中用 `@JBROOT@`；
- 在 C/Objective‑C 中用 `JBROOT_PATH("/...")` / `jbrootPrefix(@"/...")`；
- shell 脚本里用 `$(jbroot)`（jbctl/launchctl 注入的环境变量）或 `/var/jb/...`（兼容符号链接）。

### 4.6 黑名单（blacklist）

`launchdhook/src/roothider.m:378 isBlacklistedPath()` 会阻止某些 App 注入。若你的
注入 dylib 想强制注入特定黑名单 App，需要改 `roothidehooks` 的 blacklist 实现；
**默认情况下系统 App、SpringBoard 不在黑名单里**，普通用户 App 也都会被注入，
注意不要写出全局崩溃的 hook。

### 4.7 沙盒与权限

- `basebin/LaunchDaemons/*.plist` 默认以 plist 内 `UserName` 指定的身份运行。
  写 `<key>UserName</key><string>root</string>` 才以 root 跑。
- 走 `Library/LaunchDaemons` 装的 daemon 进程容器化策略由 launchctl/sandbox 决定，
  必要时在 plist 中显式 `EnableTransactions/EnvironmentVariables/MachServices`。

### 4.8 多次 jb / 升级

- 用户做 jbupdate 时，`update.m` 会把新 basebin 解压到临时目录、再
  `randomizeAndLoadBasebinTrustcache(tmpBasebinPath)` 上传新 cdhash —— 走的还是
  `JBROOT/basebin/` 这条线，所以方案 A 文件不会丢。
- 用户卸载 Dopamine（`deleteBootstrap`）会清掉整个 `.jbroot-XXXX` 目录，所以预加载
  的文件也会一起删；这是预期行为，不是 bug。

---

## 5. 改造示例（参考 patch）

下面只展示**方案 A + 方案 C 各一个最小可行 patch**，可直接套用。

### 5.1 方案 A：新增一个开机 daemon `helloworld`

```
BaseBin/_external/basebin/
  preload/
    hello                                 # ad-hoc 签名好的 Mach-O
  LaunchDaemons/
    com.acme.hello.plist
```

`com.acme.hello.plist`：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.acme.hello</string>
    <key>ProgramArguments</key>
    <array>
        <string>@JBROOT@/basebin/preload/hello</string>
    </array>
    <key>UserName</key>
    <string>root</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DISABLE_TWEAKS</key>
        <string>1</string>
    </dict>
</dict>
</plist>
```

构建：`make -C BaseBin basebin.tar && make -C Application`。  
**零源码改动。**

### 5.2 方案 C：预装 `mypkg.deb` 并加全局注入 dylib

```diff
--- a/Application/Dopamine/Jailbreak/DOBootstrapper.m
+++ b/Application/Dopamine/Jailbreak/DOBootstrapper.m
@@ -1296,6 +1296,7 @@ NSArray<NSString *> *preinstalledDebs = @[
             @"openssh-client.deb",
             @"openssh-server.deb",
             @"openssh.deb",
+            @"mypkg.deb",
         ];
```

`mypkg.deb` 的 DEBIAN/control：
```
Package: com.acme.mypkg
Name: ACME preload bundle
Version: 1.0.0
Architecture: iphoneos-arm
Description: Custom dylibs and binaries auto-loaded after jailbreak.
Maintainer: you
Depends: ellekit (>= 1.0.0)
Section: Tweaks
```

文件清单（dpkg 会在 jbroot 下展开）：
```
Library/MobileSubstrate/DynamicLibraries/com.acme.hook.dylib
Library/MobileSubstrate/DynamicLibraries/com.acme.hook.plist
Library/LaunchDaemons/com.acme.helloworld.plist
usr/local/bin/helloworld
```

`com.acme.hook.plist` (ellekit Filter)：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Filter</key>
    <dict>
        <key>Bundles</key>
        <array>
            <string>com.apple.springboard</string>
        </array>
    </dict>
</dict>
</plist>
```

打包：`dpkg-deb -Zzstd -b mypkg mypkg.deb`，再放入
`Application/Dopamine/Resources/mypkg.deb`，重新 `make` 出 .tipa 即可。

### 5.3 进阶：一次性"安装后跑一遍"的 hook 点

如果你想在 finalizeBootstrap 末尾做点别的（比如调用 jbctl trustcache add、复制
配置、初始化数据库），最干净的插入点是 `DOBootstrapper.m:1314` 那段
`if (...)/else {...}` 之后、`shouldInstallLibkrw` 之前：

```objc
// 你的一次性初始化
{
    NSString *resourceDir = [NSBundle mainBundle].bundlePath;
    NSString *postScript  = [resourceDir stringByAppendingPathComponent:@"preload_postinstall.sh"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:postScript]) {
        int r = exec_cmd_trusted(JBROOT_PATH("/bin/sh"),
                                 postScript.fileSystemRepresentation, NULL);
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain
                                       code:BootstrapErrorCodeFailedFinalising
                                   userInfo:@{NSLocalizedDescriptionKey :
                                       [NSString stringWithFormat:@"preload postinstall returned %d", r]}];
        }
    }
}
```

`preload_postinstall.sh` 放进 `Application/Dopamine/Resources/`，然后修 Makefile
的 `cp -a Dopamine/Resources/*.deb` 那行多加一条 `cp -a Dopamine/Resources/*.sh`，
或者直接通过 deb 的 postinst 跑（更推荐，因为已经在 dpkg 环境里）。

---

## 6. 验证步骤（建议在改完后跑一遍）

1. **本地构建：** `make -C BaseBin clean && make -C BaseBin basebin.tar && make -C Application`，
   确保 .tipa 生成无错。
2. **校验 basebin.tar 内容：** `tar -tf BaseBin/basebin.tar | grep -E "preload|LaunchDaemons"`。
3. **校验 .tipa 资源：** 解 .tipa → `Payload/Dopamine.app/`，确认你新增的 `.deb`、
   `.sh`、basebin.tar 内文件都在。
4. **设备上安装并越狱**，越狱成功后在设备上：
   - `launchctl list | grep com.acme` → 你的 daemon 应该在；
   - `ls -lZ /var/jb/basebin/preload/` → 你的二进制在；
   - `jbctl trustcache info | head` → 看到 cdhash 数量 > 默认值；
   - 用 `dlopen` 测试 dylib 注入；或在 SpringBoard 中观察 hook 效果；
   - `tail /var/log/system.log` 看自启动 daemon 是否报错。
5. **`make update-basebin DEVICE=mobile@<ip>` 热更新**，验证 jb update 流程不破坏
   你的预加载。

---

## 7. 风险与限制

- **AMFI 拒绝：** 任何漏签的 Mach‑O 都会被 spawn 阶段拒绝。务必 `ldid -S` 或
  ChOma 签名，并尽量在 CI 里加 `codesign --display --verbose=4` 校验。
- **iOS 版本差异：** Dopamine 当前支持 15.0–16.6.1（看 BaseBin/`__arm64e__` 分支
  和 systemhook 的 iOS16 判断）。如果你的预加载需要更新的 API，需自己加版本判断。
- **越狱二进制冲突：** 不要复用 Dopamine 已有 binary 名（jbctl、idownloadd、
  jailbreakd、launchdhook、systemhook 等），打包时 trustcache create 会重名冲突
  或者 launchd 拒绝重复 Label。
- **黑名单 App：** 注入到银行/Apple 自家某些 App 默认被 roothide 黑掉，需要单独
  改 `roothidehooks` 才能突破，且**带来检测/封号风险，自行权衡**。
- **userspace reboot 必需性：** 加 basebin/LaunchDaemons 后只有走 userspace reboot
  才能生效；首次越狱本就会 reboot，更新 daemon 则要 `jbctl reboot_userspace` 或
  `launchctl kickstart`。
- **kernel panic 风险：** 你的 daemon 如果 ring 在 jetsamhook/spawnhook 之外触发
  奇怪的 syscall（例如未注册 mach service 又调用 host_set_*），可能导致 launchd 卡
  住，从而被 watchdoghook 触发 userspace panic。建议第一版只跑最简单的 RPC 服务。

---

## 8. 参考源码定位

- `BaseBin/Makefile`：basebin.tar 构建总入口
- `BaseBin/_external/basebin/`：basebin 静态资源（plist、fallback framework、.version）
- `BaseBin/libjailbreak/src/roothider/common.m:550`：`randomizeAndLoadBasebinTrustcache`
- `BaseBin/launchdhook/src/daemon_hook.m`：launchd plist 注入
- `BaseBin/launchdhook/src/update.m`：jbupdate 时重装 basebin 并刷新 trustcache
- `BaseBin/launchdhook/src/spawn_hook.c` + `jbserver/jbdomain_systemwide.c:239
  systemwide_trust_file_by_path`：spawn 时按需 trustcache 文件
- `BaseBin/systemhook/src/main.c:432`：TweakLoader 加载链
- `BaseBin/systemhook/src/common.c:117` 起：DYLD_INSERT_LIBRARIES 注入逻辑
- `BaseBin/jbctl/src/internal.m:191`：`launchctl bootstrap system /Library/LaunchDaemons`
- `Application/Makefile:26`：`Resources/*.deb` → .tipa
- `Application/Dopamine/Jailbreak/DOBootstrapper.m:316 patchBasebinDaemonPlists`：
  `@JBROOT@` 占位符替换
- `Application/Dopamine/Jailbreak/DOBootstrapper.m:1287 preinstalledDebs`：预装 deb 列表
- `Application/Dopamine/Jailbreak/DOBootstrapper.m:1269 finalizeBootstrap`：
  首次越狱后期的 hook 点
- `Application/Dopamine/Jailbreak/DOJailbreaker.m:330 loadBasebinTrustcache`：
  首次越狱触发的 cdhash 上载

---

## 9. 一句话总结

Dopamine roothide 的预加载能力**已经全部就绪**，只是没有官方暴露的"用户自定义
插槽"。`BaseBin/_external/basebin/` 目录 + `Application/Dopamine/Resources/*.deb`
+ `preinstalledDebs` 列表三处即是天然的扩展点，可在不动核心逻辑的前提下让任意
开发者自带的 dylib / plist / 二进制随 .tipa 一起发布、越狱后自动生效。

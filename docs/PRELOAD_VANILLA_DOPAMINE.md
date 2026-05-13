# 普通 Dopamine (opa334 上游) 预加载可行性

> 对照文档：[PRELOAD_FEASIBILITY.md](./PRELOAD_FEASIBILITY.md) 已经完整论证了
> roothide 分支的方案。本文只列出上游 opa334/Dopamine（rootless / 非随机化路径
> 版本）的差异，结论先给：**也完全可行，且大部分情况比 roothide 更直接**。

调研来源：`github.com/opa334/Dopamine`（master 分支）线上读源码，对照本仓库内的
roothide 分支理解差异。

---

## 1. 结论速览

| 维度 | roothide 分支 | 上游 Dopamine | 对预加载的影响 |
| --- | --- | --- | --- |
| jbroot 路径 | `/var/containers/Bundle/Application/.jbroot-<rand>/`，每次安装随机 | `/var/jb`（固定符号链接） | **上游更简单**：plist/脚本可直接硬编 `/var/jb/...` |
| basebin trustcache | 运行时 `randomizeAndLoadBasebinTrustcache` 递归扫描目录、重算 cdhash | 编译期 `trustcache create .build/basebin.tc .build` 生成静态 `.tc`，运行时一次性 upload | **结果一致**：两者都对整个 `.build/` 递归收 cdhash，往 `_external/basebin/` 加文件都会自动入信任缓存 |
| launchd 自动加载目录 | 仅 `<jbroot>/basebin/LaunchDaemons/`（`/Library/LaunchDaemons` 由 jbctl startup 后期 launchctl bootstrap 加载） | `<jbroot>/basebin/LaunchDaemons/` **和** `<jbroot>/Library/LaunchDaemons/` 都被 launchdhook 直接扫描 | **上游更宽松**：两个目录任意放都行，无需依赖 jbctl startup |
| 预装 deb 列表 | `DOBootstrapper.m` 中 `preinstalledDebs` 数组（roothide 自加） | 无；仅 `installPackageManagers`（按 UI 偏好装 Sileo/Zebra）+ `gBundledPackages` 三件套（libroot/libkrw/basebin-link 按版本升级） | **上游缺少现成数组**，需要手工加几行代码（见下文 §3） |
| TweakLoader / 注入链 | systemhook → dlopen `<jbroot>/usr/lib/TweakLoader.dylib`（ellekit） | 完全一致 | 无差异 |
| `@JBROOT@` 占位符替换 | `patchBasebinDaemonPlists` | 同名方法完全一致 | 上游也用 `@JBROOT@`，行为一致 |
| Bootstrap 来源 | bootstrap_*.tar.zst 直接随源码仓库 | 通过 `download_bootstraps.sh` 在 build 时下载 | 与预加载无关 |

**核心结论**：上游 Dopamine 的扩展点更"宽"——
- launchd 多加一个目录 `<jbroot>/Library/LaunchDaemons`；
- jbroot 路径固定为 `/var/jb`，能直接硬编；
- basebin.tc 是静态文件，更可预测。

唯一"少"的就是 `preinstalledDebs` 这一条预安装数组——但补上只需要新增 10 行
Objective‑C 代码。

---

## 2. 三种方案在上游 Dopamine 上的实现差异

### 2.1 方案 A（塞 basebin.tar）：**完全一样，零修改**

源码中 `BaseBin/Makefile` 的关键两条：

```make
basebin.tc: subprojects
	trustcache create .build/basebin.tc .build
	cp .build/basebin.tc basebin.tc

basebin.tar: basebin.tc dyldhook
	./tar --transform "s/^.build/basebin/" -cvf "basebin.tar" ".build" ...
```

`trustcache create` 工具递归扫描 `.build` 目录把所有 Mach‑O 的 cdhash 写进
`basebin.tc`。在 App 启动 `loadBasebinTrustcache` 时直接读这个 `.tc` 上传内核。

也就是说 —— **上游同样可以把你的二进制 / dylib / plist 丢到
`BaseBin/_external/basebin/`，它们会被自动 cp 进 `.build/` → 进 `basebin.tc`
→ 进 `basebin.tar` → 解压到 `<jbroot>/basebin/` → trustcache 由内核接受**。

唯一注意点：**因为 basebin.tc 是静态生成的，Mach‑O 必须在 trustcache create 之前
已经签好 ad‑hoc**（roothide 是运行时再算所以容忍度高些）。流程：

```sh
ldid -S BaseBin/_external/basebin/preload/hello   # 先签
make -C BaseBin clean basebin.tar                  # 再打
```

### 2.2 方案 B（直接 `<jbroot>/Library/LaunchDaemons`）：**比 roothide 更直接**

上游 launchdhook 的 `daemon_hook.m` 同时扫描 **两个** 目录：

```objc
// 上游版本（未被注释掉）：
for (NSString *daemonPlistName in [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:JBROOT_PATH(@"/basebin/LaunchDaemons") error:nil]) { ... }
for (NSString *daemonPlistName in [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:JBROOT_PATH(@"/Library/LaunchDaemons") error:nil]) { ... }
```

以及在 `"Paths"` 键上 append 这两个目录给 launchd 后续扫描。

所以你的 daemon plist 可以直接出现在 `/var/jb/Library/LaunchDaemons/` 而不必
绕 deb，仍然每次 userspace boot 自动加载。

> 在 roothide 上 `<jbroot>/Library/LaunchDaemons` 的扫描被注释掉，只靠 jbctl
> startup 走 `launchctl bootstrap system /Library/LaunchDaemons`；功能上等价，但
> "时序更晚"，且**不是**由 launchdhook 直接 inject。

### 2.3 方案 C（预装 deb）：**需要小幅源码修改**

上游 `DOBootstrapper.m` 没有现成的 `preinstalledDebs` 数组，但 `installPackage:`
方法是公开的：

```objc
- (int)installPackage:(NSString *)packagePath {
    if (getuid() == 0) {
        return exec_cmd_trusted(JBROOT_PATH("/usr/bin/dpkg"), "-i",
                                packagePath.fileSystemRepresentation, NULL);
    } else {
        exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", "install_pkg",
                 packagePath.fileSystemRepresentation, NULL);
        return 0;
    }
}
```

在 `finalizeBootstrap` 的 `prep_bootstrap.sh` 首次执行块里、`installPackageManagers`
之后插入：

```objc
NSArray<NSString *> *preinstalledDebs = @[
    @"ellekit.deb",       // 你自带的依赖
    @"mypkg.deb",         // 你的预加载包
];
for (NSString *debName in preinstalledDebs) {
    NSString *debPath = [[NSBundle mainBundle].bundlePath
                          stringByAppendingPathComponent:debName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:debPath]) continue;
    int pr = [self installPackage:debPath];
    if (pr != 0) {
        return [NSError errorWithDomain:bootstrapErrorDomain
                                   code:BootstrapErrorCodeFailedFinalising
                               userInfo:@{NSLocalizedDescriptionKey :
                                          [NSString stringWithFormat:
                                           @"Failed to install %@: %d", debName, pr]}];
    }
}
```

deb 文件丢到 `Application/Dopamine/Resources/*.deb`，**前提是 Application/Makefile
也加一条 `cp -a Dopamine/Resources/*.deb build/.../Dopamine.app/`**——上游
Makefile 默认**只**拷 `sileo.deb` 和 `zebra.deb`（通过 xcodebuild 的 Resources），
不像 roothide 用通配 `*.deb`。最简单的做法：

1. **如果 Xcode project 里已经把 Resources 目录加进 Copy Bundle Resources phase**：
   你的 .deb 会自动入包；但要在 Xcode 工程内拖动添加 reference。
2. **或在 Application/Makefile 里加一行**：
   ```make
   build/Build/Products/Release-iphoneos/Dopamine.app: ...
       ...
       cp -a Dopamine/Resources/*.deb build/Build/Products/Release-iphoneos/Dopamine.app/
   ```

（这两条任选其一即可让 deb 跟随 .tipa 走。）

---

## 3. 改造 patch（针对上游 Dopamine 的最小改动）

### 3.1 只想加自启动 daemon —— **零源码改动**

把 plist + 二进制丢进 `BaseBin/_external/basebin/`，重新 `make`。

```
BaseBin/_external/basebin/
    preload/hello                              <- ldid -S 后的 Mach-O
    LaunchDaemons/com.acme.hello.plist         <- 用 @JBROOT@
```

### 3.2 想全局注入 dylib（到 SpringBoard / 普通 App）—— **零源码改动**

最快的路径：把 `dylib + plist` 也放进 `BaseBin/_external/basebin/`，再写一个**只**
做 dlopen 的小 daemon 或者干脆把 dylib 路径加到某个 plist 的 ProgramArguments 上
让 systemhook spawn 时通过 DYLD_INSERT_LIBRARIES 注入。

更正式的路径：把 dylib + plist 丢到 `<jbroot>/Library/MobileSubstrate/DynamicLibraries/`，
让 ellekit 的 TweakLoader 自然加载。**这一步需要一个 deb 包**，因为这目录
不属于 basebin。流程见 §2.3。

### 3.3 想批量预装 deb —— **加上面那段 10 行代码 + 改 Makefile**

完整 patch（针对上游 master）：

```diff
--- a/Application/Makefile
+++ b/Application/Makefile
@@ -16,6 +16,7 @@ build/Build/Products/Release-iphoneos/Dopamine.app: FORCE
 	xcodebuild ...
 	touch build/Build/Products/Release-iphoneos/Dopamine.app/Dopamine.roothide
+	cp -a Dopamine/Resources/*.deb build/Build/Products/Release-iphoneos/Dopamine.app/ || true
```

```diff
--- a/Application/Dopamine/Jailbreak/DOBootstrapper.m
+++ b/Application/Dopamine/Jailbreak/DOBootstrapper.m
@@ -<finalizeBootstrap, 紧跟在 installPackageManagers 之后>
         NSError *error = [self installPackageManagers];
         if (error) return error;
+
+        NSArray<NSString *> *preinstalledDebs = @[
+            @"ellekit.deb",
+            @"mypkg.deb",
+        ];
+        for (NSString *debName in preinstalledDebs) {
+            NSString *debPath = [[NSBundle mainBundle].bundlePath
+                                  stringByAppendingPathComponent:debName];
+            if (![[NSFileManager defaultManager] fileExistsAtPath:debPath]) continue;
+            int pr = [self installPackage:debPath];
+            if (pr != 0) {
+                return [NSError errorWithDomain:bootstrapErrorDomain
+                                           code:BootstrapErrorCodeFailedFinalising
+                                       userInfo:@{NSLocalizedDescriptionKey :
+                                                  [NSString stringWithFormat:
+                                                   @"Failed to install %@: %d",
+                                                   debName, pr]}];
+            }
+        }
```

> 注意：上游可能没把 `ellekit.deb` 默认放进 Resources（roothide 才主动 ship），
> 自己从 ellekit.space 下一份放进 `Application/Dopamine/Resources/`。如果你的
> tweak 已经依赖 ellekit，**确保它先装、再装你的 mypkg.deb**。

---

## 4. 几个上游独有的注意点

### 4.1 `loadBasebinTrustcache` 是 fail‑hard 的

上游版本如果 `basebin.tc` 与 `basebin/` 内 Mach‑O cdhash 对不上（例如你后期
手工换了 dylib 但没重新 `trustcache create`），整段越狱激活会失败
（`JBErrorCodeFailedBasebinTrustcache`）。任何修改 basebin 内文件**必须**走
`make -C BaseBin clean basebin.tar` 重建。

roothide 因为是运行时随机化算 cdhash 反而不存在这个问题。

### 4.2 jbroot 是 `/var/jb` 固定符号链接

- plist / sh / 配置文件里可以直接写 `/var/jb/...` 绝对路径。
- 用 `@JBROOT@` 占位符也可（`patchBasebinDaemonPlists` 会替换成 `/var/jb/`）。
- 系统启动时 `/var/jb` 不一定立刻可用（preboot UUID 解析后才挂载），所以**最
  早期的 daemon** 优先放 `basebin/LaunchDaemons/` 而不是 `Library/LaunchDaemons/`。

### 4.3 上游对"反越狱检测"不做主动隐藏

roothide 的整套随机化 jbroot + cdhash randomize 是为了对抗 App 端越狱检测。
**普通 Dopamine 不做这件事**：你的预加载 daemon / dylib 会以可读路径暴露在
`/var/jb`，凡是会扫 `/var/jb`、`/private/var/jb`、`/Library/MobileSubstrate` 的
检测脚本都能看到。如果对抗检测是目标，普通 Dopamine 不合适，需要换 roothide。

### 4.4 deb 在 Xcode project 中的引用

上游 `Application/Dopamine.xcodeproj` 默认只把 `sileo.deb`、`zebra.deb` 列进
"Copy Bundle Resources" build phase。新增 deb 时**两条任选**：
- (a) 在 Xcode GUI 里把 deb 加进 target 的 Resources phase；
- (b) 在 Makefile 里加 `cp -a Dopamine/Resources/*.deb ...`（绕过 Xcode）。

roothide fork 选了 (b)，更省事，但 ipa 可能多出几个不在 project 里的文件，
对 ldid 签名无影响。

---

## 5. 一句话总结

**普通 Dopamine 完全可以做预加载，而且因为：**
1. launchdhook 同时扫描 `basebin/LaunchDaemons` + `Library/LaunchDaemons` 两个目录；
2. jbroot 固定在 `/var/jb`，路径可预测；
3. `basebin.tc` 是编译期静态生成、规则透明；

**整体扩展点比 roothide 更宽。** 唯一需要补的是 `preinstalledDebs` 等价数组——
10 行代码就能加。

如果你的目标里**不需要**「对抗 App 越狱检测」「随机化路径」，**优先选普通 Dopamine**
做开发，方案 A/B/C 都更轻；只有当你必须隐藏 jb 痕迹时再切到 roothide 分支并按
[PRELOAD_FEASIBILITY.md](./PRELOAD_FEASIBILITY.md) 实施。

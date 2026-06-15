# 把 rootless tweak 移植到 roothide：原理与改动清单

> 适用：把原本为 Dopamine(rootless) 写、硬编 `/var/jb` 路径的自定义 tweak
> （如 `40-toorless`、`50-hooks`）适配到 roothide 的动态 jbroot。

---

## 一、原理：两种 jailbreak 的路径模型

| | rootless (Dopamine upstream) | roothide (Dopamine2-roothide) |
|---|---|---|
| jbroot 位置 | **固定** `/var/jb` | **随机** `/var/.../.jbroot-XXXXXXXX/`（每次安装不同）|
| 固定 `/var/jb` 符号链接 | 有（就是 jbroot 本身）| **没有**（故意不建，用于隐藏越狱）|
| 路径解析 | 直接用 `/var/jb/...` | 运行时转换：每进程注入 **systemhook** + **libroot**，用 `jbroot()` 拼真实路径 |

**关键结论**：roothide 上**不存在可依赖的固定 `/var/jb`**。任何在二进制/dylib 里**写死 `/var/jb/...` 的字符串，运行时都指向一个不存在的路径 → 失效**。

roothide 提供的转换 API（`<roothide.h>` / `libjailbreak/src/jbroot.h`）：
```c
#import <roothide.h>
jbroot("/usr/sbin/toorless")   // → "<真实jbroot>/usr/sbin/toorless"
rootfs("/path")                // jbroot 路径 → rootfs 相对
// 等价宏：JBROOT_PATH(p) / ROOTFS_PATH(p)
```
roothide 自己的代码就是这么用的，例如 systemhook 加载 TweakLoader：
```c
const char *p = JBROOT_PATH("/usr/lib/TweakLoader.dylib");   // 传 jbroot 相对路径，无 /var/jb
```

---

## 二、核心改动（必做，缺一不可）

### ① 必须用 roothide 工具链重新编译 —— 不是改字符串就行
`jbroot()` 这个符号来自 **roothide 的 libroot**。源码里写了 `jbroot()` 但仍用 rootless 工具链编，会**链接不过**。而且 roothide 的签名/entitlements 与 rootless 不同。所以：
- theos 用 **roothide 的 package scheme**（链接 roothide libroot），`#import <roothide.h>`。
- 参考官方文档：**https://github.com/roothide/Developer**（jbroot/libroot 用法以此为准）。

> 含义：rootless 版和 roothide 版是**两套不同的编译产物**，不能共用同一个 .deb/二进制。

### ② 代码里 `/var/jb/X` → `jbroot("/X")` —— 注意去掉 `/var/jb` 前缀
```objc
// ✗ 原（rootless 写死）
fopen("/var/jb/etc/toorless.conf", "r");
dlopen("/var/jb/usr/lib/libfoo.dylib", RTLD_NOW);
system("/var/jb/usr/bin/helper");

// ✓ 改（roothide，传 jbroot 相对路径）
#import <roothide.h>
fopen(jbroot("/etc/toorless.conf"), "r");
dlopen(jbroot("/usr/lib/libfoo.dylib"), RTLD_NOW);
posix_spawn 用 jbroot("/usr/bin/helper") ...
```
**易错点**：`jbroot()` 的参数是 **jbroot 相对路径**（`/etc/...`、`/usr/...`），
**不要**再带 `/var/jb`（写成 `jbroot("/var/jb/etc/..")` 会变成 `<jbroot>/var/jb/etc/..`，错）。

---

## 三、配套改动（容易漏，按 tweak 类型对照）

### LaunchDaemon（如 40-toorless 的 `.plist`）
- `Program` / `ProgramArguments[0]` 写 **jbroot 相对路径**（`/usr/sbin/toorless`），
  **不要** `/var/jb/usr/sbin/toorless`。roothide 启动时
  `launchctl bootstrap system /Library/LaunchDaemons` + 路径 hook 会解析到真实 jbroot。
- 其它参数里若传了 `/var/jb/...` 给守护进程，守护进程内部仍要用 `jbroot()` 解析。

### MobileSubstrate / ellekit dylib（如 50-hooks 的 Facehugger.dylib）
- **加载本身不用改**：roothide TweakLoader 从 jbroot 的
  `Library/MobileSubstrate/DynamicLibraries/` 加载，`.plist`(进程过滤)用 bundle id，无路径。
- **dylib 代码内部**写死的 `/var/jb` → 同 ②（`jbroot()` + roothide 重编）。

### 被 exec / dlopen 的“下游”文件
- 若 tweak 会调起别的二进制/库（`/var/jb/usr/bin/xxx`、`/var/jb/usr/lib/xxx.dylib`），
  这些**目标文件本身也得装进 roothide 的 jbroot**，且调用处用 `jbroot()` 解析。

### 配置文件 / maintainer 脚本里的路径
- deb 的 `postinst`/`prerm` 或随包配置文件里若硬编 `/var/jb`，也要改成
  jbroot 相对（脚本在 jbroot 上下文跑，用 `$JBROOT` 或 roothide 提供的变量）。

### 链接期路径（install_name / rpath）
- dylib 的 `LC_RPATH`、`install_name` 若指向 `/var/jb/...`，用 roothide 工具链重编即可正确生成；
  手工指定过 `-rpath /var/jb/...` 的要去掉。

---

## 四、不用改的部分（别白费功夫）

- **deb 的文件布局**：payload 仍按 `var/jb/...`（或 jbroot 相对）打包即可，
  roothide 安装时会把它重定位到真实 jbroot —— 文件会落对地方，这层不用动。
  （本仓库 `build-preload-debs.sh` 的 `var/jb/` 包法对两套都适用。）
- **ellekit/MS 注入 plist 的进程过滤**（Bundles/Executables）：与路径无关，不用改。

---

## 五、一句话判定 + checklist

> **“是不是把 `/var/jb` 改成 `jbroot()` 就行？”**
> 改字符串是**必要但不充分**。完整条件是：

- [ ] 用 **roothide 工具链/libroot 重新编译**（否则 `jbroot()` 链接不过、签名不对）
- [ ] 代码里所有 `/var/jb/X` → `jbroot("/X")`（**去掉 /var/jb 前缀**）
- [ ] LaunchDaemon plist 路径改 jbroot 相对，不带 `/var/jb`
- [ ] 被调起的下游二进制/库也装进 jbroot 且用 `jbroot()` 解析
- [ ] postinst/配置文件里的 `/var/jb` 一并处理
- [ ] rootless 版与 roothide 版作为**两套产物**分开（用 `control.yaml` 的 `skip_targets` 分发）

---

## 六、验证（装到 roothide 真机后）

```bash
# 1. 守护进程是否起来（toorless）
launchctl print system/<你的daemon label> 2>/dev/null | head
#    或看进程： ps -ax | grep toorless

# 2. dylib 是否被注入目标进程（Facehugger）
#    在目标 App 里看是否生效；或
#    在设备上确认文件确实落在 jbroot 内：
ls -l "$(jbroot 工具/或 jbctl 输出的 jbroot)"/usr/sbin/toorless

# 3. 看有没有“找不到 /var/jb/...”类报错（说明还有漏网的硬编路径）
#    用 Console / oslog 过滤你的 tweak 名
```
凡是日志里出现 `/var/jb/...` 的 No such file —— 就是还有没改干净的写死路径。

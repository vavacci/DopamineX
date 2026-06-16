# DopamineX 遗留问题（待以后探索）

记录已知但暂时搁置的问题，方便以后一起回来排。每条尽量写清**现象 / 已知线索 / 下一步**。

---

## 1. roothide：注入进程创建的文件，SSH 端完全找不到

**状态**：搁置（2026-06-16）

**现象**
- 在 roothide 设备的 SpringBoard 注入了一个 dylib（`preload-input/50-hooks-roothide/.../Facehugger.dylib`）。
- dylib 在 `/var/mobile/Library/Application Support/` 下创建目录+文件，**进程内判定创建成功，且能通过自己的接口读出该目录下文件内容**。
- SSH（root）`find /var -name '<目录名>' 2>/dev/null` **一个都搜不到**。

**已知线索 / 机制**
1. roothide 的 home 重定向：`BaseBin/systemhook/src/roothider_main.c::redirect_env_paths()`
   - 非容器化越狱进程：`CFFIXED_USER_HOME = <jbroot> + /var/mobile`。凡经 home 解析的
     API（`NSHomeDirectory`/`~`/`NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
     NSUserDomainMask)`/`URLsForDirectory:`）→ 落到 `<jbroot>/var/mobile/Library/Application Support/`。
   - **容器化进程**（home 形如 `/private/var/mobile/Containers/Data/...`）→ 代码 early return，
     **不重定向** → 落到该进程**私有沙盒数据容器**。
2. roothide **只重定向 home（CFFIXED_USER_HOME）和 dlopen（loadPathHook）**，**不重定向任意绝对路径**。
3. jbroot 位置：随机 `/var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX`（16-hex = jbinfo(jbrand)）；
   `get_jbroot()` 返回 `jbinfo(rootPath)`，无固定公式。

**为什么 `find /var` 也搜不到（两种假说，未定论）**
- (A) 文件在某 app 的 `/var/mobile/Containers/Data/Application/<UUID>/...` 沙盒容器里，
  **内核沙盒按进程隔离，root SSH 也读不进去**（不是 DAC 权限问题）。`find ... 2>/dev/null` 把
  "Operation not permitted" 吞了 → 0 结果是假阴性。
- (B) 该 SSH root shell 本身**没被 roothide 完全 platformize**，连 jbroot / Data 容器都进不去，
  导致 find 静默跳过；文件其实在 `<jbroot>/var/mobile/...`。

**下一步（回来时先做）**
1. dylib 里 `NSLog(@"abs=%@", url.path)` 打出**绝对路径** —— 前缀一出来立刻分支：
   - `.../.jbroot-XXXX/var/mobile/...` → 假说 B（jbroot 重定向，shell 权限问题）
   - `/var/mobile/Containers/Data/Application/<UUID>/...` → 假说 A（沙盒容器隔离）
2. SSH 端**不要吞 stderr**：`find /var/mobile/Containers/Data -name '<名>' 2>&1 | grep -vi 'No such'`；
   并测 `ls /var/mobile/Containers/Data/Application/ 2>&1`、`ls -dla /var/containers/Bundle/Application/.jbroot-* 2>&1`
   判断 shell 是否被沙盒限死。
3. 若要数据**跨进程/SSH 可见**：别写进 app 私有容器或 home，改用 jbroot 内固定绝对路径
   （`JBROOT_PATH`/`jbroot()` 拼），或真实 `/var/mobile` 的写死绝对路径。

---

## 2. roothide：toorless daemon（127.0.0.1:17533）/ initfs 子系统未打包

**状态**：搁置（2026-06，等 initfs 文件）

**现象**
- 设置里「设备初始化」POST `http://127.0.0.1:17533/init {"fh_device_id":...}` 报"无法连接服务器"。
- 17533 没起来。

**已知线索**
- `preload-input/40-toorless-roothide/` 只有 `usr/sbin/toorless`(arm64) + 两个 plist；
  toorless 二进制引用了一整套 `initfs/` 子系统（`@JBROOT@/initfs/bin/toorless16`、
  `initfs/lib/libxpc_fixup.dylib`、`libhardware_debug_support.dylib`、`kern_tool`、
  `_jbroot_initfs_path`）**未打包**。
- iOS16.5.1 似乎要 toorless16 + libxpc_fixup.dylib 变体；第三方 plist 的 `@JBROOT@` 不被替换。

**下一步**
- 需要用户提供 initfs 那套文件 / 说明它在 rootless 版怎么部署（某包带的？运行时生成？），
  再打进 roothide preload（正确 jbroot 路径、plist 用无前缀 jbroot 路径）。

---

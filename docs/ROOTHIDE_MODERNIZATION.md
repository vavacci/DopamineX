# roothide Dopamine2 构建现代化（Xcode 26 本地直编）

> 归档日期：2026-06-15　|　状态：✅ 已完成，可在 macOS 26 / Xcode 26 本地一键出 `Roothide.tipa`

## 1. 背景与目标

DopamineX 原本有两条线：

- **upstream**：opa334/Dopamine（rootless，固定 `/var/jb`），`./tools/macos-build.sh` 本地直编。
- **roothide**：roothide/Dopamine2-roothide（随机隐藏 jbroot、反检测）。

roothide 这条线长期**只能用 Xcode 15 / iOS 17 SDK 编**——要么钉死在 GitHub Actions 的 `macos-14` runner，要么本地装老 Xcode。而开发机是 **macOS 26.3.1 + Xcode 26**，跑不了老 Xcode，导致每改一点功能都得走 CI，迭代极慢。

**目标**：让 roothide 在 **Xcode 26 本地直接 `gmake` 编过**，甩掉 CI / 老 Xcode。

**采纳路线**：只做"构建现代化"——把少数几处"新 SDK / 新链接器导致编不过"的点外科手术式修掉。**不**融合进 upstream（≈重造 roothide），**不**从头写。依据：CI 日志早已证明 BaseBin 在 iOS 17.5 SDK 上整树干净编过，代码本身没问题，挡路的纯是工具链太新。

## 2. 拦路点与根因

### 2.1 `xpc_connection_get_pid` 被标 unavailable

- iOS 18.5 / 26 SDK 把 `xpc_connection_get_pid` 标为 `__API_UNAVAILABLE`，直接引用编不过。
- 全 roothide 只 `BaseBin/roothidehooks/cfprefsd.x` 用到它一处（取 client pid 打日志）。`get_euid` 等仍可用。

### 2.2 移走 SDK xpc 头的 hack —— 真正的历史根因

之前为了"让编译用仓库自带的 xpc 头"，构建脚本会把 Xcode SDK 的 `usr/include/xpc` 移走。这在 Xcode 15 上凑效，但在 Xcode 26 上触发 `<XPC/xpc.h>` 大小写错（`nonportable-include-path`）。

**查清的真相**：roothide 自己的 `BaseBin/Makefile`（`.include` 目标）**早就处理了新 SDK**：

```makefile
.include:
	cp -r _external/include/* .include
# If the SDK already ships XPC (iOS 17.4+), remove the local copy of it
ifneq (,$(wildcard $(SDK)/usr/include/xpc.modulemap))
	rm -rf .include/xpc
endif
```

即：iOS 17.4+（含 26）自带 xpc 时，它会删掉 `.include/xpc` 改用 **SDK 的 xpc 头**；私有 xpc SPI（`get_audit_token` / `set_peer_code_signing_requirement` / `copy_entitlement_for_token` 等）走**单独的 `.include/xpc_private.h`（不删）**。

所以现代 SDK 本就该用 SDK 的 xpc。我们的"移头" hack 反而和它打架——Makefile 删了 `.include/xpc`，我们又把 SDK 的 `usr/include/xpc` 也移走，**两边 xpc 都没了** → `<xpc/xpc.h>` 落到大写 `XPC.framework` → 大小写错。**这才是 roothide"只能老 Xcode 编"的真凶，不是 Xcode 本身。**

### 2.3 Xcode 26 新链接器的 shared-cache 资格检查

`palera1n.dylib` 装到 `/usr/lib`，新 `ld` 把它标为 "shared-cache eligible"，而它链接的 `libjailbreak.dylib` 是 `@loader_path`（ineligible）：

```
ld: Shared cache eligible dylib cannot link to ineligible dylib '@loader_path/libjailbreak.dylib'.
    ... opt out using ... linker flag '-not_for_dyld_shared_cache'
```

palera1n 是运行时注入的越狱 dylib，本就不该进 dyld 共享缓存。

## 3. 改动清单（全部收进幂等脚本 / patch）

| # | 文件 | 改动 |
|---|------|------|
| 1 | `BaseBin/roothidehooks/cfprefsd.x` | 用 `dlsym(RTLD_DEFAULT,"xpc_connection_get_pid")` 包一层，运行时取符号，绕开新 SDK 头文件声明。任何 Xcode 可编，运行时行为不变。 |
| 2 | `Application/Dopamine/Exploits/palera1n/Makefile` | `palera1n_LDFLAGS` 追加 `-Wl,-not_for_dyld_shared_cache`。旧链接器忽略该 flag，无副作用。 |
| 3 | `tools/macos-build.sh` | **删掉**"移走 SDK xpc 头"的 step 4b（2.2 的根因）。让 roothide 原生 Makefile 自己处理 xpc。 |
| 4 | `tools/build-roothide.sh` | **删掉**自动切老 Xcode 的逻辑；改为始终委托给（幂等的）`setup-roothide-tree.sh`。 |
| 5 | `tools/macos-build.sh` | 产物按 target 命名：roothide → `Roothide.tipa`，upstream → `Dopamine.tipa`。Xcode 内部产物 `Dopamine.app`/`Dopamine.ipa` 不变。 |

> **为什么 1、2 要做成 patch**：`Dopamine2-roothide/` 树**不在仓库里**，是 `setup-roothide-tree.sh` 现 clone 上游 `roothide/Dopamine2-roothide@57ffae0` + 打 patch 生成的。所以对树内源码的改动必须走 `tools/roothide-modernize.patch`，由 setup 自动套用，否则会被重新 clone 覆盖。

### patch 的幂等机制

`roothide-modernize.patch` 会随迭代增长。`setup-roothide-tree.sh` 用"按标记校验 + `patch --forward`"保证幂等：

1. 先 grep 每处改动的标记（`roothide_xpc_connection_get_pid`、`not_for_dyld_shared_cache`）。全在 → 跳过。
2. 否则 `patch -p1 --forward`（已应用的 hunk 自动跳过，新 hunk 照常套上），再按标记复核。

**好处**：将来新增修复时，只改 `setup-roothide-tree.sh`（加标记）+ patch（加 hunk），**已有的树也能增量补打，无需重新 clone**。`build-roothide.sh` 不用动。

## 4. 本地构建（Xcode 26）

```bash
cd ~/XcodeWorkspace/DopamineX
git pull
./tools/build-roothide.sh        # 不需要切 Xcode；树/patch 自动就位
# 产物：Dopamine2-roothide/Application/Roothide.tipa
# → AirDrop 到 iPhone，用 TrollStore 安装
```

upstream 版仍是：`./tools/macos-build.sh` → `Dopamine.tipa`。

## 5. CI（兜底，已降级为手动）

`.github/workflows/build-roothide.yml` 仍在 `macos-14`(Xcode15/iOS17.5) 上跑，但**已去掉 push 触发，只保留 `workflow_dispatch`**。本地环境出问题时，去仓库 Actions 页手动 "Run workflow" 即可，产物 artifact 名 `roothide-Dopamine2-tipa`。

## 6. 排错：将来再遇到"新工具链编不过"

按这次的同一思路逐个修，并把改动并进 `roothide-modernize.patch`：

- **新 SDK 标某符号 unavailable**：`dlsym` 运行时取（如本例 `get_pid`），或编译参数加 `-Wno-availability` / `-Wno-error=unguarded-availability`。
- **新链接器 dylib 资格 / 段对齐类报错**：按 ld 提示加链接器 flag（如本例 `-not_for_dyld_shared_cache`），旧链接器通常忽略，安全。
- **`<xpc/...>` 大小写 / 头找不到**：**不要**再去移/删 SDK 的 `usr/include/xpc`——交给 `BaseBin/Makefile` 自己处理。
- 改完务必在 `setup-roothide-tree.sh` 的 `modernize_applied()` 里加上对应标记，保持幂等。

## 7. 关联文件

- `tools/build-roothide.sh` — roothide 一键入口
- `tools/setup-roothide-tree.sh` — clone + 打 preload/modernize patch（幂等）
- `tools/roothide-modernize.patch` — 现代化源码改动（cfprefsd.x + palera1n/Makefile）
- `tools/roothide-preload.patch` — 预装 deb 的 DOBootstrapper 改动
- `tools/macos-build.sh` — upstream/roothide 共用构建引擎
- `docs/ROOTHIDE_TWEAK_PORTING.md` — tweak 适配 roothide 动态 jbroot 路径

## 8. 反检测定制（2026-06，SSH 端口 + 默认白名单）

两项越狱后反检测定制，均为 **roothide 专用**（`skip_targets: [upstream]`）。

### 8.1 RootHide Manager 的检测警告 = 端口探测（不是查文件）

`roothideapp.deb`(`com.roothide.manager`，官方预编译 v1.3.9) 的 `showDetectionWarning:`
对 `127.0.0.1` 做 **TCP connect 探测**（反汇编 `socket`/`inet_addr`/`connect` + 解 sockaddr 端口确认）：

| 探测项 | 端口 |
| --- | --- |
| `SSH Server has been installed` | `22` 和 `2222` |
| `Dropbear ...` | 另一本地端口 |
| `Frida Server ...` | `27042`（`0xa269` 字节序还原） |

→ 把 sshd 挪到 **18888**（不在 {22,2222}）即可绕过该警告。

### 8.2 SSH → 18888：`preload-16-ssh-port-roothide`

roothide 的 openssh-server 用 **launchd inetd 模式**，监听端口由
`/Library/LaunchDaemons/com.openssh.sshd.plist` 的 `Sockets`（默认 `ssh`→22 + `2222`）
决定，**不是 sshd_config 的 `Port`**。包的 postinst：plutil 外科改 `Sockets.SSHListener.SockServiceName=18888`
+ 删 `SSHListener2`（兜底整份重写 plist），再 `launchctl bootout`+`bootstrap` 重载。
连接改用 `ssh -p 18888`。该包只装 postinst、无 data 文件；硬编 openssh 先于 preload 装，故 plist 必已在位。

### 8.3 默认白名单模式：`blacklist.m` patch + `preload-45-whitelist-default-roothide`

- **真相**：Manager 里的 `whitelistMode` 开关是 `disabled:YES` 的**死摆设**，越狱端根本不读它。
  真正生效的是 `BaseBin/libjailbreak/src/roothider/blacklist.m::isBlacklistedApp()`：读
  `RootHideConfig.plist`(在 jbroot 内) 的 `appconfig[bundleID]`，**不在表里就默认注入**（黑名单语义）。
- **改法**（纳入 `roothide-customize.patch`）：app 不在 `appconfig` 时改为返回
  `roothideWhitelistDefault()` —— 读 config 顶层 `whitelistMode`(优先) 或 marker 文件
  `/etc/dopaminex/whitelist-default` 是否存在。显式配置(appconfig 有该 app)永远优先。
- **marker** 由 `preload-45-whitelist-default-roothide` ship（`./etc/dopaminex/whitelist-default`，
  prefix-less 装进 jbroot/etc，libroot 自动重定向；重装覆盖空文件无副作用，**不碰** `/var/mobile`
  里用户的 appconfig 选择）。删包/删文件即恢复原生黑名单默认。
- **语义/边界**：只 gate `/private/var/containers/Bundle/Application/<UUID>/*.app`(第三方/侧载 app)；
  **系统 app(/Applications) 不受影响照常注入**。给某 app 开 tweak：RootHide Manager → AppList →
  该 app 开关置 **OFF**(写 `appconfig[id]=NO`=显式允许)。
- **幂等**：`setup-roothide-tree.sh` 的 `customize_applied()` 增加 `roothide-customize-whitelist` 标记检查；
  blacklist.m 加入 1c reset-to-pin 列表；新增 2e 清理 `.rej/.orig`。

### 8.4 RootHide.app（Manager）必要性 / 可见性

- = 上述 Manager，DOBootstrapper **强制安装**。注入本身不靠它（systemhook/launchd 干），
  但 per-app 注入开关/varClean/检测提醒靠它。Info.plist 是普通 app（无隐藏标记），
  靠 roothide 运行时把越狱 app 从 `LSApplicationWorkspace` 枚举里摘掉 → 常规应用列表扫不到。

## 9. Developer Mode 隐藏(roothide 自带,内核+用户态双层)

iOS16+ 检测 Developer Mode 主流就是读内核 sysctl `security.mac.amfi.developer_mode_status`(=1 即开)。roothide **已自带隐藏**:

- **内核级 `hideDeveloperMode()`**(`BaseBin/libjailbreak/src/roothider/common.m`,由 `launchdhook` 首次加载调用,iOS16+,用 kfd kernel R/W):把 `developer_mode_status` 这个 sysctl OID 的 `oid_name/number/descr/kind` 跟兄弟 sysctl `security.mac.amfi.launch_env_logging` **对调**。结果:任何进程按名字查 `...developer_mode_status` → 解析到 launch_env_logging 节点的数据(通常 0)→ 读到"关闭"。不删 OID(删了查询失败本身是 tell),返回真实兄弟值更自然。**系统级、对所有进程**(含未注入的检测 app)。
- **用户态 `systemhook`**(`roothider_common.c` `__sysctl_hook`/`__sysctlbyname_hook`):对**被注入的越狱进程**,把该 sysctl 强制返回 **1**——因为内核值被藏成 0 后,越狱进程自己也读 0,但注入/JIT/未签名 dylib 需要 dev-mode=1 才能跑,故用户态顶回 1。

**两层互补**:越狱进程读 1(功能),其它进程读 0(隐藏)。

**关键协同(与白名单默认)**:用户态 hook 对**所有被注入进程无条件返回 1**。所以 **一旦把做越狱检测的 app 加白(=注入它),它会读到 dev_mode=1 → 自己暴露**。配合 §8.3 的默认白名单(第三方 app 不注入),检测 app 走内核路径读到隐藏后的 0 → dev-mode 隐藏才对它真正生效。**做检测的 app 千万别加白。**

**缺口**:只 mask sysctl 名字查询(主流路径);AMFI 行为信号(dev-signed 能否跑/能否 attach)没 mask,但沙盒 app 难主动探。mask 值依赖 launch_env_logging≈0。当前 内核隐藏+白名单默认 已是最优组合,无需再叠。

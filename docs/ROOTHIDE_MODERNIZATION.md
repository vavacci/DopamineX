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

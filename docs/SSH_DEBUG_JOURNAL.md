# SSH 调试 / 修复全记录（2026-05-14 → 2026-05-15）

DopamineX 第一次激活后 `ssh` 不通的全部根因 + 修复，按发现顺序排。**所有
fix 都已入仓**，正常用户**不需要**重复任何手工命令——这文档主要是给：

- 未来调同类问题的我自己
- fork DopamineX 改造别人设备的人

如果你只想看「怎么用 SSH」，去 [SSH_ACCESS.md](./SSH_ACCESS.md)。

---

## 顶层时间线

| # | 症状 | 根因 | 修复 | 入仓 |
| --- | --- | --- | --- | --- |
| 1 | iproxy 转发但 `nc localhost 22` "No such file or directory" | sshd 监听 18888 (roothide 反检测改的)，转 22 是空 | iproxy 转 18888 | 文档化（[SSH_ACCESS.md](./SSH_ACCESS.md)）|
| 2 | `launchctl bootstrap` 报 `Bootstrap failed: 122 Path had bad ownership/permissions` | plist 属主 `_apt` (Procursus apt sandbox 用户)，不是 root | postinst `chown root:wheel` + 上级目录链 `chmod 0755` | `1076964` |
| 3 | TCP 接受但 `kex_exchange_identification: Connection closed by remote host` | host key 缺失（没 `ssh_host_*_key`），sshd 启不起 | postinst 调 `ssh-keygen -t {rsa,ecdsa,ed25519}` 兜底生成 | `85a5ca9`（早期版本）|
| 4 | host key 在了，连上后又被 reset | sshd 启动 worker 时 `PAM: initialisation failed for "root"`——iOS rootless 无 PAM 模块 | `UsePAM no` | `85a5ca9` |
| 5 | UsePAM 改了但没生效，ssh 还是同样 reset | `sshd_config` 是 **first-match-wins**。append 在末尾的 `UsePAM no` 被前面已有的 `UsePAM yes` 屏蔽 | postinst 用 sed 替换前置 directive，没有再 append | `af68750` |
| 6 | Mac 上输完密码立即断开（NewTerm 本地能登） | sshd `MaxAuthTries` 默认 6；Mac ssh-agent 里多个 key 全被拒后撞顶上限，**还没轮到密码 prompt 就被踢** | `MaxAuthTries 20` | `af68750` |
| 7 | postinst 第一次没跑 → 后续重激活时 `set -e` 让 postinst 在某行 silent exit | dpkg postinst 上下文 PATH/locale 不稳，任何命令失败都中断后面所有步骤 | 删 `set -e`，每行 `|| true` 防御式 | `54cff53` |
| 8 | 重 build 重装，**ssh-host-keys 包仍然没装上**（dpkg -l 里没有，info/ 下没有 postinst） | `.tipa` 里有 `ssh-host-keys.deb` 但 Dopamine 装包循环静默跳过 | 见 §A | `36330ca` |
| 9 | （承接 #8）jbctl `install_pkg` 静默丢弃错误码，loop 永远返 0 | DOBootstrapper.m 非 root 分支 hardcode `return 0`，upstream 注释明说 "waitpid 不稳定，干脆忽略" | 装完用 `installedVersionForPackageWithIdentifier:` 复查 dpkg status，没装上就 fail finalizeBootstrap 并打印是哪个包 | `36330ca` |
| 10 | （承接 #8）ssh-host-keys.deb 单独装失败，其他 12 个包都装上 | 这个包 zero payload，只有 `DEBIAN/control + DEBIAN/postinst`，没 data 部分。jbctl `install_pkg` 静默拒收（裸 `sudo dpkg -i` 反而能装） | 加一个 stub `usr/share/doc/dopaminex-ssh-host-keys/README` 让 deb 有 data 段 | `36330ca` |

---

## §A 排查 ssh-host-keys 没装的全过程

最坑的一条线，单独详写以便复盘。

### 症状收敛

1. ssh 还是不通 → 设备 NewTerm 跑 `ls /var/jb/etc/ssh/ssh_host_*` → 没文件 → 推测 postinst 没跑
2. `sudo cat /var/jb/var/lib/dpkg/info/com.dopaminex.preload.ssh-host-keys.*` → 全无 → 包根本没装
3. `dpkg -l | grep ssh-host-keys` → 空 → 同上
4. `find /var/containers/Bundle/Application -name "*ssh-host-keys*.deb"` → 在 `.tipa` 里**找到了**
5. → 矛盾：deb 在 .tipa 里，但 dpkg 没装过它，jailbreak 激活又没报错

### 关键中转：手工装一遍

```sh
sudo dpkg -i /var/containers/Bundle/Application/<UUID>/Dopamine.app/preload-15-ssh-host-keys.deb
```

**成功**。dpkg 装上了，postinst 正常跑，sshd 起来了。

这证实：deb 本身没坏。问题在 **Dopamine 怎么调 dpkg**。

### 看代码：`installPackage:` 是怎么调的

```objc
- (int)installPackage:(NSString *)packagePath
{
    if (getuid() == 0) {
        return exec_cmd_trusted(JBROOT_PATH("/usr/bin/dpkg"), "-i", ...);
    }
    else {
        // idk why but waitpid sometimes fails and this returns -1,
        // so we just ignore the return value
        exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", "install_pkg", ...);
        return 0;
    }
}
```

发现两件事：

1. Dopamine 作为 TrollStore 装的 iOS app 跑，`getuid() == 0` 永远 false → 永远走 `else`
2. `else` 分支**永远返回 0**——upstream 觉得 `exec_cmd` 的返回码不可靠，索性丢掉

→ jbctl 装失败也罢、装成功也罢，调用方都看到 `pr == 0`，循环继续往下走

### 为什么单单 ssh-host-keys 失败

12 个 deb 都装上了（ellekit、curl、openssh-* 系列、hooks），就 ssh-host-keys 没装。
看 build dir：

```sh
$ find build/preload-debs/15-ssh-host-keys -type f
build/preload-debs/15-ssh-host-keys/DEBIAN/postinst
build/preload-debs/15-ssh-host-keys/DEBIAN/control
```

**完全没有 data 文件**。原本 15-ssh-host-keys 只是个 "拉起 sshd 的脚本载体"，
没东西要装到 jbroot，所以 `var/jb/` 是空的。

`dpkg -i` 直接装这种 zero-payload deb 是可以的（只跑 postinst），但 jbctl 的
`install_pkg` 包了一层 sanity check（猜测验证 data.tar 非空之类），直接拒收。

### 修

**两件事一起做**：

1. **加 stub 文件**：在 `preload-input/15-ssh-host-keys/usr/share/doc/dopaminex-ssh-host-keys/README` 放一句话说明，让 deb 有 data
2. **永久补 `installPackage` 的错误检测**：装完用 `installedVersionForPackageWithIdentifier:` 查 dpkg status——这才是"装上了"的真实信号

后者意义远超过修这一个包：以后**任意** preload deb 装失败都会**直接 fail 越狱激活并打印是哪个包**，不会再有静默跳过。

### 副产物：preinstalled_debs.h 结构改了

原来只有 deb 文件名，现在每条还带 Package id（dpkg 查询用）：

```c
typedef struct {
    NSString * const debName;
    NSString * const pkgName;
} DopaminePreloadEntry;

static const DopaminePreloadEntry kDopaminePreinstalledDebs[] = {
    { @"preload-15-ssh-host-keys.deb", @"com.dopaminex.preload.ssh-host-keys" },
    ...
};
```

`build-preload-debs.sh` 已经从 `dpkg-deb -f` (passthrough) / `control.yaml` (build)
拿到 Package 名字，直接 emit 出来即可。

---

## §B 客户端侧坑（不在 fix 范围内，文档化）

Mac 端首次 ssh 经常踩这个：

```
debug1: Authentications that can continue: publickey,password
debug1: Next authentication method: publickey
debug1: Offering public key: id_ed25519 ...
debug1: Authentications that can continue: publickey,password
... (重复 N 次)
Received disconnect from 127.0.0.1: 2: Too many authentication failures
```

Mac `~/.ssh/` 多 key + ssh-agent 加了一堆 → ssh 客户端把每个 key 都试一遍 → 
全被 sshd 拒（设备没 authorized_keys）→ 撞 `MaxAuthTries` 上限 → 还没到密码
prompt 就被断开。

postinst 已经把 `MaxAuthTries` 拉到 20 缓解。彻底解决看 [SSH_ACCESS.md](./SSH_ACCESS.md)
里 "客户端固化配置" 那段，加 `PubkeyAuthentication=no` 强制走密码。

---

## §C 仍然未解决的问题

### root 用户 ssh 密码被拒（mobile 正常）

**状态**：已在仓库 task tracker 里立项（#54），暂不阻塞日常使用。

**症状**：

```
$ ssh -p 2222 mobile@localhost     # 输 alpine → 进
$ ssh -p 2222 root@localhost       # 输 alpine → Permission denied
```

`/var/jb/usr/sbin/sshd -d -e` 看 debug log 显示对 root 也是密码不匹配，
不是 `PermitRootLogin` 拦的（PermitRootLogin yes 已生效）。

**怀疑方向**：

1. postinst 的 `chpasswd "root:alpine"` 在 iOS rootless 上写到了某个 sshd
   不读的 passwd 后端
2. iOS rootless 上 root 的密码列可能被某层"读不到 = 锁定"语义处理
3. `master.passwd` vs `shadow` vs `DSLocalDB` 三家 passwd 后端不一致
4. `passwd_mkdb` 命令在 iOS rootless 不存在 / 不更新 spwd.db

**下次调查的入口命令**（设备上）：

```sh
# 看 sshd 实际通过哪条路径读 root 的密码
sudo /var/jb/usr/sbin/sshd -p 18889 -ddd -e 2>&1 | tee /tmp/sshd-root.log &
ssh -p 18889 root@127.0.0.1   # 输 alpine
# 找 sshd-root.log 里 "auth_password" / "getpwnam" 相关行

# 看 root 密码列实际是什么
sudo grep "^root" /var/jb/etc/master.passwd
sudo grep "^root" /var/jb/etc/shadow      # 如果有的话
sudo grep "^root" /etc/master.passwd      # rootfs 上的，sshd 可能优先读这个
```

**workaround**（现状）：日常用 `mobile@`，需要 root 权限在设备上 `sudo -i`。

---

## §D 各 commit 用一句话讲讲做了啥

```
36330ca  fix: ssh-host-keys auto-install + verify all preload installs
         ↑ 两件事：stub 文件让 jbctl 接收 zero-payload；dpkg status
           复查每个 preload 真装上没。永久解决"静默跳过"。

af68750  fix(15-ssh-host-keys): sed-replace sshd_config, raise MaxAuthTries
         ↑ first-match-wins，append 不生效。改成 sed 替换前置 directive。
           顺手把 MaxAuthTries 拉到 20 让多 key Mac 客户端不被踢。

54cff53  fix(15-ssh-host-keys): defensive postinst; never exit early
         ↑ 删 set -e + 每行 || true。dpkg postinst 上下文不可控，
           不能让任何一步失败把后面全跳过。

0d52c7e  fix(15-ssh-host-keys): kickstart sshd when sshd_config changes
         ↑ kickstart 触发条件原来只看 host key 是否新生成；config 改了
           也要 reload。

382d4af  feat(15-ssh-host-keys): set root password to 'alpine' on install
         ↑ 公开仓库已明确接受 alpine 明文。chpasswd + sed master.passwd
           兜底。

85a5ca9  fix(15-ssh-host-keys): patch sshd_config UsePAM=no for rootless iOS
         ↑ iOS rootless 无 PAM 模块。

1076964  fix(15-ssh-host-keys): force root:wheel/0644 on plist before bootstrap
         ↑ Procursus dpkg 安装让 plist 属主变成 _apt，launchd 拒绝加载。
```

---

## §E 用这堆经验给后续 preload 作者的建议

如果你给 DopamineX 加新 preload 包：

1. **永远要有 data 文件**——哪怕一个 README。zero-payload deb 在 jbctl 路径上不可靠。
2. **postinst 不要 `set -e`**——iOS dpkg context PATH 不稳。每行单独 `|| true`，关键步骤
   独立判分支。
3. **改 sshd_config 用 sed 替换前置 directive，不要 append**——`first-match-wins`。
4. **要改 launchd 加载的 plist：自己 chown root:wheel + chmod 0644**——dpkg 装出来的
   plist 属主可能是 `_apt`，launchd 拒载。
5. **调用 launchctl bootstrap / kickstart 要容错**——失败 `|| true`，不要让 postinst
   返回非 0 阻断装包（dpkg postinst 失败会让 jbctl 整个 install_pkg 失败 → 现在
   会触发 finalizeBootstrap 失败 → 整个越狱激活失败）。
6. **任何首次激活要做的事都写成 idempotent**——Dopamine 每次重激活都会重跑 preload
   loop，postinst 会被反复调用。

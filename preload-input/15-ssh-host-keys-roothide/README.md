# 15-ssh-host-keys-roothide（roothide 版）

只发给 roothide（`control.yaml: skip_targets: [upstream]`）。rootless 版在 `../15-ssh-host-keys/`
（那个 `skip_targets: [roothide]`，因为它的 postinst 写死了 `/var/jb` 前缀，在 roothide 上会装失败）。

## 它做什么（装完 openssh 后，由 dpkg 跑 `DEBIAN/postinst`）
1. 生成缺失的 sshd host keys（rsa/ecdsa/ed25519，幂等）
2. patch `sshd_config`：`UsePAM no` / `PasswordAuthentication yes` / `PermitRootLogin yes` /
   `MaxAuthTries 20` 等（解决 iOS 无 PAM、默认禁 root/密码登录、多 key 被踢的问题）
3. **把 root 密码设成 `alpine`**（chpasswd，或 openssl 改 `/etc/master.passwd` + `pwd_mkdb`）
4. bootstrap / kickstart sshd

## 与 rootless 版的唯一区别：路径无 `/var/jb` 前缀
roothide 的 dpkg 是 jbroot 里的越狱二进制（libroot 感知）。它跑 postinst 时，脚本里的绝对路径
`/etc`、`/usr`、`/Library` 会被 libroot 自动重定向到 `<jbroot>/etc` 等——所以 `JB=""` 即可，
跟第三方 LaunchDaemon plist 用无前缀 jbroot 路径是同一套约定（见 `docs/ROOTHIDE_TWEAK_PORTING.md`）。

## ⚠️ 安全警告
硬编码 `root:alpine` 让全新装机无需手输密码即可 ssh。本仓库 public，等于任何知道设备地址的人都能
ssh 进 root。仅自用可接受；给别人设备请改私密口令或删掉密码段。

## ⚠️ 需设备实测确认
roothide 上 postinst 的无前缀路径重定向、`chpasswd`/`pw` 是否可用、`launchctl bootstrap` 行为，
都建议首次安装后用 `ssh root@<device>`（密码 alpine）验证一次。若密码段没生效，
roothide bootstrap 本身的默认 root 密码通常也已是 `alpine`，可直接试。

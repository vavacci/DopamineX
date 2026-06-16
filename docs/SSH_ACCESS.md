# 在 DopamineX 设备上 ssh

> ⚠️ **SECURITY WARNING — KNOWN-PUBLIC ROOT PASSWORD** ⚠️
>
> 本仓库是公开的，`preload-input/15-ssh-host-keys/DEBIAN/postinst` 在装包时
> **明文把 root 密码设为 `alpine`**——任何能拿到你的 DopamineX 越狱设备网络
> 可达 IP 的人都可以 `ssh root@... 密码 alpine`。
>
> 这是个**有意的便利取舍**，仅适用于个人/开发设备。如果你想把这个 fork 用于
> 别人的设备 / 生产 / 信任的同事之外，请：
> - 把 `15-ssh-host-keys/DEBIAN/postinst` 里 `DEFAULT_PWD="alpine"` 改成
>   你的私密密码（**不要 commit 进仓库**——改成读取一个 gitignore 的 secret
>   文件，或者根本删掉这一段，依赖 `sudo passwd root` 手工设）。

> 配套：
> - [PRELOAD_HOWTO.md](./PRELOAD_HOWTO.md)
> - [SIGNING_AND_DEPLOYMENT.md](./SIGNING_AND_DEPLOYMENT.md)

DopamineX 预加载 openssh，越狱激活后 sshd 自动启动。但有几个**非默认**约定踩
错就连不上，记在这里。

## 关键事实

| 项 | 值 | 备注 |
| --- | --- | --- |
| sshd 二进制 | `/var/jb/usr/sbin/sshd` | Procursus build |
| sshd 包来源 | `roothide.openssh-server 9.7p1-1+roothide1` | 不是上游 Procursus 版本 |
| **监听端口** | **`18888`**，不是 22 | 避免 RootHide Manager 端口探测(扫 127.0.0.1:22 和 :2222)报 "SSH Server has been installed"。**roothide 侧**由 `preload-16-ssh-port-roothide` 的 postinst 改 openssh launchd plist 的 `Sockets`(去 22/2222→单 18888)+重载实现；注意 roothide 是 launchd inetd 监听，端口在 plist 不在 sshd_config 的 `Port` |
| Host key 路径 | `/var/jb/etc/ssh/ssh_host_{rsa,ecdsa,ed25519}_key` | 由 `preload-15-ssh-host-keys` 在首次激活时生成 |
| 配置文件 | `/var/jb/etc/ssh/sshd_config` | rootless 路径 |
| 默认 root 密码 | **`alpine`**（由 15-ssh-host-keys postinst 写入） | ⚠️ 公开仓库明文，详见顶部 SECURITY WARNING |
| 默认 mobile 密码 | `alpine`（Procursus 默认） | 同上 |

## ssh 进设备的两种方式

### 方式 1：USB + iproxy（推荐）

```sh
# Mac 上一次性装
brew install libimobiledevice

# 每次用之前起一个 forwarder
# 把 Mac 本地 2222 转发到设备 18888
iproxy 2222 18888

# 另开终端
ssh -p 2222 mobile@localhost                # 或 root@localhost
# 密码: alpine
```

### 方式 2：Wi-Fi 直连（同网下）

```sh
# 设备 IP 看 Settings → Wi-Fi → 当前网络 i → IP
ssh -p 18888 mobile@<device-ip>
# 密码: alpine
```

注意 iOS 蜂窝/Wi-Fi 受 firewall 影响，公司 / 公共 Wi-Fi 经常 block；USB 路径更稳。

## 首次 ssh 之后立即做

```sh
# 1. 改默认密码（root + mobile 两个用户）
passwd                                       # 当前用户
sudo passwd root                             # 改 root
sudo passwd mobile                           # 改 mobile

# 2. 上传你自己的 public key 免密
mkdir -p ~/.ssh
echo "ssh-ed25519 AAAA... your@mac" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys

# 3. 可选：关闭密码登录，只走 key (sshd_config)
sudo vim /var/jb/etc/ssh/sshd_config
# PasswordAuthentication no
sudo launchctl kickstart -k system/com.openssh.sshd
```

## 排错

### `kex_exchange_identification: Connection closed by remote host`

最常见两个原因：

**a) 端口错了**

iproxy 转的端口跟 sshd 实际监听端口不一致。验证：

```sh
# 设备 NewTerm 里
sudo /var/jb/usr/sbin/sshd -T 2>&1 | grep -E "^port"
# 期望: port 18888
```

如果显示 18888 但你 iproxy 转的 22，改 iproxy 命令为 `iproxy 2222 18888`。

**b) host key 缺失**

```sh
# 设备 NewTerm 里
ls /var/jb/etc/ssh/ssh_host_*
# 期望: 6 个文件 (rsa/ecdsa/ed25519 各一对 key + pub)
```

如果**完全没有**：

- `dpkg -l | grep ssh-host-keys` 看 `com.dopaminex.preload.ssh-host-keys` 包装上没
- 没装上 → 装的不是含 15-ssh-host-keys 的最新 .tipa → 重 build .tipa
- 装上了但 key 没生成 → 手工跑 `sudo ssh-keygen -A -f /var/jb/etc/ssh`

**c) sshd 进程没起**

```sh
# 设备 NewTerm 里
launchctl list | grep -i ssh
# 期望: 一行 com.openssh.sshd PID xxx
```

PID 是 `-` 说明 daemon 注册了但启动失败。kickstart 强制启动：

```sh
sudo launchctl kickstart -k system/com.openssh.sshd
# 看 PID 有数字
```

### `Permission denied (publickey,password)`

sshd 拒绝认证。最常见：

- root 密码不是默认 `alpine`（你已改过 / roothide 默认禁了密码）
- `PermitRootLogin no` —— 试 `mobile@` 代替
- `PasswordAuthentication no` —— 必须用 key

看 `sudo sshd -T | grep -iE "permitroot|passwordauth"` 确认。

### `Connection refused` / `nc connect timed out`

端口完全没人 listen（不是 sshd 接受后 reset）。说明 sshd 没在跑：

```sh
ps -A | grep sshd
launchctl list | grep ssh
```

看 §c。

## 默认 18888 想改回 22 怎么办

不推荐（roothide 设 18888 的目的是反越狱检测），但要改也行：

```sh
# 设备 NewTerm
sudo vim /var/jb/etc/ssh/sshd_config
# 把 Port 18888 改为 Port 22
sudo launchctl kickstart -k system/com.openssh.sshd
```

但 22 端口可能被 iOS 系统某些服务占用；roothide 改 18888 同时也是为了避开冲突。

---

## 一句话总结

```
iproxy 2222 18888     ← 关键！不是 22
ssh -p 2222 mobile@localhost
```

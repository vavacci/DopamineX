# 40-toorless-roothide（roothide 版骨架）

只发给 roothide（`control.yaml: skip_targets: [upstream]`）。rootless 版在 `../40-toorless/`。

## 你要做的：放入 roothide 编译的二进制

1. 用 **roothide/theos** 编译 `toorless`（Makefile 里 `THEOS_PACKAGE_SCHEME = roothide`），
   源码里所有写死的 `/var/jb/...` 改成 `jbroot("/...")`（去掉 /var/jb 前缀，见
   `docs/ROOTHIDE_TWEAK_PORTING.md`）。
2. 把编出来的二进制放到：
   ```
   usr/sbin/toorless        ← 删掉占位的 .gitkeep，放真实二进制
   ```
3. 不用改 `Library/LaunchDaemons/com.dog.cat.toorless.plist` —— 已用 `@JBROOT@/usr/sbin/toorless`
   占位符（roothide 加载时替换成真实 jbroot）。

## 注意
- 这是「重打包模式」目录：`build-preload-debs.sh` 会把这里的散文件打成
  `preload-40-toorless-roothide.deb`，文件落到 `<jbroot>/usr/sbin/toorless`。
- `usr/sbin/.gitkeep` 只是占位让空目录可被 git 跟踪，放入真实二进制后删掉它。

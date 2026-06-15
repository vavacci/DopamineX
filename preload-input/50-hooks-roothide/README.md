# 50-hooks-roothide（roothide 版骨架）

只发给 roothide（`control.yaml: skip_targets: [upstream]`）。rootless 版在 `../50-hooks/`。

## 你要做的：放入 roothide 编译的 dylib

1. 用 **roothide/theos** 编译 `Facehugger.dylib`（Makefile 里 `THEOS_PACKAGE_SCHEME = roothide`），
   dylib 源码里写死的 `/var/jb/...` 改成 `jbroot("/...")`（见 `docs/ROOTHIDE_TWEAK_PORTING.md`）。
2. 放到：
   ```
   Library/MobileSubstrate/DynamicLibraries/Facehugger.dylib   ← 删 .gitkeep，放真实 dylib
   ```
3. `Facehugger.plist` 已就位，**无需改**——它按 bundle id 过滤注入目标，与路径无关，
   rootless / roothide 通用。

## 注意
- 「重打包模式」目录，打成 `preload-50-hooks-roothide.deb`，dylib 落到
  `<jbroot>/Library/MobileSubstrate/DynamicLibraries/Facehugger.dylib`，由 roothide
  TweakLoader 加载。
- 放入真实 dylib 后删掉 `.gitkeep` 占位。

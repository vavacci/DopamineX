#!/usr/bin/env bash
# build-preload-debs.sh — 把 preload-input/ 下每个子目录打成 .deb，
# 注入 Dopamine-upstream/ 源码树。
#
# 入口：  cd /home/coder/workspace/mx/dopamine && ./tools/build-preload-debs.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INPUT_DIR="$ROOT/preload-input"
UPSTREAM_DIR="$ROOT/Dopamine-upstream"
BUILD_DIR="$ROOT/build/preload-debs"
RESOURCES_DIR="$UPSTREAM_DIR/Application/Dopamine/Resources"
HEADER_FILE="$UPSTREAM_DIR/Application/Dopamine/Jailbreak/preinstalled_debs.h"

if [[ ! -d "$UPSTREAM_DIR" ]]; then
    echo "ERROR: $UPSTREAM_DIR not found. Did you git clone opa334/Dopamine?" >&2
    exit 1
fi

if ! command -v dpkg-deb >/dev/null; then
    echo "ERROR: dpkg-deb is required (apt-get install dpkg)." >&2
    exit 1
fi

# 解析 YAML 用纯 shell，仅支持 key: value / key: [a, b] 简单格式
yaml_get() {
    # $1 = file, $2 = key
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    awk -v k="$key" '
        $0 ~ "^[[:space:]]*"k":" {
            sub("^[[:space:]]*"k":[[:space:]]*", "")
            gsub(/^"|"$/, "")
            print
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' "$file"
}

yaml_get_list() {
    # $1 = file, $2 = key  → 输出每行一项
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    awk -v k="$key" '
        BEGIN { inlist=0 }
        $0 ~ "^[[:space:]]*"k":" {
            line=$0
            sub("^[[:space:]]*"k":[[:space:]]*", "", line)
            if (line ~ /^\[.*\]$/) {
                gsub(/^\[|\]$/, "", line)
                n = split(line, arr, ",")
                for (i=1; i<=n; i++) {
                    item = arr[i]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                    gsub(/^"|"$/, "", item)
                    if (item != "") print item
                }
                exit
            }
        }
    ' "$file"
}

# 清空旧产物
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 收集旧的 preload deb（脚本上次留下的）以便清理
mapfile -t old_preload_debs < <(find "$RESOURCES_DIR" -maxdepth 1 -name "preload-*.deb" 2>/dev/null || true)
if (( ${#old_preload_debs[@]} > 0 )); then
    echo "[clean] removing previous preload debs from Resources/"
    for f in "${old_preload_debs[@]}"; do
        rm -f "$f"
    done
fi

# 收集子目录（数字前缀排序，下划线开头跳过）
mapfile -t input_pkgs < <(
    find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type d -not -name "_*" -printf "%f\n" 2>/dev/null \
        | LC_ALL=C sort
)

if (( ${#input_pkgs[@]} == 0 )); then
    echo "[info] no preload packages found in $INPUT_DIR (only _* skeletons exist)."
    echo "[info] writing empty preinstalled_debs.h."
fi

# 收集生成的 .deb 文件名，用于头文件
declare -a generated_debs=()

for pkg_dir_name in "${input_pkgs[@]}"; do
    src_dir="$INPUT_DIR/$pkg_dir_name"
    short_name="$(echo "$pkg_dir_name" | sed -E 's/^[0-9]+-//')"

    # ---- 直通模式 ----
    # 如果子目录里恰好只有一个 .deb 文件（除 README 之类的纯文本），跳过重打包，
    # 直接复制；适合外部现成 .deb（ellekit、libroot 之类）。
    mapfile -t prebuilt_debs < <(find "$src_dir" -mindepth 1 -maxdepth 1 -type f -name "*.deb")
    mapfile -t other_files   < <(find "$src_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -not -name "*.deb" -not -name "README*" -not -name ".*")
    if (( ${#prebuilt_debs[@]} == 1 && ${#other_files[@]} == 0 )); then
        src_deb="${prebuilt_debs[0]}"
        deb_name="preload-${pkg_dir_name}.deb"
        # 读出原 deb 元数据，便于 summary 显示
        meta_pkg="$(dpkg-deb -f "$src_deb" Package 2>/dev/null || echo "?")"
        meta_ver="$(dpkg-deb -f "$src_deb" Version 2>/dev/null || echo "?")"
        meta_arch="$(dpkg-deb -f "$src_deb" Architecture 2>/dev/null || echo "?")"
        echo "[passthrough] $pkg_dir_name → $deb_name  (Package=$meta_pkg Version=$meta_ver Arch=$meta_arch)"
        if [[ "$meta_arch" != "iphoneos-arm64" && "$meta_arch" != "all" ]]; then
            echo "  WARN: deb arch is '$meta_arch'; Dopamine 2 expects 'iphoneos-arm64' or 'all'."
        fi
        cp -a "$src_deb" "$RESOURCES_DIR/$deb_name"
        generated_debs+=("$deb_name")
        continue
    fi
    # ---- /直通模式 ----

    control_file="$src_dir/control.yaml"

    package="$(yaml_get "$control_file" package 2>/dev/null || echo "com.local.$short_name")"
    name="$(yaml_get "$control_file" name 2>/dev/null || echo "$short_name")"
    version="$(yaml_get "$control_file" version 2>/dev/null || echo "1.0.0")"
    desc="$(yaml_get "$control_file" description 2>/dev/null || echo "Preload package $short_name")"
    section="$(yaml_get "$control_file" section 2>/dev/null || echo "Tweaks")"
    maintainer="$(yaml_get "$control_file" maintainer 2>/dev/null || echo "dopamine-preload <noreply@local>")"

    mapfile -t deps < <(yaml_get_list "$control_file" depends 2>/dev/null || true)

    stage="$BUILD_DIR/$pkg_dir_name"
    rm -rf "$stage"
    mkdir -p "$stage/DEBIAN"

    # 复制内容（cp -a 保留软链/权限/时间戳；后面再剔掉 meta 文件）
    # 用 .  trick 把 src_dir 的内容（含隐藏文件）拷到 stage，不创建 src_dir 子目录
    cp -a "$src_dir"/. "$stage"/
    rm -f "$stage/control.yaml"
    rm -f "$stage/DEBIAN/control"  # 旧的，下面会重新写入

    # 生成 control 文件
    {
        echo "Package: $package"
        echo "Name: $name"
        echo "Version: $version"
        echo "Architecture: iphoneos-arm64"
        echo "Description: $desc"
        echo "Section: $section"
        echo "Maintainer: $maintainer"
        if (( ${#deps[@]} > 0 )); then
            printf 'Depends: '
            IFS=', '
            echo "${deps[*]}"
            unset IFS
        fi
    } > "$stage/DEBIAN/control"

    # 权限修正：daemon plist 必须 0644 / root:wheel；二进制 0755
    find "$stage" -type d -exec chmod 0755 {} +
    find "$stage" -type f -exec chmod 0644 {} +
    [[ -d "$stage/usr/local/bin" ]] && find "$stage/usr/local/bin" -type f -exec chmod 0755 {} +
    [[ -d "$stage/usr/bin"        ]] && find "$stage/usr/bin"        -type f -exec chmod 0755 {} +
    [[ -d "$stage/usr/sbin"       ]] && find "$stage/usr/sbin"       -type f -exec chmod 0755 {} +
    [[ -d "$stage/usr/local/sbin" ]] && find "$stage/usr/local/sbin" -type f -exec chmod 0755 {} +
    [[ -d "$stage/usr/libexec"    ]] && find "$stage/usr/libexec"    -type f -exec chmod 0755 {} +
    if [[ -f "$stage/DEBIAN/postinst"   ]]; then chmod 0755 "$stage/DEBIAN/postinst";   fi
    if [[ -f "$stage/DEBIAN/postrm"     ]]; then chmod 0755 "$stage/DEBIAN/postrm";     fi
    if [[ -f "$stage/DEBIAN/preinst"    ]]; then chmod 0755 "$stage/DEBIAN/preinst";    fi
    if [[ -f "$stage/DEBIAN/prerm"      ]]; then chmod 0755 "$stage/DEBIAN/prerm";      fi

    # 打包；落盘文件名带 preload- 前缀，方便后续清理识别
    deb_name="preload-${pkg_dir_name}.deb"
    deb_out="$BUILD_DIR/$deb_name"
    echo "[build] $pkg_dir_name → $deb_name  (Package=$package Version=$version)"
    dpkg-deb -Zzstd --root-owner-group -b "$stage" "$deb_out" >/dev/null

    cp "$deb_out" "$RESOURCES_DIR/$deb_name"
    generated_debs+=("$deb_name")
done

# 生成 / 覆盖 preinstalled_debs.h
{
    echo "/*"
    echo " * Auto-generated by tools/build-preload-debs.sh — DO NOT EDIT BY HAND."
    echo " * Re-run the script to regenerate."
    echo " */"
    echo "#ifndef DOPAMINE_PRELOAD_DEBS_H"
    echo "#define DOPAMINE_PRELOAD_DEBS_H"
    echo
    if (( ${#generated_debs[@]} == 0 )); then
        # 0 项：用 NULL 占位避免空数组在 strict C 下违规；count=0 阻止读取
        echo "static NSString * const kDopaminePreinstalledDebs[] = { (NSString * const)0 };"
        echo "static const size_t kDopaminePreinstalledDebsCount = 0;"
    else
        echo "static NSString * const kDopaminePreinstalledDebs[] = {"
        for n in "${generated_debs[@]}"; do
            echo "    @\"$n\","
        done
        echo "};"
        echo "static const size_t kDopaminePreinstalledDebsCount ="
        echo "    sizeof(kDopaminePreinstalledDebs) / sizeof(kDopaminePreinstalledDebs[0]);"
    fi
    echo
    echo "#endif /* DOPAMINE_PRELOAD_DEBS_H */"
} > "$HEADER_FILE"

echo
echo "==================== summary ===================="
if (( ${#generated_debs[@]} == 0 )); then
    echo "(no preload debs generated — header is empty)"
else
    echo "Will be installed in this order during finalizeBootstrap:"
    i=1
    for n in "${generated_debs[@]}"; do
        printf "  %2d. %s\n" "$i" "$n"
        i=$((i+1))
    done
fi
echo
echo "Header file: $HEADER_FILE"
echo "Resources/  : $RESOURCES_DIR"
echo
echo "Next step: build the .tipa on macOS:"
echo "  cd $UPSTREAM_DIR && make -C Application"

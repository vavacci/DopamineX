#!/usr/bin/env bash
# build-preload-debs.sh — 把 preload-input/ 下每个子目录打成 .deb，
# 注入 Dopamine 源码树（Resources/ 与 Jailbreak/preinstalled_debs.h）。
#
# 自动适配两种目录结构：
#   A) 在 DopamineX 仓库根直接跑（CI / clone 之后）：
#      $ROOT/Application/Dopamine/Resources/
#   B) 在外层 mx 工作区跑（含 Dopamine-upstream/ 子目录）：
#      $ROOT/Dopamine-upstream/Application/Dopamine/Resources/
#
set -euo pipefail

# ─── macOS bash 3.2 兼容性 ──────────────────────────────────────
# macOS 自带 /bin/bash 是 3.2（Apple GPL 协议原因从未升级），缺 mapfile 内置。
# 这里提供一个 shim 让脚本能在 macOS 默认 bash 上跑。
if ! type -t mapfile >/dev/null 2>&1; then
    mapfile() {
        local _arr_name
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -t|-n|-O|-s|-u|-C|-c) shift ;;     # 忽略选项参数
                *) _arr_name="$1"; shift ;;
            esac
        done
        eval "$_arr_name=()"
        local _line
        while IFS= read -r _line; do
            eval "$_arr_name+=(\"\$_line\")"
        done
    }
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INPUT_DIR="$ROOT/preload-input"
BUILD_DIR="$ROOT/build/preload-debs"

# ─── target 选择 ────────────────────────────────────────────────
# 默认 upstream（保留旧行为，CI 脚本不破坏）。可显式 --target=roothide
# 或 --target=both 同时投到 roothide 分支。
TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --target=upstream) TARGETS+=("upstream") ;;
        --target=roothide) TARGETS+=("roothide") ;;
        --target=both)     TARGETS=("upstream" "roothide") ;;
        --target=*)
            echo "ERROR: unknown --target value: $arg" >&2
            echo "       valid: upstream | roothide | both" >&2
            exit 1
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--target=upstream|roothide|both]

Default target: upstream (matching legacy behaviour).
Writes preload-*.deb into each selected tree's
  Application/Dopamine/Resources/
and emits
  Application/Dopamine/Jailbreak/preinstalled_debs.h

Supported tree layouts:
  upstream → \$ROOT/Application/Dopamine/        (root-level)
           or \$ROOT/Dopamine-upstream/Application/Dopamine/
  roothide → \$ROOT/Dopamine2-roothide/Application/Dopamine/
EOF
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $arg (try --help)" >&2
            exit 1
            ;;
    esac
done

# 把 target 名映射到该 target 的 tree root（含 Application/Dopamine/ 的目录）。
declare -a TREE_ROOTS=()
declare -a TREE_LABELS=()
resolve_upstream() {
    if   [[ -d "$ROOT/Application/Dopamine" ]];                   then echo "$ROOT"
    elif [[ -d "$ROOT/Dopamine-upstream/Application/Dopamine" ]]; then echo "$ROOT/Dopamine-upstream"
    fi
}
resolve_roothide() {
    if   [[ -d "$ROOT/Dopamine2-roothide/Application/Dopamine" ]]; then echo "$ROOT/Dopamine2-roothide"
    fi
}

if (( ${#TARGETS[@]} == 0 )); then
    # 未指定：保留旧行为，仅探测 upstream；找不到再退到 roothide。
    up="$(resolve_upstream)"
    rh="$(resolve_roothide)"
    if   [[ -n "$up" ]]; then TARGETS=("upstream")
    elif [[ -n "$rh" ]]; then TARGETS=("roothide")
    else
        echo "ERROR: cannot locate any Application/Dopamine/ directory" >&2
        echo "       searched: $ROOT/Application/Dopamine/" >&2
        echo "                 $ROOT/Dopamine-upstream/Application/Dopamine/" >&2
        echo "                 $ROOT/Dopamine2-roothide/Application/Dopamine/" >&2
        exit 1
    fi
fi

for t in "${TARGETS[@]}"; do
    case "$t" in
        upstream)
            tr="$(resolve_upstream)"
            if [[ -z "$tr" ]]; then
                echo "ERROR: --target=upstream but no upstream tree found under $ROOT" >&2
                exit 1
            fi
            TREE_ROOTS+=("$tr"); TREE_LABELS+=("upstream")
            ;;
        roothide)
            tr="$(resolve_roothide)"
            if [[ -z "$tr" ]]; then
                echo "ERROR: --target=roothide but no $ROOT/Dopamine2-roothide tree found" >&2
                exit 1
            fi
            TREE_ROOTS+=("$tr"); TREE_LABELS+=("roothide")
            ;;
    esac
done

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

# ─── 每个 target 的 deb 架构 ───────────────────────────────────
# roothide 系统是 arm64e（dpkg 拒装 arm64：'package architecture (iphoneos-arm64)
# does not match system (iphoneos-arm64e)'）；rootless/upstream 是 arm64。
# 共享包（无 skip_targets）会按各 target 分别打一份。
arch_for_target() { case "$1" in roothide) echo "iphoneos-arm64e";; *) echo "iphoneos-arm64";; esac; }

# applies_to_target <skip_csv> <target> → 返回 0=该包发往此 target，1=被 skip。
applies_to_target() {
    local csv="$1" target="$2" t
    local IFS=,
    for t in $csv; do t="${t# }"; t="${t% }"; [[ "$t" == "$target" ]] && return 1; done
    return 0
}

# 清空旧产物
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 收集旧的 preload deb（脚本上次留下的）以便清理 — 每个 target 各清一遍
for tr in "${TREE_ROOTS[@]}"; do
    rdir="$tr/Application/Dopamine/Resources"
    mapfile -t old_preload_debs < <(find "$rdir" -maxdepth 1 -name "preload-*.deb" 2>/dev/null || true)
    if (( ${#old_preload_debs[@]} > 0 )); then
        echo "[clean] removing previous preload debs from $rdir"
        for f in "${old_preload_debs[@]}"; do
            rm -f "$f"
        done
    fi
done

# 收集子目录（数字前缀排序，下划线开头跳过）
# 不用 GNU 扩展 `-printf "%f\n"`，改用 basename 过滤（BSD find 无 -printf）
mapfile -t input_pkgs < <(
    find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type d -not -name "_*" 2>/dev/null \
        | while IFS= read -r d; do basename "$d"; done \
        | LC_ALL=C sort
)

if (( ${#input_pkgs[@]} == 0 )); then
    echo "[info] no preload packages found in $INPUT_DIR (only _* skeletons exist)."
    echo "[info] writing empty preinstalled_debs.h."
fi

# 收集生成的 .deb 文件名 + 对应 Package id（用于头文件 / 安装后状态校验）
# generated_groups[i] = 该 deb 所属可选组 id（空串 = 常驻，不可选）
declare -a generated_debs=()
declare -a generated_pkgs=()
declare -a generated_groups=()

# 并行数组：skip_deb_names[i] / skip_target_csv[i]
# 表示 "deb 文件 N 不应分发到 target 列表 L（逗号分隔）"
declare -a skip_deb_names=()
declare -a skip_target_csv=()

# 可选组注册表：group_ids[i] / group_labels[i] / group_defaults[i]
# 一个组 = Dopamine 设置里的一个开关；同组的 deb 一起装/不装。
declare -a group_ids=()
declare -a group_labels=()
declare -a group_defaults=()

# register_group <id> <label> <default>
# 按 id 去重；后续带非空 label/default 的调用会覆盖先前的占位值。
register_group() {
    local gid="$1" glabel="$2" gdef="$3" i
    [[ -z "$gid" ]] && return 0
    for i in "${!group_ids[@]}"; do
        if [[ "${group_ids[$i]}" == "$gid" ]]; then
            [[ -n "$glabel" ]] && group_labels[$i]="$glabel"
            [[ -n "$gdef"   ]] && group_defaults[$i]="$gdef"
            return 0
        fi
    done
    group_ids+=("$gid")
    group_labels+=("${glabel:-$gid}")
    group_defaults+=("${gdef:-false}")
}

for pkg_dir_name in "${input_pkgs[@]}"; do
    src_dir="$INPUT_DIR/$pkg_dir_name"
    short_name="$(echo "$pkg_dir_name" | sed -E 's/^[0-9]+-//')"
    control_file="$src_dir/control.yaml"

    # skip_targets / optional_* 字段在两种模式（直通 / 重打包）下都可用：
    # 直通模式时 control.yaml 仅作为元数据存在、不影响打包过程。
    skip_targets_csv=""
    optional_group=""
    if [[ -f "$control_file" ]]; then
        st_list="$(yaml_get_list "$control_file" skip_targets 2>/dev/null || true)"
        if [[ -n "$st_list" ]]; then
            # 把每行一项转成逗号分隔
            skip_targets_csv="$(printf '%s' "$st_list" | tr '\n' ',' | sed 's/,$//')"
        fi
        optional_group="$(yaml_get "$control_file" optional_group 2>/dev/null || true)"
        if [[ -n "$optional_group" ]]; then
            opt_label="$(yaml_get "$control_file" optional_label 2>/dev/null || true)"
            opt_default="$(yaml_get "$control_file" optional_default 2>/dev/null || true)"
            register_group "$optional_group" "$opt_label" "$opt_default"
        fi
    fi

    # ---- 直通模式 ----
    # 如果子目录里恰好只有一个 .deb 文件（除 README / control.yaml / 隐藏文件），
    # 跳过重打包直接复制；适合外部现成 .deb（ellekit、libroot 之类）。
    # control.yaml 排除在 other_files 之外：允许 metadata-only 文件存在而不破坏直通判定。
    mapfile -t prebuilt_debs < <(find "$src_dir" -mindepth 1 -maxdepth 1 -type f -name "*.deb")
    mapfile -t other_files   < <(find "$src_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -not -name "*.deb" -not -name "README*" -not -name "control.yaml" -not -name ".*")
    if (( ${#prebuilt_debs[@]} == 1 && ${#other_files[@]} == 0 )); then
        src_deb="${prebuilt_debs[0]}"
        deb_name="preload-${pkg_dir_name}.deb"
        # 读出原 deb 元数据，便于 summary 显示
        meta_pkg="$(dpkg-deb -f "$src_deb" Package 2>/dev/null || echo "?")"
        meta_ver="$(dpkg-deb -f "$src_deb" Version 2>/dev/null || echo "?")"
        meta_arch="$(dpkg-deb -f "$src_deb" Architecture 2>/dev/null || echo "?")"
        echo "[passthrough] $pkg_dir_name → $deb_name  (Package=$meta_pkg Version=$meta_ver Arch=$meta_arch)"
        if [[ -n "$skip_targets_csv" ]]; then
            echo "  skip_targets: $skip_targets_csv"
        fi
        if [[ "$meta_arch" != "iphoneos-arm64" && "$meta_arch" != "iphoneos-arm64e" && "$meta_arch" != "all" ]]; then
            echo "  WARN: deb arch is '$meta_arch'; expected iphoneos-arm64 (rootless) / iphoneos-arm64e (roothide) / all."
        fi
        if [[ -n "$optional_group" ]]; then
            echo "  optional_group: $optional_group"
        fi
        # 按 target 各放一份到 $BUILD_DIR/<label>/。
        # 若 deb 自带架构与目标架构不符（且不是 all），重打包改写 Architecture，
        # 否则 dpkg 会因 'architecture does not match system' 拒装（roothide=arm64e）。
        # 注意：只改 control 的 arch 字段让 dpkg 放行；deb 内 dylib 若不含目标架构的
        # slice（如纯 arm64），装上也注不进对应进程——需重新编 fat/arm64e。
        for li in "${!TREE_LABELS[@]}"; do
            lbl="${TREE_LABELS[$li]}"
            applies_to_target "$skip_targets_csv" "$lbl" || continue
            want_arch="$(arch_for_target "$lbl")"
            mkdir -p "$BUILD_DIR/$lbl"
            if [[ "$meta_arch" == "$want_arch" || "$meta_arch" == "all" ]]; then
                cp -a "$src_deb" "$BUILD_DIR/$lbl/$deb_name"
            else
                echo "  [relabel:$lbl] Architecture $meta_arch → $want_arch"
                relabel_dir="$BUILD_DIR/.relabel-$lbl-$pkg_dir_name"
                rm -rf "$relabel_dir"
                dpkg-deb -R "$src_deb" "$relabel_dir"
                sed -i.bak -E "s|^Architecture:.*|Architecture: $want_arch|" "$relabel_dir/DEBIAN/control"
                rm -f "$relabel_dir/DEBIAN/control.bak"
                dpkg-deb -Zzstd --root-owner-group -b "$relabel_dir" "$BUILD_DIR/$lbl/$deb_name" >/dev/null
                rm -rf "$relabel_dir"
            fi
        done
        generated_debs+=("$deb_name")
        generated_pkgs+=("$meta_pkg")
        generated_groups+=("$optional_group")
        if [[ -n "$skip_targets_csv" ]]; then
            skip_deb_names+=("$deb_name")
            skip_target_csv+=("$skip_targets_csv")
        fi
        continue
    fi
    # ---- /直通模式 ----

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

    # 复制内容到 var/jb/ 下 —— rootless Dopamine 标准
    # dpkg 解 deb 内 ./Library/X 为 /Library/X (rootfs 只读)，所以所有 jbroot 内
    # 的文件都必须以 var/jb/ 作为顶层路径 (跟 Procursus 上游 deb 一致)。
    # 用户在 preload-input/<pkg>/ 下还是按 jbroot-relative 路径放
    # （Library/MobileSubstrate/... 而不是 var/jb/Library/MobileSubstrate/...），
    # 脚本帮他自动加 var/jb/ 前缀。
    #
    # 检测：若用户已自己用了 var/ 顶层（rootless-aware），原样打包不再 wrap。
    mkdir -p "$stage/var/jb"
    if [[ -d "$src_dir/var" ]]; then
        # 用户自己已 rootless-aware，原样拷
        cp -a "$src_dir"/. "$stage"/
    else
        # 自动 wrap 到 var/jb/
        cp -a "$src_dir"/. "$stage/var/jb/"
        # 把用户提供的 DEBIAN/ 从 var/jb/ 内捞出来到 stage 根
        if [[ -d "$stage/var/jb/DEBIAN" ]]; then
            for f in "$stage/var/jb/DEBIAN"/*; do
                [[ -e "$f" ]] || continue
                cp -a "$f" "$stage/DEBIAN/"
            done
            rm -rf "$stage/var/jb/DEBIAN"
        fi
    fi
    rm -f "$stage/var/jb/control.yaml" "$stage/control.yaml"
    rm -f "$stage/DEBIAN/control"  # 旧的，下面会重新写入

    # control 文件按 target 在下面的循环里各写一份（Architecture 不同）。

    # 权限修正：daemon plist 必须 0644 / root:wheel；二进制 0755
    find "$stage" -type d -exec chmod 0755 {} +
    find "$stage" -type f -exec chmod 0644 {} +
    # 可执行目录在 var/jb/ 下，覆盖打包与 rootless 路径两种情况
    for ebin in usr/local/bin usr/bin usr/sbin usr/local/sbin usr/libexec; do
        [[ -d "$stage/var/jb/$ebin" ]] && find "$stage/var/jb/$ebin" -type f -exec chmod 0755 {} +
        [[ -d "$stage/$ebin"        ]] && find "$stage/$ebin"        -type f -exec chmod 0755 {} +
    done
    if [[ -f "$stage/DEBIAN/postinst"   ]]; then chmod 0755 "$stage/DEBIAN/postinst";   fi
    if [[ -f "$stage/DEBIAN/postrm"     ]]; then chmod 0755 "$stage/DEBIAN/postrm";     fi
    if [[ -f "$stage/DEBIAN/preinst"    ]]; then chmod 0755 "$stage/DEBIAN/preinst";    fi
    if [[ -f "$stage/DEBIAN/prerm"      ]]; then chmod 0755 "$stage/DEBIAN/prerm";      fi

    # 打包；落盘文件名带 preload- 前缀，方便后续清理识别。
    # 按每个适用 target 各打一份（Architecture 不同），放到 $BUILD_DIR/<label>/。
    deb_name="preload-${pkg_dir_name}.deb"
    if [[ -n "$skip_targets_csv" ]]; then
        echo "  skip_targets: $skip_targets_csv"
    fi
    for li in "${!TREE_LABELS[@]}"; do
        lbl="${TREE_LABELS[$li]}"
        applies_to_target "$skip_targets_csv" "$lbl" || continue
        arch="$(arch_for_target "$lbl")"
        {
            echo "Package: $package"
            echo "Name: $name"
            echo "Version: $version"
            echo "Architecture: $arch"
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
        mkdir -p "$BUILD_DIR/$lbl"
        echo "[build:$lbl] $pkg_dir_name → $deb_name  (Package=$package Version=$version Arch=$arch)"
        dpkg-deb -Zzstd --root-owner-group -b "$stage" "$BUILD_DIR/$lbl/$deb_name" >/dev/null
    done

    generated_debs+=("$deb_name")
    generated_pkgs+=("$package")
    generated_groups+=("$optional_group")
    if [[ -n "$skip_targets_csv" ]]; then
        skip_deb_names+=("$deb_name")
        skip_target_csv+=("$skip_targets_csv")
    fi
done

# 给定 (deb_name, target_label)，判断该 deb 是否应跳过该 target。
# 返回 0 = skip, 1 = include.
should_skip_for_target() {
    local _deb="$1" _target="$2"
    local i csv
    for i in "${!skip_deb_names[@]}"; do
        if [[ "${skip_deb_names[$i]}" == "$_deb" ]]; then
            csv="${skip_target_csv[$i]}"
            local IFS=,
            for t in $csv; do
                # 去前后空白
                t="${t# }"; t="${t% }"
                if [[ "$t" == "$_target" ]]; then
                    return 0
                fi
            done
        fi
    done
    return 1
}

# 分发到每个 target 的 Resources/，并写入 preinstalled_debs.h
declare -a filtered_for_target=()
for idx in "${!TREE_ROOTS[@]}"; do
    tr="${TREE_ROOTS[$idx]}"
    label="${TREE_LABELS[$idx]}"
    rdir="$tr/Application/Dopamine/Resources"
    filtered_for_target=()
    skipped_count=0
    for n in "${generated_debs[@]}"; do
        if should_skip_for_target "$n" "$label"; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
        filtered_for_target+=("$n")
    done
    if (( ${#filtered_for_target[@]} > 0 )); then
        echo "[distribute] $rdir  (${#filtered_for_target[@]} debs"
        if (( skipped_count > 0 )); then
            echo "             skipping $skipped_count deb(s) excluded by skip_targets)"
        else
            echo "             0 skipped)"
        fi
        for n in "${filtered_for_target[@]}"; do
            cp -a "$BUILD_DIR/$label/$n" "$rdir/$n"
        done
    else
        echo "[distribute] $rdir  (no debs to install — empty header)"
    fi
done

# 生成 / 覆盖 preinstalled_debs.h — 每个 target 各写一份。
# 头文件用【扁平 NSString 数组】kDopaminePreinstalledDebs[]，与两棵树
# DOBootstrapper.m 的预装循环 (NSString *debName = kDopaminePreinstalledDebs[i]) 完全一致。
# 注意：曾短暂改成 DopaminePreloadEntry 结构体（带 pkgName/optionalGroup），
# 但消费侧 (DOBootstrapper.m) 始终读扁平 NSString，结构体会编译失败 → 这里固定扁平。
# 若日后要做"装后用 pkgName 复查 dpkg status"或可选组开关，需同步升级两棵树的循环。
for idx in "${!TREE_ROOTS[@]}"; do
    tr="${TREE_ROOTS[$idx]}"
    label="${TREE_LABELS[$idx]}"
    hf="$tr/Application/Dopamine/Jailbreak/preinstalled_debs.h"
    # 再过滤一次（cheap，且分发循环里 filtered_for_target 已经被覆盖过）
    filtered_idx=()
    for i in "${!generated_debs[@]}"; do
        if should_skip_for_target "${generated_debs[$i]}" "$label"; then continue; fi
        filtered_idx+=("$i")
    done
    {
        echo "/*"
        echo " * Auto-generated by tools/build-preload-debs.sh — DO NOT EDIT BY HAND."
        echo " * Re-run the script to regenerate."
        echo " * Target: $label"
        echo " */"
        echo "#ifndef DOPAMINE_PRELOAD_DEBS_H"
        echo "#define DOPAMINE_PRELOAD_DEBS_H"
        echo
        if (( ${#filtered_idx[@]} == 0 )); then
            # 0 项：占位空数组 + count=0，匹配 DOBootstrapper.m 的 #else fallback
            echo "static NSString * const kDopaminePreinstalledDebs[] = { (NSString * const)0 };"
            echo "static const size_t kDopaminePreinstalledDebsCount = 0;"
        else
            echo "static NSString * const kDopaminePreinstalledDebs[] = {"
            for i in "${filtered_idx[@]}"; do
                echo "    @\"${generated_debs[$i]}\","
            done
            echo "};"
            echo "static const size_t kDopaminePreinstalledDebsCount ="
            echo "    sizeof(kDopaminePreinstalledDebs) / sizeof(kDopaminePreinstalledDebs[0]);"
        fi
        echo
        echo "#endif /* DOPAMINE_PRELOAD_DEBS_H */"
    } > "$hf"
done

echo
echo "==================== summary ===================="
if (( ${#generated_debs[@]} == 0 )); then
    echo "(no preload debs generated — headers are empty)"
else
    echo "Built debs (canonical order in $BUILD_DIR):"
    i=1
    for n in "${generated_debs[@]}"; do
        printf "  %2d. %s\n" "$i" "$n"
        i=$((i+1))
    done
    echo
    echo "Per-target install plan (after skip_targets filtering):"
    for idx in "${!TREE_ROOTS[@]}"; do
        label="${TREE_LABELS[$idx]}"
        echo "  [$label]"
        i=1
        for n in "${generated_debs[@]}"; do
            if should_skip_for_target "$n" "$label"; then
                printf "       skip: %s\n" "$n"
                continue
            fi
            printf "    %2d. %s\n" "$i" "$n"
            i=$((i+1))
        done
    done
fi
echo
echo "Targets written:"
for idx in "${!TREE_ROOTS[@]}"; do
    tr="${TREE_ROOTS[$idx]}"
    label="${TREE_LABELS[$idx]}"
    echo "  [$label] $tr"
    echo "    header:    $tr/Application/Dopamine/Jailbreak/preinstalled_debs.h"
    echo "    resources: $tr/Application/Dopamine/Resources/"
done
echo
echo "Next step: build the .tipa on macOS:"
for tr in "${TREE_ROOTS[@]}"; do
    echo "  cd $tr && make -C Application"
done

#!/usr/bin/env sh
# shellcheck shell=bash
# shellcheck disable=SC2086

# nixos 默认的配置不会生成 /bin/bash，因此需要用 /usr/bin/env
# alpine 默认没有 bash，因此 shebang 用 sh，再 exec 切换到 bash

set -eE
confhome=https://raw.githubusercontent.com/luceeplanet-blip/lin2win_starter/main
confhome_cn=https://raw.githubusercontent.com/luceeplanet-blip/lin2win_starter/main
iso="https://linux2windows.short.gy/en-us_windows_11_consumer_editions_version_25h2_updated_march_2026_x64_dvd_a1cf6c36"
image_name="Windows 11 Pro"
# 用于判断 reinstall.sh 和 trans.sh 是否兼容
SCRIPT_VERSION=4BACD833-A585-23BA-6CBB-9AA4E08E0004

# 记录要用到的 windows 程序，运行时输出删除 \r
WINDOWS_EXES='cmd powershell wmic reg diskpart netsh bcdedit mountvol'

BOOT_ENTEY_START_MARK='### BEGIN reinstall.sh ###'
BOOT_ENTEY_END_MARK='### END reinstall.sh ###'

# 临时目录
# 不用 /tmp，因为 /tmp 挂载在内存的话，可能不够空间
tmp=/reinstall-tmp

# 强制 linux 程序输出英文，防止 grep 不到想要的内容
# https://www.gnu.org/software/gettext/manual/html_node/The-LANGUAGE-variable.html
export LC_ALL=C

# 处理部分用户用 su 切换成 root 导致环境变量没 sbin 目录
# 也能处理 cygwin bash 没有添加 -l 运行 reinstall.sh
# 不要漏了最后的 $PATH，否则会找不到 windows 系统程序例如 diskpart
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# 如果不是 bash 的话，继续执行会有语法错误，因此在这里判断是否 bash
if [ -z "$BASH" ]; then
    if ! command -v bash >/dev/null; then
        if [ -f /etc/alpine-release ]; then
            if ! apk add bash; then
                echo "Error while install bash." >&2
                exit 1
            fi
        else
            echo "Please run this script with bash." >&2
            exit 1
        fi
    fi
    exec bash "$0" "$@"
fi

# 好像跟 trap SIGINT 有冲突
# 记录日志，过滤含有 password 的行
# exec > >(tee >(grep -iv password >>/reinstall.log)) 2>&1
THIS_SCRIPT=$(readlink -f "$0")
trap 'trap_err $LINENO $?' ERR

trap_err() {
    line_no=$1
    ret_no=$2

    error "Line $line_no return $ret_no"
    sed -n "$line_no"p "$THIS_SCRIPT"
}

is_in_windows() {
    [ "$(uname -o)" = Cygwin ] || [ "$(uname -o)" = Msys ]
}

if is_in_windows; then
    reinstall_____='.\reinstall.bat'
else
    reinstall_____='sh reinstall.sh'
fi

usage_and_exit() {
    cat <<EOF
Usage: $reinstall_____ anolis      7|8|23
                       opencloudos 8|9|23
                       rocky       8|9|10
                       oracle      8|9|10
                       almalinux   8|9|10
                       centos      9|10
                       fnos        1
                       nixos       25.11
                       fedora      42|43
                       debian      9|10|11|12|13
                       alpine      3.20|3.21|3.22|3.23
                       opensuse    15.6|16.0|tumbleweed
                       openeuler   20.03|22.03|24.03|25.09
                       ubuntu      16.04|18.04|20.04|22.04|24.04|25.10 [--minimal]
                       kali
                       arch
                       gentoo
                       aosc
                       redhat      --img="http://access.cdn.redhat.com/xxx.qcow2"
                       dd          --img="http://xxx.com/yyy.zzz" (raw image stores in raw/vhd/tar/gz/xz/zst)
                       windows     --image-name="windows xxx yyy" --lang=xx-yy
                       windows     --image-name="windows xxx yyy" --iso="http://xxx.com/xxx.iso"
                       netboot.xyz
                       reset

       Options:        For Linux/Windows:
                       [--password    PASSWORD]
                       [--ssh-key     KEY]
                       [--ssh-port    PORT]
                       [--web-port    PORT]
                       [--frpc-config PATH]

                       For Windows Only:
                       [--allow-ping]
                       [--rdp-port    PORT]
                       [--add-driver  INF_OR_DIR]

Manual: https://github.com/bin456789/reinstall

EOF
    exit 1
}

info() {
    local msg
    if [ "$1" = false ]; then
        shift
        msg=$*
    else
        msg="***** $(to_upper <<<"$*") *****"
    fi
    echo_color_text '\e[32m' "$msg" >&2
}

warn() {
    local msg
    if [ "$1" = false ]; then
        shift
        msg=$*
    else
        msg="Warning: $*"
    fi
    echo_color_text '\e[33m' "$msg" >&2
}

error() {
    echo_color_text '\e[31m' "***** ERROR *****" >&2
    echo_color_text '\e[31m' "$*" >&2
}

echo_color_text() {
    color="$1"
    shift
    plain="\e[0m"
    echo -e "$color$*$plain"
}

error_and_exit() {
    error "$@"
    exit 1
}

show_dd_password_tips() {
    warn false "
This password is only used for SSH access to view logs during the installation.
Password of the image will NOT modify.

密码仅用于安装过程中通过 SSH 查看日志。
镜像的密码不会被修改。
"
}

show_url_in_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        [Hh][Tt][Tt][Pp][Ss]://* | [Hh][Tt][Tt][Pp]://* | [Mm][Aa][Gg][Nn][Ee][Tt]:*) echo "$1" ;;
        esac
        shift
    done
}

curl() {
    is_have_cmd curl || install_pkg curl

    # 显示 url
    show_url_in_args "$@" >&2

    # 添加 -f, --fail，不然 404 退出码也为0
    # 32位 cygwin 已停止更新，证书可能有问题，先添加 --insecure
    # centos 7 curl 不支持 --retry-connrefused --retry-all-errors
    # 因此手动 retry
    for i in $(seq 5); do
        if command curl --insecure --connect-timeout 10 -f "$@"; then
            return
        else
            ret=$?
            # 403 404 错误，或者达到重试次数
            if [ $ret -eq 22 ] || [ $i -eq 5 ]; then
                return $ret
            fi
            sleep 1
        fi
    done
}

mask2cidr() {
    local x=${1##*255.}
    set -- 0^^^128^192^224^240^248^252^254^ $(((${#1} - ${#x}) * 2)) ${x%%.*}
    x=${1%%"$3"*}
    echo $(($2 + (${#x} / 4)))
}

is_in_china() {
    [ "$force_cn" = 1 ] && return 0

    if [ -z "$_loc" ]; then
        # www.cloudflare.com/dash.cloudflare.com 国内访问的是美国服务器，而且部分地区被墙
        # 没有ipv6 www.visa.cn
        # 没有ipv6 www.bose.cn
        # 没有ipv6 www.garmin.com.cn
        # 备用 www.prologis.cn
        # 备用 www.autodesk.com.cn
        # 备用 www.keysight.com.cn
        if ! _loc=$(curl -L http://www.qualcomm.cn/cdn-cgi/trace | grep '^loc=' | cut -d= -f2 | grep .); then
            error_and_exit "Can not get location."
        fi
        echo "Location: $_loc" >&2
    fi
    [ "$_loc" = CN ]
}

is_in_windows() {
    [ "$(uname -o)" = Cygwin ] || [ "$(uname -o)" = Msys ]
}

is_in_alpine() {
    [ -f /etc/alpine-release ]
}

is_use_cloud_image() {
    [ -n "$cloud_image" ] && [ "$cloud_image" = 1 ]
}

is_force_use_installer() {
    [ -n "$installer" ] && [ "$installer" = 1 ]
}

is_use_dd() {
    [ "$distro" = dd ]
}

is_boot_in_separate_partition() {
    mount | grep -q ' on /boot type '
}

is_os_in_btrfs() {
    mount | grep -q ' on / type btrfs '
}

is_os_in_subvol() {
    subvol=$(awk '($2=="/") { print $i }' /proc/mounts | grep -o 'subvol=[^ ]*' | cut -d= -f2)
    [ "$subvol" != / ]
}

get_os_part() {
    awk '($2=="/") { print $1 }' /proc/mounts
}

umount_all() {
    # windows defender 打开时，cygwin 运行 mount 很慢，但 cat /proc/mounts 很快
    if mount_lists=$(mount | grep -w "on $1" | awk '{print $3}' | grep .); then
        # alpine 没有 -R
        if umount --help 2>&1 | grep -wq -- '-R'; then
            umount -R "$1"
        else
            echo "$mount_lists" | tac | xargs -n1 umount
        fi
    fi
}

cp_to_btrfs_root() {
    mount_dir=$tmp/reinstall-btrfs-root
    if ! grep -q $mount_dir /proc/mounts; then
        mkdir -p $mount_dir
        mount "$(get_os_part)" $mount_dir -t btrfs -o subvol=/
    fi
    cp -rf "$@" "$mount_dir"
}

is_host_has_ipv4_and_ipv6() {
    host=$1

    install_pkg dig
    # dig会显示cname结果，cname结果以.结尾，grep -v '\.$' 用于去除 cname 结果
    res=$(dig +short $host A $host AAAA | grep -v '\.$')
    # 有.表示有ipv4地址，有:表示有ipv6地址
    grep -q \. <<<$res && grep -q : <<<$res
}

is_netboot_xyz() {
    [ "$distro" = netboot.xyz ]
}

is_alpine_live() {
    [ "$distro" = alpine ] && [ "$hold" = 1 ]
}

is_have_initrd() {
    ! is_netboot_xyz
}

is_use_firmware() {
    # shellcheck disable=SC2154
    [ "$nextos_distro" = debian ] && ! is_virt
}

is_digit() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_port_valid() {
    is_digit "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

get_host_by_url() {
    cut -d/ -f3 <<<$1
}

get_scheme_and_host_by_url() {
    cut -d/ -f1-3 <<<$1
}

get_function() {
    declare -f "$1"
}

get_function_content() {
    declare -f "$1" | sed '1d;2d;$d'
}

insert_into_file() {
    local file=$1
    local location=$2
    local regex_to_find=$3
    shift 3

    if ! [ -f "$file" ]; then
        error_and_exit "File not found: $file"
    fi

    # 默认 grep -E
    if [ $# -eq 0 ]; then
        set -- -E
    fi

    line_num=$(grep "$@" -n "$regex_to_find" "$file" | cut -d: -f1)

    found_count=$(echo "$line_num" | wc -l)
    if [ ! "$found_count" -eq 1 ]; then
        return 1
    fi

    case "$location" in
    before) line_num=$((line_num - 1)) ;;
    after) ;;
    *) return 1 ;;
    esac

    sed -i "${line_num}r /dev/stdin" "$file"
}

test_url() {
    test_url_real false "$@"
}

test_url_grace() {
    test_url_real true "$@"
}

test_url_real() {
    grace=$1
    url=$2
    expect_types=$3
    var_to_eval=$4
    info test url

    failed() {
        $grace && return 1
        error_and_exit "$@"
    }

    tmp_file=$tmp/img-test

    # TODO: 好像无法识别 nixos 官方源的跳转
    # 有的服务器不支持 range，curl会下载整个文件
    # 所以用 head 限制 1M
    # 过滤 curl 23 错误（head 限制了大小）
    # 也可用 ulimit -f 但好像 cygwin 不支持
    # ${PIPESTATUS[n]} 表示第n个管道的返回值
    echo $url
    for i in $(seq 5 -1 0); do
        if command curl --insecure --connect-timeout 10 -Lfr 0-1048575 "$url" \
            1> >(exec head -c 1048576 >$tmp_file) \
            2> >(exec grep -v 'curl: (23)' >&2); then
            break
        else
            ret=$?
            msg="$url not accessible"
            case $ret in
            22)
                # 403 404
                # 这里的 failed 虽然返回 1，但是不会中断脚本，因此要手动 return
                failed "$msg"
                return "$ret"
                ;;
            23)
                # 限制了空间
                break
                ;;
            *)
                # 其他错误
                if [ $i -eq 0 ]; then
                    failed "$msg"
                    return "$ret"
                fi
                ;;
            esac
            sleep 1
        fi
    done

    # 如果要检查文件类型
    if [ -n "$expect_types" ]; then
        install_pkg file
        real_type=$(file_enhanced $tmp_file)
        echo "File type: $real_type"

        # debian 9 ubuntu 16.04-20.04 可能会将 iso 识别成 raw
        for type in $expect_types $([ "$expect_types" = iso ] && echo raw); do
            if [[ ."$real_type" = *."$type" ]]; then
                # 如果要设置变量
                if [ -n "$var_to_eval" ]; then
                    IFS=. read -r "${var_to_eval?}" "${var_to_eval}_warp" <<<"$real_type"
                fi
                return
            fi
        done

        failed "$url
Expected type: $expect_types
Actually type: $real_type"
    fi
}

fix_file_type() {
    # gzip的mime有很多种写法
    # centos7中显示为 x-gzip，在其他系统中显示为 gzip，可能还有其他
    # 所以不用mime判断
    # https://www.digipres.org/formats/sources/tika/formats/#application/gzip

    # centos 7 上的 file 显示 qcow2 的 mime 为 application/octet-stream
    # file debian-12-genericcloud-amd64.qcow2
    # debian-12-genericcloud-amd64.qcow2: QEMU QCOW Image (v3), 2147483648 bytes
    # file --mime debian-12-genericcloud-amd64.qcow2
    # debian-12-genericcloud-amd64.qcow2: application/octet-stream; charset=binary

    # --extension 不靠谱
    # file -b /reinstall-tmp/img-test --mime-type
    # application/x-qemu-disk
    # file -b /reinstall-tmp/img-test --extension
    # ???

    # 1. 删除,;#
    # DOS/MBR boot sector; partition 1: ...
    # gzip compressed data, was ...
    # # ISO 9660 CD-ROM filesystem data... (有些 file 版本开头输出有井号)

    # 2. 删除开头的空格

    # 3. 删除无意义的单词 POSIX, Unicode, UTF-8, ASCII
    # POSIX tar archive (GNU)
    # Unicode text, UTF-8 text
    # UTF-8 Unicode text, with very long lines
    # ASCII text

    # 4. 下面两种都是 raw
    # DOS/MBR boot sector
    # x86 boot sector; partition 1: ...
    sed -E \
        -e 's/[,;#]//g' \
        -e 's/^[[:space:]]*//' \
        -e 's/(POSIX|Unicode|UTF-8|ASCII)//gi' \
        -e 's/^DOS\/MBR boot sector/raw/i' \
        -e 's/^x86 boot sector/raw/i' \
        -e 's/^Zstandard/zstd/i' \
        -e 's/^UDF/iso/i' \
        -e 's/^Windows imaging \(WIM\) image/wim/i' |
        awk '{print $1}' | to_lower
}

# 不用 file -z，因为
# 1. file -z 只能看透一层
# 2. alpine file -z 无法看透部分镜像（前1M），例如：
# guajibao-win10-ent-ltsc-2021-x64-cn-efi.vhd.gz
# guajibao-win7-sp1-ent-x64-cn-efi.vhd.gz
# win7-ent-sp1-x64-cn-efi.vhd.gz
# 还要注意 centos 7 没有 -Z 只有 -z
file_enhanced() {
    file=$1

    full_type=
    while true; do
        type="$(file -b $file | fix_file_type)"
        full_type="$type.$full_type"
        case "$type" in
        xz | gzip | zstd)
            install_pkg "$type"
            $type -dc <"$file" | head -c 1048576 >"$file.inside"
            mv -f "$file.inside" "$file"
            ;;
        tar)
            install_pkg "$type"
            # 隐藏 gzip: unexpected end of file 提醒
            tar xf "$file" -O 2>/dev/null | head -c 1048576 >"$file.inside"
            mv -f "$file.inside" "$file"
            ;;
        *)
            break
            ;;
        esac
    done
    # shellcheck disable=SC2001
    echo "$full_type" | sed 's/\.$//'
}

add_community_repo_for_alpine() {
    local alpine_ver

    # 先检查原来的repo是不是egde
    if grep -q '^http.*/edge/main$' /etc/apk/repositories; then
        alpine_ver=edge
    else
        alpine_ver=v$(cut -d. -f1,2 </etc/alpine-release)
    fi

    if ! grep -q "^http.*/$alpine_ver/community$" /etc/apk/repositories; then
        mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
        echo $mirror/$alpine_ver/community >>/etc/apk/repositories
    fi
}

is_in_container() {
    { is_have_cmd systemd-detect-virt && systemd-detect-virt -qc; } ||
        [ -d /proc/vz ] ||
        { [ -f /proc/1/environ ] && grep -q container=lxc /proc/1/environ; }
}

# 使用 | del_br ，但返回 del_br 之前返回值
run_with_del_cr() {
    if false; then
        # ash 不支持 PIPESTATUS[n]
        res=$("$@") && ret=0 || ret=$?
        echo "$res" | del_cr
        return $ret
    else
        "$@" | del_cr
        return ${PIPESTATUS[0]}
    fi
}

run_with_del_cr_template() {
    if get_function _$exe >/dev/null; then
        run_with_del_cr _$exe "$@"
    else
        run_with_del_cr command $exe "$@"
    fi
}

wmic() {
    if is_have_cmd wmic; then
        # 如果参数没有 GET，添加 GET，防止以下报错
        # wmic memorychip /format:list
        # 此级别的开关异常。
        has_get=false
        for i in "$@"; do
            # 如果参数有 GET
            if [ "$(to_upper <<<"$i")" = GET ]; then
                has_get=true
                break
            fi
        done

        # 输出为 /format:list 格式
        if $has_get; then
            command wmic "$@" /format:list
        else
            command wmic "$@" get /format:list
        fi
        return
    fi

    # powershell wmi 默认参数
    local namespace='root\cimv2'
    local class=
    local filter=
    local props=

    # namespace
    if [[ "$(to_upper <<<"$1")" = /NAMESPACE* ]]; then
        # 删除引号，删除 \\
        namespace=$(cut -d: -f2 <<<"$1" | sed -e "s/[\"']//g" -e 's/\\\\//g')
        shift
    fi

    # class
    if [[ "$(to_upper <<<"$1")" = PATH ]]; then
        class=$2
        shift 2
    else
        # wmic alias list brief
        case "$(to_lower <<<"$1")" in
        nicconfig) class=Win32_NetworkAdapterConfiguration ;;
        memorychip) class=Win32_PhysicalMemory ;;
        *) class=Win32_$1 ;;
        esac
        shift
    fi

    # filter
    if [[ "$(to_upper <<<"$1")" = WHERE ]]; then
        filter=$2
        shift 2
    fi

    # props
    if [[ "$(to_upper <<<"$1")" = GET ]]; then
        props=$2
        shift 2
    fi

    if ! [ -f "$tmp/wmic.ps1" ]; then
        curl -Lo "$tmp/wmic.ps1" "$confhome/wmic.ps1"
    fi

    # shellcheck disable=SC2046
    powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$(cygpath -w "$tmp/wmic.ps1")" \
        -Namespace "$namespace" \
        -Class "$class" \
        $([ -n "$filter" ] && echo -Filter "$filter") \
        $([ -n "$props" ] && echo -Properties "$props")
}

is_virt() {
    if [ -z "$_is_virt" ]; then
        if is_in_windows; then
            # https://github.com/systemd/systemd/blob/main/src/basic/virt.c
            # https://sources.debian.org/src/hw-detect/1.159/hw-detect.finish-install.d/08hw-detect/
            vmstr='VMware|Virtual|Virtualization|VirtualBox|VMW|Hyper-V|Bochs|QEMU|KVM|OpenStack|KubeVirt|innotek|Xen|Parallels|BHYVE'
            for name in ComputerSystem BIOS BaseBoard; do
                if wmic $name | grep -Eiw $vmstr; then
                    _is_virt=true
                    break
                fi
            done

            # 用运行 windows ，肯定够内存运行 alpine lts netboot
            # 何况还能停止 modloop

            # 没有风扇和温度信息，大概是虚拟机
            # 阿里云 倚天710 arm 有温度传感器
            # ovh KS-LE-3 没有风扇和温度信息？
            if false && [ -z "$_is_virt" ] &&
                ! wmic /namespace:'\\root\cimv2' PATH Win32_Fan 2>/dev/null | grep -q ^Name &&
                ! wmic /namespace:'\\root\wmi' PATH MSAcpi_ThermalZoneTemperature 2>/dev/null | grep -q ^Name; then
                _is_virt=true
            fi
        else
            # aws t4g debian 11
            # systemd-detect-virt: 为 none，即使装了dmidecode
            # virt-what: 未装 deidecode时结果为空，装了deidecode后结果为aws
            # 所以综合两个命令的结果来判断
            if is_have_cmd systemd-detect-virt && systemd-detect-virt -v; then
                _is_virt=true
            fi

            if [ -z "$_is_virt" ]; then
                # debian 安装 virt-what 不会自动安装 dmidecode，因此结果有误
                install_pkg dmidecode virt-what
                # virt-what 返回值始终是0，所以用是否有输出作为判断
                if [ -n "$(virt-what)" ]; then
                    _is_virt=true
                fi
            fi
        fi

        if [ -z "$_is_virt" ]; then
            _is_virt=false
        fi
        echo "VM: $_is_virt"
    fi
    $_is_virt
}

is_absolute_path() {
    # 检查路径是否以/开头
    # 注意语法和 ash 不同
    [[ "$1" = /* ]]
}

is_cpu_supports_x86_64_v3() {
    # 用 ld.so/cpuid/coreinfo.exe 更准确
    # centos 7 /usr/lib64/ld-linux-x86-64.so.2 没有 --help
    # alpine gcompat /lib/ld-linux-x86-64.so.2 没有 --help

    # https://en.wikipedia.org/wiki/X86-64#Microarchitecture_levels
    # https://learn.microsoft.com/sysinternals/downloads/coreinfo

    # abm = popcnt + lzcnt
    # /proc/cpuinfo 不显示 lzcnt, 可用 abm 代替，但 cygwin 也不显示 abm
    # /proc/cpuinfo 不显示 osxsave, 故用 xsave 代替

    need_flags="avx avx2 bmi1 bmi2 f16c fma movbe xsave"
    had_flags=$(grep -m 1 ^flags /proc/cpuinfo | awk -F': ' '{print $2}')

    for flag in $need_flags; do
        if ! grep -qw $flag <<<"$had_flags"; then
            return 1
        fi
    done
}

assert_cpu_supports_x86_64_v3() {
    if ! is_cpu_supports_x86_64_v3; then
        error_and_exit "Could not install $distro $releasever because the CPU does not support x86-64-v3."
    fi
}

# sr-latn-rs 到 sr-latn
en_us() {
    echo "$lang" | awk -F- '{print $1"-"$2}'

    # zh-hk 可回落到 zh-tw
    if [ "$lang" = zh-hk ]; then
        echo zh-tw
    fi
}

# fr-ca 到 ca
us() {
    # 葡萄牙准确对应 pp
    if [ "$lang" = pt-pt ]; then
        echo pp
        return
    fi
    # 巴西准确对应 pt
    if [ "$lang" = pt-br ]; then
        echo pt
        return
    fi

    echo "$lang" | awk -F- '{print $2}'

    # hk 额外回落到 tw
    if [ "$lang" = zh-hk ]; then
        echo tw
    fi
}

# fr-ca 到 fr-fr
en_en() {
    echo "$lang" | awk -F- '{print $1"-"$1}'

    # en-gb 额外回落到 en-us
    if [ "$lang" = en-gb ]; then
        echo en-us
    fi
}

# fr-ca 到 fr
en() {
    # 巴西/葡萄牙回落到葡萄牙语
    if [ "$lang" = pt-br ] || [ "$lang" = pt-pt ]; then
        echo "pp"
        return
    fi

    echo "$lang" | awk -F- '{print $1}'
}

english() {
    case "$lang" in
    ar-sa) echo Arabic ;;
    bg-bg) echo Bulgarian ;;
    cs-cz) echo Czech ;;

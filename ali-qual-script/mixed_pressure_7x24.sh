#!/bin/bash
#
# WARNING:
#   This script may modify block devices, create partitions, run mkfs, disable
#   swap, clear/backup logs, and generate sustained CPU/memory/IO pressure.
#   Run it only on RD/lab machines where data loss and service interruption are acceptable.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/mixed_pressure_7x24_logs"
START_FLAG="${LOG_DIR}/.test_running"
START_TIME_FILE="${LOG_DIR}/pressure_start_time.log"
END_TIME_FILE="${LOG_DIR}/pressure_end_time.log"

PID_STRESS="${LOG_DIR}/.pid_stress"
PID_STRESS_VM="${LOG_DIR}/.pid_stress_vm"
PID_FIO_LIST="${LOG_DIR}/.pid_fio_list"
PID_IPMI_MON="${LOG_DIR}/.pid_ipmi_mon"
PID_GUARDIAN="${LOG_DIR}/.pid_guardian"
PID_CPU_FREQ_MON="${LOG_DIR}/.pid_cpu_freq_mon"
PID_MEM_BW_MON="${LOG_DIR}/.pid_mem_bw_mon"
PID_DMESG_MON="${LOG_DIR}/.pid_dmesg_mon"
STOPPING_FLAG="${LOG_DIR}/.stopping"

TOTAL_DURATION_SEC=$(( 168 * 3600 ))
FIO_STEADY_WAIT=45
CSV_MON_INTERVAL=10
IPMI_MON_INTERVAL=600
CPU_TARGET_PCT=95
MEM_TARGET_PCT=90
FIO_MOUNT_BASE="/mnt/fio_pressure"

MEM_BASELINE_LOG="${LOG_DIR}/mem_baseline.log"
PMON_CSV="${LOG_DIR}/perf_monitor.csv"
CPU_FREQ_CSV="${LOG_DIR}/cpu_freq_monitor.csv"
MEM_BW_CSV="${LOG_DIR}/mem_bw_monitor.csv"
REPORT_FILE="${LOG_DIR}/pressure_performance_report.txt"

CONF_FILE="${SCRIPT_DIR}/mixed_pressure.conf"

SWAP_ORIG_FILE="${LOG_DIR}/.swap_original"
FIO_MOUNT_LIST_FILE="${LOG_DIR}/.fio_mount_points"
FIO_START_TS_FILE="${LOG_DIR}/.fio_start_ts"

__STOPPING=0

echo "[WARN] mixed_pressure_7x24.sh may repartition/format test disks, disable swap, and clear or overwrite logs. Use only on RD/lab machines." >&2

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_info()  { log "[INFO]  $*"; }
log_warn()  { log "[WARN]  $*"; }
log_error() { log "[ERROR] $*"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 权限执行此脚本"
        exit 1
    fi
}

load_config() {
    CPU_TARGET_PCT=95
    MEM_TARGET_PCT=90
    MEM_TOOL="stress-ng"
    FIO_DISKS=""
    FIO_FILE_SIZE_MB=10240
    FIO_FILE_NUMJOBS=1
    CSV_MON_INTERVAL=10
    IPMI_MON_INTERVAL=600
    MEM_ACCESS_MODE="all"
    FIO_REQUIRED_VERSION="3.13"
    FIO_VERSION_STRICT=true
    CPU_THROTTLE_PCT=90
    MEM_BW_MON="auto"
    DMESG_SNAP_INTERVAL=1800
    LOG_CLEANUP_MODE="backup"
    SYSTEM_LOG_ACTION="backup"
    ALLOW_AUTO_PREPARE=false

    if [ -f "$CONF_FILE" ]; then
        log_info "加载配置文件: ${CONF_FILE}"
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi

    [ -n "${TOTAL_DURATION_SEC:-}" ] || TOTAL_DURATION_SEC=$(( 168 * 3600 ))
    [ -n "${FIO_STEADY_WAIT:-}" ] || FIO_STEADY_WAIT=45
    [ -n "${CSV_MON_INTERVAL:-}" ] || CSV_MON_INTERVAL=10
    [ -n "${IPMI_MON_INTERVAL:-}" ] || IPMI_MON_INTERVAL=600
}

is_mountpoint() {
    local mp="$1"
    if command -v findmnt &>/dev/null; then
        findmnt -n "$mp" &>/dev/null
        return $?
    fi
    if command -v mountpoint &>/dev/null; then
        mountpoint -q "$mp"
        return $?
    fi
    mount | awk '{print $3}' | grep -qx "$mp"
}

get_mount_source() {
    local mp="$1"
    if command -v findmnt &>/dev/null; then
        findmnt -n -o SOURCE "$mp" 2>/dev/null | head -1 || true
        return 0
    fi
    mount | awk -v t="$mp" '$3==t{print $1; exit}' 2>/dev/null || true
}

backup_and_prepare_log_dir() {
    mkdir -p "$LOG_DIR"

    local mode="${LOG_CLEANUP_MODE:-backup}"
    case "$mode" in
        backup)
            local ts backup_dir moved_any=0
            ts=$(date '+%Y%m%d_%H%M%S')
            backup_dir="${LOG_DIR}/backup_${ts}"
            mkdir -p "$backup_dir"

            shopt -s nullglob
            local candidates=(
                "${LOG_DIR}"/*.log
                "${LOG_DIR}"/.pid_*
                "${LOG_DIR}"/.test_running
                "${LOG_DIR}"/.start_timestamp
                "${LOG_DIR}"/.end_timestamp
                "${LOG_DIR}"/.stopping
                "${LOG_DIR}"/.resource_usage.log
                "${LOG_DIR}"/crash_*.log
                "${LOG_DIR}"/perf_monitor.csv
                "${LOG_DIR}"/cpu_freq_monitor.csv
                "${LOG_DIR}"/mem_bw_monitor.csv
                "${LOG_DIR}"/pressure_performance_report.txt
                "${LOG_DIR}"/.swap_original
                "${LOG_DIR}"/.fio_mount_points
                "${LOG_DIR}"/.pid_cpu_freq_mon
                "${LOG_DIR}"/.pid_mem_bw_mon
                "${LOG_DIR}"/.pid_dmesg_mon
            )
            shopt -u nullglob

            local f
            for f in "${candidates[@]}"; do
                [ -e "$f" ] || continue
                mv "$f" "$backup_dir/" 2>/dev/null && moved_any=1
            done
            if [ "$moved_any" -eq 1 ]; then
                log_info "旧日志已备份到: ${backup_dir}"
            fi
            ;;
        delete)
            rm -f "${LOG_DIR}"/*.log "${LOG_DIR}"/.pid_* "${LOG_DIR}"/.test_running \
                  "${LOG_DIR}"/.start_timestamp "${LOG_DIR}"/.end_timestamp "${LOG_DIR}"/.stopping "${LOG_DIR}"/.resource_usage.log \
                  "${LOG_DIR}"/crash_*.log "$PMON_CSV" "$CPU_FREQ_CSV" "$MEM_BW_CSV" "$REPORT_FILE" "$SWAP_ORIG_FILE" "$FIO_MOUNT_LIST_FILE"
            ;;
        keep)
            ;;
        *)
            log_warn "未知 LOG_CLEANUP_MODE=${mode}，回退为 keep"
            ;;
    esac
}

handle_system_logs_on_start() {
    local action="${SYSTEM_LOG_ACTION:-backup}"
    case "$action" in
        backup)
            log_info "系统日志处理: backup（保存压测开始前快照，不清空）"
            dmesg > "${LOG_DIR}/dmesg_before.log" 2>&1 || true
            if [ -f /var/log/messages ]; then
                cp /var/log/messages "${LOG_DIR}/var_log_messages_before.log" 2>/dev/null || true
            fi
            ;;
        clear)
            log_info "系统日志处理: clear（清空 dmesg 和 /var/log/messages）"
            dmesg -C 2>/dev/null || true
            : > /var/log/messages 2>/dev/null || true
            ;;
        none)
            log_info "系统日志处理: none（不操作）"
            ;;
        *)
            log_warn "未知 SYSTEM_LOG_ACTION=${action}，回退为 backup"
            SYSTEM_LOG_ACTION="backup"
            handle_system_logs_on_start
            ;;
    esac
}

record_original_swap() {
    : > "$SWAP_ORIG_FILE"
    if command -v swapon &>/dev/null; then
        swapon --noheadings --show=NAME 2>/dev/null | awk '{print $1}' >> "$SWAP_ORIG_FILE" || true
        return 0
    fi
    awk 'NR>1{print $1}' /proc/swaps 2>/dev/null >> "$SWAP_ORIG_FILE" || true
}

restore_original_swap() {
    [ -f "$SWAP_ORIG_FILE" ] || return 0
    if [ ! -s "$SWAP_ORIG_FILE" ]; then
        log_info "原始 swap 列表为空，保持 swap 关闭状态"
        return 0
    fi

    log_info "恢复 swap（按启动时记录的 swap 列表）..."
    while read -r swap_dev; do
        [ -n "$swap_dev" ] || continue
        swapon "$swap_dev" 2>/dev/null || log_warn "swapon 失败: ${swap_dev}"
    done < "$SWAP_ORIG_FILE"
}

check_prerequisites() {
    STRESS_CMD=""
    local missing=0
    local optional_missing=0
    for cmd in bc dmidecode fio; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "缺少依赖: $cmd"
            missing=1
        fi
    done
    if command -v stress-ng &>/dev/null; then
        STRESS_CMD="stress-ng"
    else
        log_error "必须安装 stress-ng 才能进行高级内存压测 (不支持普通 stress)"
        missing=1
    fi
    if ! command -v ipmitool &>/dev/null; then
        log_warn "ipmitool 未安装，将跳过 BMC 硬件监控"
        SKIP_IPMI=true
        optional_missing=1
    else
        SKIP_IPMI=false
    fi
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
    log_info "所有必需依赖检查通过 (bc / dmidecode / fio / ${STRESS_CMD})"
    if [ "$optional_missing" -ne 0 ]; then
        log_warn "部分可选依赖缺失，相关功能将跳过（不影响整体流程）"
    fi
    log_info "压测工具: ${STRESS_CMD}"

    local fio_ver
    fio_ver=$(fio --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
    log_info "fio 版本: ${fio_ver} (要求 ${FIO_REQUIRED_VERSION:-3.13})"
    if [ "${FIO_VERSION_STRICT:-true}" = "true" ] && [ "$fio_ver" != "$FIO_REQUIRED_VERSION" ]; then
        log_error "fio 版本必须为 ${FIO_REQUIRED_VERSION}，当前 ${fio_ver}；如确需继续请设 FIO_VERSION_STRICT=false"
        missing=1
    fi

    if ! "${STRESS_CMD}" --help 2>&1 | grep -q '\-\-vm '; then
        log_error "${STRESS_CMD} 不支持 --vm 内存压测，升级到 stress-ng 0.09+"
        exit 1
    fi
}

check_test_running() {
    if [ -f "$START_FLAG" ]; then
        local any_alive=0
        if [ -f "$PID_FIO_LIST" ]; then
            while read -r pid; do
                [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && any_alive=1 && break
            done < "$PID_FIO_LIST"
        fi
        [ "$any_alive" -eq 0 ] && [ -f "$PID_STRESS" ] && kill -0 "$(cat "$PID_STRESS")" 2>/dev/null && any_alive=1
        if [ "$any_alive" -eq 0 ] && [ -f "$PID_STRESS_VM" ]; then
            while read -r vp; do
                [ -n "$vp" ] && kill -0 "$vp" 2>/dev/null && any_alive=1 && break
            done < "$PID_STRESS_VM"
        fi
        [ "$any_alive" -eq 1 ] && return 0
    fi
    return 1
}

detect_system_disk() {
    SYSTEM_DISK_BASES=""

    local add_base
    add_base() {
        local dev="$1" base
        [ -z "$dev" ] && return 0
        [ -b "$dev" ] || dev="/dev/${dev}"
        [ -b "$dev" ] || return 0
        base="/dev/$(lsblk -nlo PKNAME "$dev" 2>/dev/null | awk 'NF{print; exit}')"
        if [ ! -b "$base" ]; then
            case "$dev" in
                *p[0-9]) base="${dev%p*}" ;;
                *)       base="$dev" ;;
            esac
        fi
        [ -b "$base" ] || return 0
        case " ${SYSTEM_DISK_BASES} " in
            *" ${base} "*) ;;
            *) SYSTEM_DISK_BASES="${SYSTEM_DISK_BASES} ${base}" ;;
        esac
    }

    local src
    while read -r src; do
        [ -n "$src" ] && add_base "$src"
    done < <(awk '!/^#/ && $1 ~ /^\// {print $1}' /proc/mounts)

    local root_src
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    [ -z "$root_src" ] && root_src=$(df / | tail -1 | awk '{print $1}')
    add_base "$root_src"

    if command -v swapon &>/dev/null; then
        local sw
        while read -r sw; do
            [ -n "$sw" ] && add_base "$sw"
        done < <(swapon --noheadings --show=NAME 2>/dev/null)
    else
        while read -r sw; do
            [ -n "$sw" ] && add_base "$sw"
        done < <(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null)
    fi

    local slaves
    slaves=$(lsblk -nlo NAME,TYPE / 2>/dev/null | grep -v "disk\|part" | while read -r n _; do
        lsblk -s -nlo NAME,TYPE "/dev/${n}" 2>/dev/null | grep disk | awk '{print "/dev/" $1}'
    done | sort -u || true)
    for sd in $slaves; do
        [ -b "$sd" ] && case " ${SYSTEM_DISK_BASES} " in *" ${sd} "*) ;; *) SYSTEM_DISK_BASES="${SYSTEM_DISK_BASES} ${sd}" ;; esac
    done

    SYSTEM_DISK_BASES=$(echo "$SYSTEM_DISK_BASES" | xargs)
    if [ -z "$SYSTEM_DISK_BASES" ]; then
        log_warn "未能可靠识别系统盘，出于安全默认仅保护 /dev/sda；请通过配置文件 FIO_DISKS 显式指定测试盘，或人工核对"
        SYSTEM_DISK_BASES="/dev/sda"
    fi

    log_info "系统盘保护列表: ${SYSTEM_DISK_BASES}"
    log_info "以上磁盘及其分区不会被分区/格式化/压测"
}

is_system_disk() {
    local d="$1"
    for b in $SYSTEM_DISK_BASES; do
        echo "$d" | grep -qE "^${b}([0-9]+|p[0-9]+)?$" && return 0
    done
    return 1
}

gather_block_devices() {
    local disks=""
    for dev in /dev/sd[a-z] /dev/nvme[0-9]*n1 /dev/vd[a-z]; do
        [ -b "$dev" ] && disks="${disks} ${dev}"
    done
    [ -z "$disks" ] && return 1
    echo "$disks" | tr ' ' '\n' | sort -u
    return 0
}

is_safe_test_disk() {
    local disk="$1"
    local sig
    sig=$(blkid -p -o value -s TYPE "$disk" 2>/dev/null || true)
    case "$sig" in
        "" ) return 0 ;;
        LVM2_member|linux_raid_member|crypto_LUKS|swap) return 1 ;;
        * ) return 1 ;;
    esac
}

authorize_disk() {
    local disk="$1"
    [ "${ALLOW_AUTO_PREPARE:-false}" = "true" ] && return 0
    local trimmed
    trimmed=$(echo " ${FIO_DISKS:-} " | xargs)
    [ -z "${trimmed}" ] && return 0
    echo " ${trimmed} " | grep -q " ${disk} "
}

prompt_format_confirm() {
    local disk="$1"
    [ "${ALLOW_AUTO_PREPARE:-false}" = "true" ] && return 0
    if [ ! -e /dev/tty ]; then
        log_warn "非交互环境且未设置 ALLOW_AUTO_PREPARE=true，跳过自动格式化: ${disk}" >&2
        return 1
    fi
    local ans=""
    read -r -p "[CONFIRM] 即将 wipefs + 重新分区 + mkfs.ext4，清空磁盘 ${disk} 全部数据！输入 yes 确认: " ans < /dev/tty || true
    if [ "$ans" = "yes" ]; then
        return 0
    fi
    log_warn "用户未确认格式化，跳过: ${disk}" >&2
    return 1
}

prepare_and_format_disk() {
    local disk="$1"
    if is_system_disk "$disk"; then
        log_warn "系统盘 ${disk} 被请求准备/格式化，已拒绝（保护生效）" >&2
        echo ""
        return 0
    fi
    local best_part=""
    local disk_fstype
    disk_fstype=$(blkid -s TYPE -o value "$disk" 2>/dev/null || echo "")
    case "$disk_fstype" in
        ext4|xfs) best_part="$disk" ;;
        *)
            for part in ${disk}p* ${disk}[0-9]*; do
                [ -b "$part" ] || continue
                local fstype
                fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "")
                case "$fstype" in ext4|xfs) best_part="$part"; break ;; esac
            done
            ;;
    esac
    
    if [ -z "$best_part" ]; then
        if ! lsblk -nlo MOUNTPOINT "$disk" 2>/dev/null | grep -q "[a-zA-Z0-9]"; then
            if ! is_safe_test_disk "$disk"; then
                log_warn "非系统盘 ${disk} 检测到受保护签名(Raid/LVM/加密/swap)，跳过自动格式化" >&2
                echo ""
                return 0
            fi
            if ! prompt_format_confirm "$disk"; then
                echo ""
                return 0
            fi
            log_info "非系统盘 ${disk} 无可用文件系统且未挂载，执行自动分区与 ext4 格式化..." >&2
            if ! wipefs -a "$disk" >/dev/null 2>&1; then
                log_error "wipefs 失败: ${disk}" >&2
                return 1
            fi
            if ! parted -s "$disk" mklabel gpt mkpart primary ext4 0% 100% >/dev/null 2>&1; then
                log_error "parted 分区失败: ${disk}" >&2
                return 1
            fi
            sleep 2
            
            local new_part=""
            for p in "${disk}1" "${disk}p1"; do
                [ -b "$p" ] && new_part="$p" && break
            done
            if [ -z "$new_part" ]; then
                local auto_p
                auto_p=$(lsblk -nlo NAME "$disk" 2>/dev/null | grep -v "^$(basename "$disk")$" | head -1)
                [ -n "$auto_p" ] && new_part="/dev/$auto_p"
            fi
            
            if [ -n "$new_part" ] && [ -b "$new_part" ]; then
                if mkfs.ext4 -F "$new_part" >/dev/null 2>&1; then
                    best_part="$new_part"
                else
                    log_error "mkfs.ext4 失败: ${new_part}" >&2
                    return 1
                fi
            else
                log_error "自动分区后未发现可用分区: ${disk}" >&2
                return 1
            fi
        else
            log_warn "非系统盘 ${disk} 存在已挂载分区，跳过自动格式化" >&2
        fi
    fi
    echo "$best_part"
}

find_data_disks() {
    local valid_disks=""
    if [ -n "${FIO_DISKS:-}" ]; then
        log_info "使用配置文件指定的测试盘: ${FIO_DISKS}" >&2
        for disk in $FIO_DISKS; do
            if [ ! -b "$disk" ]; then
                log_error "指定测试盘不存在: ${disk}" >&2
                return 1
            fi
            if is_system_disk "$disk"; then
                log_error "指定测试盘是系统盘，拒绝: ${disk}" >&2
                return 1
            fi
            local bp
            if ! bp=$(prepare_and_format_disk "$disk"); then
                log_error "指定测试盘准备失败: ${disk}" >&2
                return 1
            fi
            [ -n "$bp" ] && valid_disks="${valid_disks} ${bp}"
        done
        valid_disks=$(echo "$valid_disks" | xargs)
        if [ -n "$valid_disks" ]; then
            echo "$valid_disks"
            return 0
        fi
        log_error "配置指定的测试盘均未产生可用分区 (FIO_DISKS=\"${FIO_DISKS}\")，中止，不回退" >&2
        return 1
    fi

    local all_disks
    all_disks=$(gather_block_devices) || return 1

    for disk in $all_disks; do
        is_system_disk "$disk" && continue
        authorize_disk "$disk" || { log_warn "未授权磁盘，跳过: ${disk}" >&2; continue; }
        local bp
        if ! bp=$(prepare_and_format_disk "$disk"); then
            log_warn "自动发现磁盘准备失败，跳过: ${disk}" >&2
            continue
        fi
        [ -z "$bp" ] && continue
        valid_disks="${valid_disks} ${bp}"
        log_info "  数据盘/分区: ${bp} (ext4/xfs)" >&2
    done

    valid_disks=$(echo "$valid_disks" | xargs)
    [ -z "$valid_disks" ] && return 1
    echo "$valid_disks"
    return 0
}

mount_data_disk() {
    local part_dev="$1" index="$2"
    local mount_point base_mount
    [ "$index" -eq 1 ] && base_mount="${FIO_MOUNT_BASE}" || base_mount="${FIO_MOUNT_BASE}_${index}"

    local existing_mp=""
    if command -v findmnt &>/dev/null; then
        existing_mp=$(findmnt -n -S "$part_dev" -o TARGET 2>/dev/null | head -1 || echo "")
    fi
    if [ -n "$existing_mp" ]; then
        log_info "${part_dev} 已挂载于 ${existing_mp}，直接使用该挂载点" >&2
        echo "$existing_mp"
        return 0
    fi

    mount_point="$base_mount"
    if is_mountpoint "$mount_point"; then
        log_warn "挂载点已被占用（不会 umount）: ${mount_point} <- $(get_mount_source "$mount_point")" >&2
    fi

    local try=0
    while is_mountpoint "$mount_point"; do
        try=$(( try + 1 ))
        if [ "$try" -gt 8 ]; then
            log_warn "无法找到可用挂载点(尝试次数过多): base=${base_mount}" >&2
            return 1
        fi
        mount_point="${base_mount}_$(date '+%s')_${RANDOM}"
    done

    mkdir -p "$mount_point"
    if ! mount "$part_dev" "$mount_point" 2>/dev/null; then
        log_warn "挂载失败: ${part_dev} -> ${mount_point}" >&2
        return 1
    fi

    echo "${part_dev} ${mount_point}" >> "$FIO_MOUNT_LIST_FILE"
    log_info "已挂载: ${part_dev} -> ${mount_point}" >&2
    echo "$mount_point"
    return 0
}

start_fio_pressure() {
    local target="$1" fio_log="$2" mode="$3"
    local fio_name="fio_pressure"

    if [ "$mode" = "file" ]; then
        local testfile="/var/tmp/fio_pressure_testfile"
        log_info "启动文件级 fio 压测 (file: ${testfile}, size=${FIO_FILE_SIZE_MB}M, numjobs=${FIO_FILE_NUMJOBS})"
        rm -f "$testfile" 2>/dev/null || true
        local fio_direct="--direct=1"
        local fio_engine="--ioengine=libaio"
        local fstype
        fstype=$(df -T "$(dirname "$testfile")" 2>/dev/null | tail -1 | awk '{print $2}')
        if [ "$fstype" = "tmpfs" ]; then
            log_warn "/var/tmp 检测为 tmpfs，去除 --direct=1 改用 sync IO"
            fio_direct=""
            fio_engine="--ioengine=sync"
        fi
        nohup fio --name=${fio_name} --filename=${testfile} --rw=rw --rwmixread=50 \
            ${fio_engine} ${fio_direct} --bs=1M --size=${FIO_FILE_SIZE_MB}M \
            --numjobs=${FIO_FILE_NUMJOBS} --iodepth=16 --group_reporting --time_based \
            --runtime=${TOTAL_DURATION_SEC}s --end_fsync=0 --thread --norandommap --randrepeat=0 --exitall \
            &> "$fio_log" &
    else
        log_info "启动块设备级 fio 压测 (目录: ${target})"
        local numjobs=4
        local disk_free_kb
        disk_free_kb=$(df -k "$target" | tail -1 | awk '{print $4}')
        local target_size_mb=$(( disk_free_kb / 1024 * 90 / 100 / numjobs ))
        [ "$target_size_mb" -lt 1024 ] && target_size_mb=1024
        
        log_info "目标压测数据大小: 每线程 ${target_size_mb}M (共 ${numjobs} 线程，总占用 90% 空闲空间)"
        nohup fio --name=${fio_name} --directory=${target} --rw=rw --rwmixread=50 \
            --ioengine=libaio --direct=1 --bs=1M --size=${target_size_mb}M --numjobs=${numjobs} --iodepth=64 \
            --group_reporting --time_based --runtime=${TOTAL_DURATION_SEC}s \
            --end_fsync=0 --thread --norandommap --randrepeat=0 --exitall \
            &> "$fio_log" &
    fi
    local fio_pid=$!
    echo "$fio_pid" >> "$PID_FIO_LIST"
    log_info "fio 已启动 (PID: ${fio_pid}), 日志: ${fio_log}"
}

compute_fio_usage() {
    local total_cpus fio_cpus
    total_cpus=$(nproc)
    fio_cpus=0
    if [ -f "$PID_FIO_LIST" ]; then
        local pids
        pids=$(awk 'NF{print $1}' "$PID_FIO_LIST" | paste -sd, -)
        if [ -n "$pids" ]; then
            local pct
            pct=$(top -b -d 3 -n 2 -p "$pids" 2>/dev/null | awk '
                /^[[:space:]]*[0-9]+/ {
                    if (NF >= 9) {
                        val[$1]=$9
                    }
                }
                END {
                    for (p in val) sum += val[p]
                    print sum+0
                }
            ')
            local cc
            cc=$(echo "scale=0; ${pct:-0} / 100" | bc 2>/dev/null || echo "0")
            fio_cpus=$(( cc > 0 ? cc : 0 ))
        fi
    fi

    local total_mem_kb fio_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    fio_mem_kb=0
    if [ -f "$PID_FIO_LIST" ]; then
        while read -r pid; do
            [ -z "$pid" ] && continue
            local rss
            rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
            fio_mem_kb=$(( fio_mem_kb + (rss > 0 ? rss : 0) ))  
        done < "$PID_FIO_LIST"
    fi
    local cached_kb
    cached_kb=$(grep -E '^(Cached|Buffers):' /proc/meminfo | awk '{sum+=$2} END {print sum+0}')
    echo "${fio_cpus} ${fio_mem_kb} ${total_cpus} ${total_mem_kb} ${cached_kb}"
}

collect_mem_stats() {
    local label="$1"
    local total_kb free_kb avail_kb swap_total_kb swap_free_kb cached_kb buff_kb
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    free_kb=$(grep MemFree  /proc/meminfo | awk '{print $2}')
    avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_free_kb=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    cached_kb=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
    buff_kb=$(grep '^Buffers:' /proc/meminfo | awk '{print $2}')

    local used_kb=$(( total_kb - free_kb - buff_kb - cached_kb ))
    local swap_used_kb=$(( swap_total_kb - swap_free_kb ))
    local mem_pct
    mem_pct=$(echo "scale=1; ${used_kb} * 100 / ${total_kb}" | bc)

    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "=== ${label} @ ${ts} ==="
        echo "total_kb=${total_kb}"
        echo "free_kb=${free_kb}"
        echo "avail_kb=${avail_kb}"
        echo "used_kb=${used_kb}"
        echo "cached_kb=${cached_kb}"
        echo "buff_kb=${buff_kb}"
        echo "swap_total_kb=${swap_total_kb}"
        echo "swap_used_kb=${swap_used_kb}"
        echo "mem_usage_pct=${mem_pct}"
        echo "timestamp=$(date '+%s')"
    }
}

get_mem_stat_val() {
    local key="$1" file="$2"
    grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2 || echo "0"
}

start_csv_monitor() {
    local interval="$1"
    local duration="$2"

    log_info "启动 OS 内存指标监控 (间隔 ${interval}s, 持续 ${duration}s)"

    {
        local start_ts
        start_ts=$(date '+%s')
        echo "timestamp,mem_total_kb,mem_free_kb,mem_avail_kb,mem_used_pct,swap_total_kb,swap_used_kb,cached_kb,buffer_kb" > "$PMON_CSV"
        local end_ts=$(( start_ts + duration ))
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            local ts total_kb free_kb avail_kb swap_total_kb swap_free_kb cached_kb buff_kb
            ts=$(date '+%s')
            total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            free_kb=$(grep MemFree  /proc/meminfo | awk '{print $2}')
            avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
            swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
            swap_free_kb=$(grep SwapFree /proc/meminfo | awk '{print $2}')
            cached_kb=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
            buff_kb=$(grep '^Buffers:' /proc/meminfo | awk '{print $2}')
            local used_kb=$(( total_kb - free_kb - buff_kb - cached_kb ))
            local swap_used_kb=$(( swap_total_kb - swap_free_kb ))
            local mem_pct
            mem_pct=$(echo "scale=1; ${used_kb} * 100 / ${total_kb}" | bc)
            echo "${ts},${total_kb},${free_kb},${avail_kb},${mem_pct},${swap_total_kb},${swap_used_kb},${cached_kb},${buff_kb}" >> "$PMON_CSV"
            sleep "$interval"
        done
        log_info "OS 内存指标监控已结束"
    } &
    local csv_pid=$!
    echo "$csv_pid" >> "$PID_IPMI_MON"
    log_info "OS 内存指标监控已启动 (PID: ${csv_pid})"
}

start_ipmi_monitor() {
    local mon_log="$1"
    local pid_file="$2"
    local interval="$3"
    local duration="$4"

    log_info "启动 ipmitool BMC 硬件监控 (间隔 ${interval}s, 持续 ${duration}s)"

    {
        local end_ts=$(( $(date '+%s') + duration ))
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            local ts
            ts=$(date '+%Y-%m-%d %H:%M:%S')
            echo "=== SNAPSHOT ${ts} ===" >> "$mon_log"
            timeout 30 ipmitool sensor list 2>/dev/null >> "$mon_log" || {
                echo "[WARN] ipmitool sensor list 超时或失败 @ ${ts}" >> "$mon_log"
            }
            echo "" >> "$mon_log"
            sleep "$interval"
        done
    } &
    local ipmi_pid=$!
    echo "$ipmi_pid" >> "$pid_file"
    log_info "ipmitool 监控已启动 (PID: ${ipmi_pid})"
}

start_cpu_freq_monitor() {
    local interval="$1"
    local duration="$2"

    local cpu_list
    cpu_list=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sort -V)
    if [ -z "$cpu_list" ]; then
        log_warn "未找到 CPU sysfs 目录，跳过 CPU 频率监控"
        return 0
    fi
    local first_dir
    first_dir=$(echo "$cpu_list" | head -1)
    if [ ! -d "${first_dir}/cpufreq" ]; then
        log_warn "未检测到 CPUFreq 驱动接口 (${first_dir}/cpufreq 不存在)，跳过 CPU 频率监控"
        return 0
    fi

    log_info "启动 CPU 频率监控 (间隔 ${interval}s, 持续 ${duration}s)"

    {
        local start_ts
        start_ts=$(date '+%s')
        {
            echo -n "timestamp"
            local dir
            for dir in $cpu_list; do
                echo -n ",$(basename "${dir}")_freq_khz"
            done
            echo ",max_freq_khz"
        } > "$CPU_FREQ_CSV"

        local end_ts=$(( start_ts + duration ))
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            local ts
            ts=$(date '+%s')
            echo -n "${ts}"
            local maxf=0
            for dir in $cpu_list; do
                local f
                f=$(cat "${dir}/cpufreq/scaling_cur_freq" 2>/dev/null | tr -d '[:space:]')
                [ -z "$f" ] && f=0
                echo -n ",${f}"
                if [ "$f" -gt "$maxf" ]; then maxf="$f"; fi
            done
            local max_scaling
            max_scaling=$(cat "${first_dir}/cpufreq/scaling_max_freq" 2>/dev/null | tr -d '[:space:]')
            [ -z "$max_scaling" ] && max_scaling="$maxf"
            echo ",${max_scaling}" >> "$CPU_FREQ_CSV"
            sleep "$interval"
        done
        log_info "CPU 频率监控已结束"
    } &
    local freq_pid=$!
    echo "$freq_pid" > "$PID_CPU_FREQ_MON"
    log_info "CPU 频率监控已启动 (PID: ${freq_pid})"
}

start_mem_bw_monitor() {
    local interval="$1"
    local duration="$2"

    if [ "${MEM_BW_MON:-auto}" = "off" ]; then
        log_info "MEM_BW_MON=off，跳过内存带宽监控"
        return 0
    fi
    if ! command -v perf &>/dev/null; then
        log_warn "perf 未安装，跳过内存带宽监控（以内存压测负载持续运行为满负载证据）"
        return 0
    fi

    local use_read="" use_write=""
    if timeout 15 perf stat -a -e "uncore_imc/data_reads/" -x, sleep 1 >/dev/null 2>&1; then
        use_read="uncore_imc/data_reads/"
    fi
    if timeout 15 perf stat -a -e "uncore_imc/data_writes/" -x, sleep 1 >/dev/null 2>&1; then
        use_write="uncore_imc/data_writes/"
    fi
    if [ -z "$use_read" ] && [ -z "$use_write" ]; then
        log_warn "未能探测到可用内存带宽硬件计数器 (uncore_imc)，跳过内存带宽监控（以内存压测负载持续运行为满负载证据）"
        return 0
    fi

    log_info "启动内存带宽监控 (间隔 ${interval}s, 持续 ${duration}s, 事件: ${use_read:-无} ${use_write:-无})"

    {
        echo "timestamp,mem_read_MBps,mem_write_MBps" > "$MEM_BW_CSV"
        local prev_r=0 prev_w=0 first=1
        local end_ts=$(( $(date '+%s') + duration ))
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            local ts
            ts=$(date '+%s')
            local r w events="" out r_unit="" w_unit=""
            [ -n "$use_read" ] && events="$use_read"
            [ -n "$use_write" ] && events="${events:+${events},}${use_write}"
            # perf stat -x, CSV columns: value,unit,event,... (value=$1, unit=$2)
            out=$(timeout 60 perf stat -a -e "$events" -x, sleep "$interval" 2>&1)
            r=$(echo "$out" | awk -F, '$0 ~ /data_reads/  && $1 ~ /^[0-9]+(\.[0-9]+)?$/ {sum+=$1} END{print sum+0}')
            w=$(echo "$out" | awk -F, '$0 ~ /data_writes/ && $1 ~ /^[0-9]+(\.[0-9]+)?$/ {sum+=$1} END{print sum+0}')
            r_unit=$(echo "$out" | awk -F, '$0 ~ /data_reads/  {u=$2; gsub(/^[ \t]+|[ \t]+$/,"",u); print u; exit}')
            w_unit=$(echo "$out" | awk -F, '$0 ~ /data_writes/ {u=$2; gsub(/^[ \t]+|[ \t]+$/,"",u); print u; exit}')
            if [ "$first" -eq 1 ]; then
                prev_r="$r"; prev_w="$w"; first=0
                continue
            fi
            local r_mbw w_mbw
            if [ -n "$use_read" ] && [ "$r" -ge "$prev_r" ] && [ "$r" -gt 0 ]; then
                if [ "$r_unit" = "MiB" ]; then
                    r_mbw=$(echo "scale=1; ($r - $prev_r) / $interval" | bc 2>/dev/null || echo "0")
                else
                    r_mbw=$(echo "scale=1; ($r - $prev_r) / 1048576 / $interval" | bc 2>/dev/null || echo "0")
                fi
            else
                r_mbw=0
            fi
            if [ -n "$use_write" ] && [ "$w" -ge "$prev_w" ] && [ "$w" -gt 0 ]; then
                if [ "$w_unit" = "MiB" ]; then
                    w_mbw=$(echo "scale=1; ($w - $prev_w) / $interval" | bc 2>/dev/null || echo "0")
                else
                    w_mbw=$(echo "scale=1; ($w - $prev_w) / 1048576 / $interval" | bc 2>/dev/null || echo "0")
                fi
            else
                w_mbw=0
            fi
            echo "${ts},${r_mbw},${w_mbw}" >> "$MEM_BW_CSV"
            prev_r="$r"; prev_w="$w"
        done
        log_info "内存带宽监控已结束"
    } &
    local bw_pid=$!
    echo "$bw_pid" > "$PID_MEM_BW_MON"
    log_info "内存带宽监控已启动 (PID: ${bw_pid})"
}

start_dmesg_monitor() {
    local interval="$1"
    local duration="$2"

    log_info "启动 dmesg 中途增量快照监控 (每 ${interval}s 保存并清空一次, 持续 ${duration}s)"

    {
        local end_ts=$(( $(date '+%s') + duration ))
        local seq=0
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            seq=$(( seq + 1 ))
            dmesg -c > "${LOG_DIR}/dmesg_incremental_$(date '+%Y%m%d_%H%M%S')_${seq}.log" 2>/dev/null || true
            sleep "$interval"
        done
        log_info "dmesg 中途增量快照监控已结束"
    } &
    local dmesg_pid=$!
    echo "$dmesg_pid" > "$PID_DMESG_MON"
    log_info "dmesg 中途增量快照监控已启动 (PID: ${dmesg_pid})"
}

parse_ipmi_thermal() {
    local mon_log="$1"
    [ -f "$mon_log" ] || return 0
    awk '
        /^=== SNAPSHOT/ { in_snap=1; next }
        in_snap {
            if ($0 ~ /^[[:space:]]*$/) { in_snap=0; next }
            if ($0 ~ /WARN|ipmitool|not available/) next
            n=split($0,a,"|")
            if (n<3) next
            name=a[1]; gsub(/^[ \t]+|[ \t]+$/,"",name)
            val=a[2]+0; unit=a[3]; gsub(/^[ \t]+|[ \t]+$/,"",unit)
            u=tolower(unit)
            if (u ~ /degrees c/) {
                if (!(name in cmin)){cmin[name]=val;cmax[name]=val;csum[name]=val;cn[name]=1;cl[cln++]=name}
                else { if(val<cmin[name])cmin[name]=val; if(val>cmax[name])cmax[name]=val; csum[name]+=val; cn[name]++ }
            }
            else if (u ~ /watt/) {
                if (!(name in pmin)){pmin[name]=val;pmax[name]=val;psum[name]=val;pn[name]=1;pl[pln++]=name}
                else { if(val<pmin[name])pmin[name]=val; if(val>pmax[name])pmax[name]=val; psum[name]+=val; pn[name]++ }
            }
        }
        END {
            for(i=0;i<cln;i++){ nm=cl[i]; printf "温度 %s: min=%.1fC max=%.1fC avg=%.1fC n=%d\n", nm, cmin[nm], cmax[nm], csum[nm]/cn[nm], cn[nm] }
            for(i=0;i<pln;i++){ nm=pl[i]; printf "功耗 %s: min=%.1fW max=%.1fW avg=%.1fW n=%d\n", nm, pmin[nm], pmax[nm], psum[nm]/pn[nm], pn[nm] }
        }
    ' "$mon_log"
}

start_stress_guardian() {
    local duration="$1"

    {
        local end_ts=$(( $(date '+%s') + duration + 30 ))
        local cpu_died=0 vm_died=0
        local cpu_early_death_ts=0 vm_early_death_ts=0
        local fio_start_ts=""
        [ -f "$FIO_START_TS_FILE" ] && fio_start_ts=$(cat "$FIO_START_TS_FILE" 2>/dev/null || echo "")
        local deadline
        if [ -n "$fio_start_ts" ] && [ "$fio_start_ts" -gt 0 ] 2>/dev/null; then
            deadline=$(( fio_start_ts + duration - 5 ))
        else
            deadline=$(( $(date '+%s') + duration - 5 ))
        fi
        local fio_initial="" fio_alive=0 recorded_fio=""
        local vm_recorded_dead="" loop_count=0
        local disk_watch_list=""
        if [ -s "$FIO_MOUNT_LIST_FILE" ]; then
            while read -r wpart _wmp; do
                [ -n "$wpart" ] || continue
                local pbase
                pbase=$(lsblk -nlo PKNAME "$wpart" 2>/dev/null | awk 'NF{print; exit}')
                if [ -n "$pbase" ] && [ -b "/dev/${pbase}" ]; then
                    disk_watch_list="${disk_watch_list} ${wpart}:/dev/${pbase}"
                else
                    disk_watch_list="${disk_watch_list} ${wpart}:${wpart}"
                fi
            done < "$FIO_MOUNT_LIST_FILE"
        fi
        if [ -s "$PID_FIO_LIST" ]; then
            fio_initial=$(awk 'NF{print $1}' "$PID_FIO_LIST" | paste -sd ' ' -)
            fio_alive=$(echo "$fio_initial" | wc -w)
        fi

        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            loop_count=$(( loop_count + 1 ))
            if [ -f "$STOPPING_FLAG" ]; then
                log_info "检测到停止标志，进程守护静默退出"
                break
            fi
            local stress_pid=""
            if [ -f "$PID_STRESS" ] && [ "$cpu_died" -eq 0 ]; then
                stress_pid=$(cat "$PID_STRESS" 2>/dev/null || echo "")
                if [ -n "$stress_pid" ] && ! kill -0 "$stress_pid" 2>/dev/null; then
                    cpu_died=1
                    local now_ts
                    now_ts=$(date '+%s')
                    if [ "$now_ts" -lt "$deadline" ]; then
                        cpu_early_death_ts="$now_ts"
                        log_error "stress-ng CPU 异常退出 (PID: ${stress_pid}, 提前于预期结束时间)"
                        {
                            echo "=== STRESS CPU CRASH @ $(date '+%Y-%m-%d %H:%M:%S') ==="
                            echo "pid=${stress_pid}"
                            echo "expected_end_ts=${deadline}"
                            echo "crash_ts=${cpu_early_death_ts}"
                            echo "=== Memory state ==="
                            free -m
                        } > "${LOG_DIR}/crash_stress_cpu.log"
                    else
                        log_info "stress-ng CPU 正常结束 (PID: ${stress_pid})"
                    fi
                    pkill -9 -P "$stress_pid" 2>/dev/null || true
                fi
            fi

            if [ -f "$PID_STRESS_VM" ] && [ "$vm_died" -eq 0 ]; then
                # multi-PID aware (memtester writes 2 PIDs, stress-ng writes 1):
                # record each newly-dead PID once; all-dead => vm_died=1
                local vm_alive=0 vm_total=0 vm_newly_dead=""
                while read -r vp; do
                    [ -n "$vp" ] || continue
                    vm_total=$(( vm_total + 1 ))
                    if kill -0 "$vp" 2>/dev/null; then
                        vm_alive=$(( vm_alive + 1 ))
                    elif ! echo "$vm_recorded_dead" | grep -qw "$vp"; then
                        vm_recorded_dead="${vm_recorded_dead} ${vp}"
                        vm_newly_dead="${vm_newly_dead} ${vp}"
                    fi
                done < "$PID_STRESS_VM"
                if [ -n "$vm_newly_dead" ]; then
                    local now_ts
                    now_ts=$(date '+%s')
                    if [ "$now_ts" -lt "$deadline" ]; then
                        vm_early_death_ts="$now_ts"
                        log_error "内存压测进程异常退出 (PID:${vm_newly_dead}, 存活 ${vm_alive}/${vm_total}, 提前于预期结束时间)"
                        {
                            echo "=== STRESS VM CRASH @ $(date '+%Y-%m-%d %H:%M:%S') ==="
                            echo "pids=${vm_newly_dead}"
                            echo "alive=${vm_alive}/${vm_total}"
                            echo "expected_end_ts=${deadline}"
                            echo "crash_ts=${vm_early_death_ts}"
                            echo "=== Memory state ==="
                            free -m
                            echo "=== stress-ng/memtester VM log tail ==="
                            tail -30 "${LOG_DIR}/stress_vm.log" 2>/dev/null || echo "(log not available)"
                        } > "${LOG_DIR}/crash_stress_vm.log"
                    else
                        log_info "内存压测进程结束 (PID:${vm_newly_dead}, 存活 ${vm_alive}/${vm_total})"
                    fi
                fi
                if [ "$vm_total" -gt 0 ] && [ "$vm_alive" -eq 0 ]; then
                    vm_died=1
                fi
            fi

            [ "$cpu_died" -eq 1 ] && [ "$vm_died" -eq 1 ] && break
            [ -n "$fio_initial" ] && [ "$fio_alive" -eq 0 ] && break

            if [ -n "$fio_initial" ]; then
                local new_alive=0
                for fpid in $fio_initial; do
                    if kill -0 "$fpid" 2>/dev/null; then
                        new_alive=$(( new_alive + 1 ))
                    elif ! echo "$recorded_fio" | grep -qw "$fpid"; then
                        recorded_fio="${recorded_fio} ${fpid}"
                        local fnow_ts
                        fnow_ts=$(date '+%s')
                        if [ "$fnow_ts" -lt "$deadline" ]; then
                            local fio_cmd="" fio_dir fio_name
                            if [ -r "/proc/${fpid}/cmdline" ]; then
                                fio_cmd=$(tr '\0' ' ' < "/proc/${fpid}/cmdline" 2>/dev/null || echo "")
                            fi
                            fio_dir=$(echo "$fio_cmd" | grep -oE -- '--directory=[^ ]+' | cut -d= -f2 || echo "N/A")
                            fio_name=$(echo "$fio_cmd" | grep -oE -- '--name=[^ ]+' | cut -d= -f2 || echo "N/A")
                            [ -n "$fio_dir" ] || fio_dir="N/A"
                            [ -n "$fio_name" ] || fio_name="N/A"
                            log_error "fio 进程异常退出 (PID: ${fpid}, job: ${fio_name}, directory: ${fio_dir}, 提前于预期结束时间)"
                            {
                                echo "=== FIO CRASH @ $(date '+%Y-%m-%d %H:%M:%S') ==="
                                echo "pid=${fpid}"
                                echo "job=${fio_name}"
                                echo "directory=${fio_dir}"
                                echo "expected_end_ts=${deadline}"
                                echo "crash_ts=${fnow_ts}"
                                echo "=== matching fio log tail ==="
                                local fio_log_match=""
                                fio_log_match=$(ls -t "${LOG_DIR}"/fio_pressure_*.log 2>/dev/null | head -3)
                                for f in $fio_log_match; do
                                    echo "----- $f -----"
                                    tail -15 "$f" 2>/dev/null
                                done
                                echo "=== Memory state ==="
                                free -m
                            } >> "${LOG_DIR}/crash_fio.log"
                        fi
                    fi
                done
                fio_alive="$new_alive"
            fi

            # disk-drop detection: every 60s verify test partitions/disks still exist
            if [ $(( loop_count % 12 )) -eq 0 ] && [ -n "$disk_watch_list" ]; then
                for entry in $disk_watch_list; do
                    local dpart dbase
                    dpart="${entry%%:*}"
                    dbase="${entry##*:}"
                    if [ ! -b "$dpart" ] && [ ! -b "$dbase" ]; then
                        if ! grep -q "partition=${dpart}" "${LOG_DIR}/crash_disk.log" 2>/dev/null; then
                            log_error "测试盘疑似掉盘: ${dpart} (base ${dbase}) 设备节点消失"
                            {
                                echo "=== DISK LOST @ $(date '+%Y-%m-%d %H:%M:%S') ==="
                                echo "partition=${dpart}"
                                echo "base=${dbase}"
                                echo "=== lsblk snapshot ==="
                                lsblk 2>/dev/null
                                echo "=== dmesg tail ==="
                                dmesg 2>/dev/null | tail -30
                            } >> "${LOG_DIR}/crash_disk.log"
                        fi
                    fi
                done
            fi

            sleep 5
        done
        log_info "进程守护已退出"
    } &
    local guardian_pid=$!
    echo "$guardian_pid" > "$PID_GUARDIAN"
    log_info "进程守护已启动 (PID: ${guardian_pid})"
}

start_stress_cpu() {
    local cpu_cores="$1"
    local stress_log="$2"

    log_info "启动 CPU 压测 (${STRESS_CMD}, ${cpu_cores} 核)"

    ${STRESS_CMD} --cpu "$cpu_cores" --timeout ${TOTAL_DURATION_SEC}s >> "$stress_log" 2>&1 &
    local stress_pid=$!
    echo "$stress_pid" > "$PID_STRESS"

    wait "$stress_pid" 2>/dev/null && exit_code=0 || exit_code=$?
    {
        echo "stress CPU exit code: ${exit_code}"
        echo "stress CPU cores: ${cpu_cores}"
        echo "stress CPU duration: ${TOTAL_DURATION_SEC}s"
    } >> "$stress_log"
    log_info "stress CPU 已结束 (PID: ${stress_pid}, exit: ${exit_code})"
}

start_stress_vm() {
    local mem_pct="$1"
    local vm_mode="$2"
    local vm_log="$3"

    local mem_tool
    if [ "${MEM_TOOL:-auto}" = "auto" ]; then
        if command -v memtester &>/dev/null; then
            mem_tool="memtester"
        else
            mem_tool="stress-ng"
        fi
    else
        mem_tool="${MEM_TOOL}"
    fi

    case "$mem_tool" in
        memtester)
            log_info "启动 memtester 内存压测 (${mem_pct} 物理内存, 2 workers)"
            local mem_mb
            mem_mb=$(echo "$mem_pct" | sed 's/[Mm]//')
            local half_mb=$(( mem_mb / 2 ))
            [ "$half_mb" -lt 1 ] && half_mb=1
            : > "$PID_STRESS_VM"
            local w
            for w in 1 2; do
                nohup memtester "${half_mb}M" 9999999 >> "$vm_log" 2>&1 &
                echo "$!" >> "$PID_STRESS_VM"
            done
            ;;
        stress-ng|*)
            # NOTE: stress-ng --vm-bytes is PER-WORKER; split target across 2 workers
            local mb_total mb_each
            mb_total=$(echo "$mem_pct" | sed 's/[Mm]$//')
            mb_each=$(( mb_total / 2 ))
            [ "$mb_each" -lt 1 ] && mb_each=1
            log_info "启动 ${STRESS_CMD} 内存压测 (总计 ${mem_pct}, 2 workers x ${mb_each}M/worker, mode=${vm_mode})"
            local vm_args="--vm 2 --vm-bytes ${mb_each}M --vm-keep"
            case "$vm_mode" in
                rand|random)  vm_args="${vm_args} --vm-method random" ;;
                seq|sequential) vm_args="${vm_args} --vm-method inc" ;;
                flip)         vm_args="${vm_args} --vm-method flip" ;;
                rowhammer)    vm_args="${vm_args} --vm-method rowhammer" ;;
                walk)         vm_args="${vm_args} --vm-method walk-one --vm-method walk-zero" ;;
                all)          vm_args="${vm_args}" ;;
                *)            log_warn "未知内存访问模式: ${vm_mode}, 使用默认 all"; vm_args="${vm_args}" ;;
            esac
            ${STRESS_CMD} ${vm_args} --timeout ${TOTAL_DURATION_SEC}s >> "$vm_log" 2>&1 &
            echo "$!" > "$PID_STRESS_VM"
            ;;
    esac

    local vm_rc=0
    wait || vm_rc=$?
    {
        echo "stress VM exit code: ${vm_rc}"
        echo "stress VM tool: ${mem_tool}"
        echo "stress VM bytes: ${mem_pct}"
        echo "stress VM mode: ${vm_mode}"
    } >> "$vm_log"
    log_info "内存压测已结束 (tool=${mem_tool}, bytes=${mem_pct})"
}

generate_performance_report() {
    log_info "生成性能报告..."

    local rep="$REPORT_FILE"
    {
        echo "=============================================================="
        echo "  整机 7x24H 混合压力测试 - 性能报告"
        echo "=============================================================="
        echo "  生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "--------------------------------------------------------------"

        if [ -f "$START_TIME_FILE" ]; then
            echo "  开始时间: $(cat "$START_TIME_FILE")"
        fi
        if [ -f "$END_TIME_FILE" ]; then
            echo "  结束时间: $(cat "$END_TIME_FILE")"
        fi

        local actual_hours="N/A"
        if [ -f "${LOG_DIR}/.start_timestamp" ] && [ -f "${LOG_DIR}/.end_timestamp" ]; then
            local st et
            st=$(cat "${LOG_DIR}/.start_timestamp")
            et=$(cat "${LOG_DIR}/.end_timestamp")
            actual_hours=$(echo "scale=1; (${et} - ${st}) / 3600" | bc)
        fi
        echo "  实际运行: ${actual_hours} 小时 (目标: $(( TOTAL_DURATION_SEC / 3600 ))H)"
        echo ""

        echo "========== 内存性能指标 =========="
        if [ -f "${LOG_DIR}/mem_baseline.log" ]; then
            local bl_total bl_free bl_avail bl_swap_total bl_swap_used
            bl_total=$(get_mem_stat_val total_kb "${LOG_DIR}/mem_baseline.log")
            bl_free=$(get_mem_stat_val free_kb "${LOG_DIR}/mem_baseline.log")
            bl_avail=$(get_mem_stat_val avail_kb "${LOG_DIR}/mem_baseline.log")
            bl_swap_total=$(get_mem_stat_val swap_total_kb "${LOG_DIR}/mem_baseline.log")
            bl_swap_used=$(get_mem_stat_val swap_used_kb "${LOG_DIR}/mem_baseline.log")

            echo "  [压测前-基线]"
            echo "    总内存:      $(echo "scale=1; ${bl_total} / 1024 / 1024" | bc) GB"
            echo "    可用内存:    $(echo "scale=1; ${bl_avail} / 1024 / 1024" | bc) GB"
            echo "    空闲内存:    $(echo "scale=1; ${bl_free} / 1024 / 1024" | bc) GB"
            echo "    Swap 总量:   $(echo "scale=1; ${bl_swap_total} / 1024 / 1024" | bc) GB"
            echo "    Swap 已用:   $(echo "scale=1; ${bl_swap_used} / 1024" | bc) MB"
            echo ""
        fi

        if [ -f "${LOG_DIR}/mem_reset.log" ]; then
            local rs_total rs_free rs_avail rs_swap_used
            rs_total=$(get_mem_stat_val total_kb "${LOG_DIR}/mem_reset.log")
            rs_free=$(get_mem_stat_val free_kb "${LOG_DIR}/mem_reset.log")
            rs_avail=$(get_mem_stat_val avail_kb "${LOG_DIR}/mem_reset.log")
            rs_swap_used=$(get_mem_stat_val swap_used_kb "${LOG_DIR}/mem_reset.log")

            echo "  [压测后-复位]"
            echo "    总内存:      $(echo "scale=1; ${rs_total} / 1024 / 1024" | bc) GB"
            echo "    可用内存:    $(echo "scale=1; ${rs_avail} / 1024 / 1024" | bc) GB"
            echo "    空闲内存:    $(echo "scale=1; ${rs_free} / 1024 / 1024" | bc) GB"
            echo "    Swap 已用:   $(echo "scale=1; ${rs_swap_used} / 1024" | bc) MB"
            echo ""
        fi

        if [ -f "$PMON_CSV" ]; then
            local total_lines peak_mem_use min_mem_free avg_mem_use peak_swap_use
            total_lines=$(tail -n +2 "$PMON_CSV" | wc -l)
            if [ "$total_lines" -gt 0 ]; then
                peak_mem_use=$(tail -n +2 "$PMON_CSV" | awk -F, '{if($5>max)max=$5} END{print max+0}')
                min_mem_free=$(tail -n +2 "$PMON_CSV" | awk -F, 'NR==1{min=$3}{if($3<min)min=$3} END{print min+0}')
                avg_mem_use=$(tail -n +2 "$PMON_CSV" | awk -F, '{sum+=$5;n++} END{printf "%.1f", sum/n}')
                peak_swap_use=$(tail -n +2 "$PMON_CSV" | awk -F, '{if($7>max)max=$7} END{print max+0}')

                echo "  [压测期间统计 - ${total_lines} 个采样点]"
                echo "    峰值使用率:  ${peak_mem_use}%"
                echo "    平均使用率:  ${avg_mem_use}%"
                echo "    最小可用内存: $(echo "scale=1; ${min_mem_free} / 1024 / 1024" | bc) GB"
                echo "    Swap 峰值:   $(echo "scale=1; ${peak_swap_use} / 1024" | bc) MB"
                echo ""
            fi
        fi

        echo "========== 部件状态 =========="
        if [ -f "${LOG_DIR}/stress_vm.log" ]; then
            local vm_exit
            vm_exit=$(grep "exit code:" "${LOG_DIR}/stress_vm.log" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "?")
            echo "  stress-ng VM:  exit=${vm_exit}"
        fi
        if [ -f "${LOG_DIR}/stress_cpu.log" ]; then
            local cpu_exit
            cpu_exit=$(grep "exit code:" "${LOG_DIR}/stress_cpu.log" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "?")
            echo "  stress-ng CPU: exit=${cpu_exit}"
        fi

        echo ""
        echo "========== CPU 频率与降频检查 =========="
        if [ -f "$CPU_FREQ_CSV" ] && [ -s "$CPU_FREQ_CSV" ]; then
            local freq_summary
            freq_summary=$(tail -n +2 "$CPU_FREQ_CSV" | awk -F, -v t="${CPU_THROTTLE_PCT:-90}" '
                {
                    nf=NF
                    maxf=$nf
                    minf=maxf
                    for(i=2;i<nf;i++){ if($i!="" && $i+0<minf) minf=$i+0 }
                    if(maxf>0 && minf < maxf*t/100) thr++
                    s++
                }
                END { printf "%d %d", s+0, thr+0 }
            ')
            local freq_samples freq_throttle
            read -r freq_samples freq_throttle <<< "$freq_summary"
            echo "  CPU 频率采样点数: ${freq_samples:-0}"
            echo "  疑似降频样本数 (任一核 < max*${CPU_THROTTLE_PCT}%): ${freq_throttle:-0}"
            [ "${freq_throttle:-0}" -gt 0 ] && echo "  *** 检测到疑似降频，请人工核查 cpu_freq_monitor.csv ***"
        else
            echo "  (CPU 频率监控未运行或无数据)"
        fi

        echo ""
        echo "========== 内存带宽监控 =========="
        if [ -f "$MEM_BW_CSV" ] && [ -s "$MEM_BW_CSV" ]; then
            local bw_summary
            bw_summary=$(tail -n +2 "$MEM_BW_CSV" | awk -F, '
                { if($2!="" && $2+0>rmax) rmax=$2+0; rsum+=$2; rc++; if($3!="" && $3+0>wmax) wmax=$3+0; wsum+=$3; wc++ }
                END { printf "%.1f %.1f %.1f %.1f", (rc?rsum/rc:0), rmax, (wc?wsum/wc:0), wmax }
            ')
            local r_avg r_max w_avg w_max
            read -r r_avg r_max w_avg w_max <<< "$bw_summary"
            echo "  读带宽: 平均 ${r_avg} MBps, 峰值 ${r_max} MBps"
            echo "  写带宽: 平均 ${w_avg} MBps, 峰值 ${w_max} MBps"
            echo "  (数值为 perf uncore 计数器近似值，平台不支持时该项为空)"
        else
            echo "  (内存带宽硬件计数器不可用，以内存压测进程持续运行作为满负载证据)"
        fi

        echo ""
        echo "========== 温度与功耗监控 (BMC) =========="
        if [ -f "${LOG_DIR}/ipmi_monitor.log" ]; then
            local thermal_summary
            thermal_summary=$(parse_ipmi_thermal "${LOG_DIR}/ipmi_monitor.log")
            if [ -n "$thermal_summary" ]; then
                while IFS= read -r line; do
                    echo "  ${line}"
                done <<< "$thermal_summary"
            else
                echo "  (未从 ipmi_monitor.log 解析到温度/功耗传感器)"
            fi
        else
            echo "  (ipmitool 监控未运行或未安装)"
        fi

        echo ""
        echo "========== 系统日志检查 =========="
        local dmesg_err_pattern="Oops:|Call Trace:|^BUG:|Kernel panic|Hardware Error:|mce:|MCE|segfault|task hung|KASAN|EDAC|I/O error|nvme .*reset|controller reset|device disconnected|device blocked|ata[0-9]+ .*(error|reset)"
        local dmesg_files=""
        [ -f "${LOG_DIR}/dmesg_pressure.log" ] && dmesg_files="${LOG_DIR}/dmesg_pressure.log"
        local dmesg_inc_count=0
        if compgen -G "${LOG_DIR}/dmesg_incremental_*.log" > /dev/null; then
            # shellcheck disable=SC2086
            dmesg_files="${dmesg_files} ${LOG_DIR}/dmesg_incremental_*.log"
            dmesg_inc_count=$(ls "${LOG_DIR}"/dmesg_incremental_*.log 2>/dev/null | wc -l)
        fi
        if [ -n "$dmesg_files" ]; then
            local dmesg_err=0
            # shellcheck disable=SC2086
            dmesg_err=$(cat $dmesg_files 2>/dev/null | grep -ciE "$dmesg_err_pattern" || true)
            echo "  dmesg 异常(含增量快照 ${dmesg_inc_count} 个文件): ${dmesg_err} 行"
        fi

        if [ -f "${LOG_DIR}/journalctl_pressure.log" ]; then
            local j_err
            j_err=$(grep -ciE "Out of memory|Killed process|Oops:|Call Trace:|^BUG:|Kernel panic|Hardware Error:|mce:|MCE|panic|EDAC|task hung|I/O error|nvme .*reset|controller reset" "${LOG_DIR}/journalctl_pressure.log" 2>/dev/null || echo "0")
            echo "  journalctl 异常关键词: ${j_err} 行"
        fi

        if [ -f "${LOG_DIR}/crash_stress_vm.log" ] || [ -f "${LOG_DIR}/crash_stress_cpu.log" ] || [ -f "${LOG_DIR}/crash_fio.log" ] || [ -f "${LOG_DIR}/crash_disk.log" ]; then
            echo ""
            echo "  *** 检测到异常终止/掉盘记录，请检查 crash_*.log (含 crash_disk.log) ***"
        fi

        echo ""
        echo "=============================================================="
    } > "$rep"

    log_info "性能报告已生成: ${rep}"
}

do_start() {
    check_root
    load_config
    check_prerequisites

    if check_test_running; then
        log_warn "混合压力测试已在运行中"
        log_warn "如需重新开始，请先执行: $0 stop"
        exit 1
    fi

    backup_and_prepare_log_dir
    exec &> >(tee -a "${LOG_DIR}/console_output.log")

    log_info "========== 整机 7x24H 混合压力测试 - 启动 =========="

    trap 'log_warn "收到信号，开始自动收尾..."; do_stop; exit 130' INT TERM HUP
    trap 'do_stop' EXIT

    log_info "Step 1: 处理系统日志..."
    handle_system_logs_on_start

    log_info "Step 2: 记录测试开始时间..."
    date '+%Y-%m-%d %H:%M:%S' | tee "$START_TIME_FILE"
    date '+%s' > "${LOG_DIR}/.start_timestamp"

    log_info "Step 3: 收集 dmidecode 内存信息..."
    dmidecode -t memory > "${LOG_DIR}/dmidecode_memory.log" 2>&1 || true
    log_info "dmidecode 内存信息已保存"

    log_info "Step 4: 采集内存基线数据..."
    collect_mem_stats "BASELINE" > "$MEM_BASELINE_LOG"
    log_info "内存基线数据已保存: ${MEM_BASELINE_LOG}"

    log_info "Step 5: 收集测试前 BMC 传感器数据..."
    if [ "$SKIP_IPMI" = "false" ]; then
        timeout 30 ipmitool sensor list > "${LOG_DIR}/sensor_before.log" 2>/dev/null || {
            log_warn "ipmitool sensor list 执行失败或超时"
        }
        log_info "传感器数据已保存至: ${LOG_DIR}/sensor_before.log"
    else
        log_info "ipmitool 未安装, 跳过 BMC 传感器采集"
    fi

    log_info "Step 6: 记录并关闭 swap..."
    record_original_swap
    swapoff -a 2>/dev/null || true
    local swap_total
    swap_total=$(free -m | awk '/Swap/{print $2}')
    [ "$swap_total" = "0" ] && log_info "swap 已成功关闭" || log_warn "swap 可能未完全关闭, 当前 swap 总量: ${swap_total}MB"

    log_info "Step 7: 启动监控..."
    : > "$PID_IPMI_MON"

    start_csv_monitor "$CSV_MON_INTERVAL" "$TOTAL_DURATION_SEC"

    if [ "$SKIP_IPMI" = "false" ]; then
        start_ipmi_monitor "${LOG_DIR}/ipmi_monitor.log" "$PID_IPMI_MON" "$IPMI_MON_INTERVAL" "$TOTAL_DURATION_SEC"
    else
        log_info "ipmitool 未安装, 跳过 BMC 传感器监控"
    fi

    start_cpu_freq_monitor "$CSV_MON_INTERVAL" "$TOTAL_DURATION_SEC"
    start_mem_bw_monitor "$CSV_MON_INTERVAL" "$TOTAL_DURATION_SEC"
    start_dmesg_monitor "$DMESG_SNAP_INTERVAL" "$TOTAL_DURATION_SEC"

    # EXIT-trap teardown (do_stop) only performs full cleanup when START_FLAG
    # exists; set it now so any later start-phase failure still kills monitors
    # and restores swap.
    touch "$START_FLAG"

    log_info "Step 8: 检测系统盘..."
    detect_system_disk

    log_info "Step 9: 查找可用数据盘..."
    local data_disks
    if ! data_disks=$(find_data_disks); then
        if [ -n "${FIO_DISKS:-}" ]; then
            log_error "指定测试盘准备失败 (FIO_DISKS=\"${FIO_DISKS}\")，中止测试（不回退文件级模式）"
            exit 1
        fi
        log_warn "查找或准备数据盘失败，回退到文件级压测模式"
        data_disks=""
    fi
    data_disks=$(echo "$data_disks" | xargs)

    local fio_mode
    local disk_index=0
    : > "$PID_FIO_LIST"
    : > "$FIO_MOUNT_LIST_FILE"
    date '+%s' > "$FIO_START_TS_FILE"

    if [ -n "$data_disks" ]; then
        fio_mode="block"
        log_info "可用数据盘: ${data_disks}"
        for part in $data_disks; do
            disk_index=$(( disk_index + 1 ))
            local mount_point
            mount_point=$(mount_data_disk "$part" "$disk_index") || continue
            local disk_label
            disk_label=$(echo "$part" | sed 's|/dev/||g' | sed 's|/|_|g')
            start_fio_pressure "$mount_point" "${LOG_DIR}/fio_pressure_${disk_label}.log" "block"
        done
    else
        fio_mode="file"
        log_warn "==============================================="
        log_warn "未找到任何可用的非系统数据盘，将退化到对系统盘进行安全文件级压测"
        log_warn "目标路径: /var/tmp 下创建测试文件"
        
        # 计算系统盘安全压测文件大小
        local root_free_kb
        root_free_kb=$(df -k /var/tmp | tail -1 | awk '{print $4}')
        local root_free_mb=$(( root_free_kb / 1024 ))
        
        # 预留 5GB 安全空间，其余作为压测文件大小，若不足 5GB 则退出
        if [ "$root_free_mb" -lt 5120 ]; then
            log_error "系统盘 /var/tmp 剩余空间不足 5GB (${root_free_mb}MB)，无法进行安全的压测，退出！"
            exit 1
        fi
        
        # 使用配置文件指定的 FIO_FILE_SIZE_MB，如果是多线程，则检查总大小
        local safe_fio_mb=$(( root_free_mb - 5120 ))
        local total_req_mb=$(( FIO_FILE_SIZE_MB * FIO_FILE_NUMJOBS ))
        if [ "$total_req_mb" -gt "$safe_fio_mb" ]; then
            local new_size=$(( safe_fio_mb / FIO_FILE_NUMJOBS ))
            log_warn "配置的总压测文件大小 (${total_req_mb}MB) 过大，为保护系统盘，自动调整每线程大小为 ${new_size}MB"
            FIO_FILE_SIZE_MB=$new_size
        fi
        
        log_warn "最终确定的系统盘压测文件大小为: ${FIO_FILE_SIZE_MB} MB"
        log_warn "==============================================="
        start_fio_pressure "/var/tmp" "${LOG_DIR}/fio_pressure_file.log" "file"
    fi

    if [ ! -s "$PID_FIO_LIST" ]; then
        log_error "fio 压测未能启动，请检查磁盘状态"
        exit 1
    fi

    log_info ""
    log_info "Step 10: 等待 ${FIO_STEADY_WAIT}s 让 fio 达到稳态..."
    sleep "$FIO_STEADY_WAIT"

    log_info "Step 11: 获取 fio 资源占用，计算 CPU 压测参数..."
    local usage_info
    usage_info=$(compute_fio_usage)
    [ -z "$usage_info" ] && usage_info="0 0 $(nproc) $(grep MemTotal /proc/meminfo | awk '{print $2}') 0"
    local fio_cpus fio_mem_kb total_cpus total_mem_kb cached_kb
    read -r fio_cpus fio_mem_kb total_cpus total_mem_kb cached_kb <<< "$usage_info"

    local cpu_cores
    cpu_cores=$(echo "${total_cpus} * ${CPU_TARGET_PCT} / 100 - ${fio_cpus}" | bc | cut -d. -f1)
    [ -z "$cpu_cores" ] && cpu_cores=1
    [ "$cpu_cores" -lt 1 ] && cpu_cores=1

    local total_mem_gb
    total_mem_gb=$(echo "scale=1; ${total_mem_kb} / 1024 / 1024" | bc)

    local avail_mem_kb target_mem_mb
    avail_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    target_mem_mb=$(echo "${avail_mem_kb} * ${MEM_TARGET_PCT} / 100 / 1024" | bc | cut -d. -f1)
    [ -z "$target_mem_mb" ] && target_mem_mb=1024
    [ "$target_mem_mb" -lt 1024 ] && target_mem_mb=1024

    {
        echo "=== Resource Usage Snapshot (after fio steady state) ==="
        echo "total_cpus=${total_cpus}"
        echo "cpu_cores=${cpu_cores}"
        echo "total_mem_kb=${total_mem_kb}"
        echo "avail_mem_kb=${avail_mem_kb}"
        echo "target_mem_mb=${target_mem_mb}"
        echo "vm_mode=${MEM_ACCESS_MODE}"
        echo "fio_mode=${fio_mode}"
        echo "total_duration_sec=${TOTAL_DURATION_SEC}"
    } > "${LOG_DIR}/.resource_usage.log"

    log_info "  总 CPU 核心: ${total_cpus}"
    log_info "  stress CPU 核数: ${cpu_cores}"
    log_info "  总内存: ${total_mem_gb} GB"
    log_info "  stress-ng VM 加压: ${target_mem_mb}M (基于可用内存 ${MEM_TARGET_PCT}%, 2 workers, mode=${MEM_ACCESS_MODE})"
    log_info ""

    log_info "Step 12: 启动 stress-ng CPU 压测..."
    start_stress_cpu "$cpu_cores" "${LOG_DIR}/stress_cpu.log" &
    sleep 2

    log_info "Step 13: 启动内存压测..."
    start_stress_vm "${target_mem_mb}M" "$MEM_ACCESS_MODE" "${LOG_DIR}/stress_vm.log" &
    sleep 2

    log_info "Step 14: 启动进程守护..."
    start_stress_guardian "$TOTAL_DURATION_SEC"

    touch "$START_FLAG"

    local end_time
    end_time=$(date -d "+${TOTAL_DURATION_SEC} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$(( TOTAL_DURATION_SEC / 3600 )) 小时后")

    echo ""
    echo "=============================================="
    echo "  整机 7x24H 混合压力测试 - 已启动"
    echo "=============================================="
    echo "  测试开始时间: $(cat "$START_TIME_FILE")"
    echo "  预计完成时间: ${end_time}"
    echo "----------------------------------------------"
    echo "  压测组件:"
    echo "    CPU:    ${STRESS_CMD} --cpu (${cpu_cores} 核)"
    echo "    内存:   ${MEM_TOOL:-auto} (${target_mem_mb}M, 可用内存${MEM_TARGET_PCT}%, mode=${MEM_ACCESS_MODE})"
    echo "    硬盘:   fio $(fio --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1) (50%读 50%写, 模式: ${fio_mode})"
    local monitor_suffix=""
    if [ "${SKIP_IPMI:-false}" = "true" ]; then
        monitor_suffix=" [跳过]"
    fi
    echo "    监控:   ipmitool BMC 硬件监控 (每${IPMI_MON_INTERVAL}s) / OS内存 (每${CSV_MON_INTERVAL}s)${monitor_suffix}"
    echo "----------------------------------------------"
    echo "  注意事项:"
    echo "  1. ${end_time} 后会自动执行 stop 进行收尾"
    echo "  2. 按 Ctrl+C 可提前终止并自动收尾"
    echo "  3. 查看状态:      $0 status"
    echo "=============================================="
    echo ""

    log_info "脚本将等待 ${TOTAL_DURATION_SEC}s (${TOTAL_DURATION_SEC}秒) 后自动停止..."
    sleep "$TOTAL_DURATION_SEC"
    log_info "压测时长已到 (${TOTAL_DURATION_SEC}s)，开始自动停止..."
    do_stop
}

do_stop() {
    if [ "${__STOPPING}" -eq 1 ]; then
        log_warn "do_stop 已在执行中，忽略重复调用"
        return 0
    fi
    __STOPPING=1

    check_root
    mkdir -p "$LOG_DIR"
    exec &> >(tee -a "${LOG_DIR}/console_output.log")

    if ! check_test_running; then
        if [ -f "$START_FLAG" ]; then
            log_warn "未检测到正在运行的测试进程, 但发现残留标记文件, 将继续收集日志"
        else
            log_warn "测试未在运行, 无需停止"
            __STOPPING=0
            return 0
        fi
    fi

    log_info "========== 停止 7x24H 混合压力测试 =========="

    touch "$STOPPING_FLAG"

    log_info "停止 fio 进程..."
    if [ -f "$PID_FIO_LIST" ]; then
        local pids_to_kill=""
        while read -r pid; do
            [ -z "$pid" ] && continue
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                pids_to_kill="${pids_to_kill} ${pid}"
            fi
        done < "$PID_FIO_LIST"
        if [ -n "$pids_to_kill" ]; then
            sleep 3
            for pid in $pids_to_kill; do
                kill -9 "$pid" 2>/dev/null || true
                log_info "  fio (PID: ${pid}) 已停止"
            done
        fi
    fi

    log_info "停止 stress-ng CPU 进程..."
    if [ -f "$PID_STRESS" ]; then
        local pid
        pid=$(cat "$PID_STRESS")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 3
            kill -9 "$pid" 2>/dev/null || true
            log_info "  stress-ng CPU (PID: ${pid}) 已停止"
        fi
    fi

    log_info "停止内存压测进程 (stress-ng VM / memtester)..."
    if [ -f "$PID_STRESS_VM" ]; then
        while read -r pid; do
            [ -n "$pid" ] || continue
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                sleep 1
                kill -9 "$pid" 2>/dev/null || true
                log_info "  内存压测 (PID: ${pid}) 已停止"
            fi
        done < "$PID_STRESS_VM"
    fi

    log_info "停止 ipmitool 监控进程..."
    if [ -f "$PID_IPMI_MON" ]; then
        while read -r pid; do
            [ -z "$pid" ] && continue
            kill "$pid" 2>/dev/null || true
        done < "$PID_IPMI_MON"
    fi

    log_info "停止 CPU 频率监控进程..."
    if [ -f "$PID_CPU_FREQ_MON" ]; then
        while read -r pid; do
            [ -z "$pid" ] && continue
            kill "$pid" 2>/dev/null || true
        done < "$PID_CPU_FREQ_MON"
    fi

    log_info "停止内存带宽监控进程..."
    if [ -f "$PID_MEM_BW_MON" ]; then
        while read -r pid; do
            [ -z "$pid" ] && continue
            kill "$pid" 2>/dev/null || true
        done < "$PID_MEM_BW_MON"
    fi

    log_info "停止 dmesg 增量快照监控进程..."
    if [ -f "$PID_DMESG_MON" ]; then
        while read -r pid; do
            [ -z "$pid" ] && continue
            kill "$pid" 2>/dev/null || true
        done < "$PID_DMESG_MON"
    fi

    log_info "停止进程守护..."
    if [ -f "$PID_GUARDIAN" ]; then
        local gpid
        gpid=$(cat "$PID_GUARDIAN")
        [ -n "$gpid" ] && kill "$gpid" 2>/dev/null || true
    fi

    sleep 2

    log_info "记录测试结束时间..."
    date '+%Y-%m-%d %H:%M:%S' | tee "$END_TIME_FILE"
    date '+%s' > "${LOG_DIR}/.end_timestamp"

    log_info "采集内存复位数据..."
    collect_mem_stats "RESET" > "${LOG_DIR}/mem_reset.log"
    log_info "内存复位数据已保存"

    log_info "收集测试后 BMC 传感器数据..."
    if command -v ipmitool &>/dev/null; then
        timeout 30 ipmitool sensor list > "${LOG_DIR}/sensor_after.log" 2>/dev/null || {
            log_warn "ipmitool sensor list 执行失败或超时"
        }
        log_info "传感器数据已保存至: ${LOG_DIR}/sensor_after.log"
    else
        log_info "ipmitool 未安装，跳过 BMC 传感器采集"
    fi

    log_info "收集 dmesg 日志..."
    dmesg > "${LOG_DIR}/dmesg_pressure.log" 2>&1 || true

    log_info "收集系统日志..."
    if [ -f /var/log/messages ]; then
        cp /var/log/messages "${LOG_DIR}/var_log_messages.log" 2>/dev/null || true
    fi

    log_info "收集 journalctl 日志..."
    if command -v journalctl &>/dev/null; then
        local since_arg until_arg
        since_arg="@$(cat "${LOG_DIR}/.start_timestamp" 2>/dev/null || echo 0)"
        until_arg="@$(cat "${LOG_DIR}/.end_timestamp" 2>/dev/null || echo now)"
        journalctl --since "$since_arg" --until "$until_arg" --no-pager > "${LOG_DIR}/journalctl_pressure.log" 2>&1 || log_warn "journalctl 采集失败"
    else
        log_info "systemd-journal 不可用，跳过 journalctl"
    fi

    log_info "恢复 swap..."
    restore_original_swap

    log_info "卸载 fio 挂载点..."
    if [ -f "$FIO_MOUNT_LIST_FILE" ]; then
        while read -r part_dev mp; do
            [ -n "$mp" ] || continue
            if is_mountpoint "$mp"; then
                if umount "$mp" 2>/dev/null; then
                    log_info "已卸载: ${mp}"
                else
                    log_warn "卸载失败(可能被占用): ${mp} <- $(get_mount_source "$mp")"
                fi
            fi
        done < "$FIO_MOUNT_LIST_FILE"
    fi
    rm -f /var/tmp/fio_pressure_testfile 2>/dev/null || true

    log_info "生成性能报告..."
    generate_performance_report

    rm -f "$START_FLAG"
    __STOPPING=0

    log_info ""
    log_info "=============================================="
    log_info "  整机 7x24H 混合压力测试 - 已停止"
    log_info "  报告文件: ${REPORT_FILE}"
    log_info "  日志目录: ${LOG_DIR}"
    log_info "=============================================="
}

do_status() {
    mkdir -p "$LOG_DIR"

    echo "=============================================="
    echo "  整机 7x24H 混合压力测试 - 状态"
    echo "=============================================="

    if check_test_running; then
        echo "  状态: 运行中"

        if [ -f "${LOG_DIR}/.start_timestamp" ]; then
            local start_ts
            start_ts=$(cat "${LOG_DIR}/.start_timestamp")
            local now_ts elapsed_h
            now_ts=$(date '+%s')
            elapsed_h=$(echo "scale=1; (${now_ts} - ${start_ts}) / 3600" | bc)
            local target_h=168
            if [ -f "${LOG_DIR}/.resource_usage.log" ]; then
                local dur_saved
                dur_saved=$(get_mem_stat_val total_duration_sec "${LOG_DIR}/.resource_usage.log")
                case "$dur_saved" in ''|*[!0-9]*) ;; *) target_h=$(( dur_saved / 3600 )) ;; esac
            fi
            echo "  已运行: ${elapsed_h} 小时 (目标: ${target_h}H)"
        fi
    else
        echo "  状态: 未运行"
        if [ -f "${LOG_DIR}/.end_timestamp" ]; then
            local end_ts_text
            end_ts_text=$(cat "${LOG_DIR}/.end_timestamp")
            echo "  上次结束: $(date -d "@${end_ts_text}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A')"
        fi
        if [ -f "$REPORT_FILE" ]; then
            echo "  报告文件: ${REPORT_FILE}"
        fi
    fi

    echo "----------------------------------------------"

    echo "  进程状态:"
    if [ -f "$PID_FIO_LIST" ] && [ -s "$PID_FIO_LIST" ]; then
        local fio_count=0 fio_total=0
        fio_total=$(awk 'NF{n++} END{print n+0}' "$PID_FIO_LIST")
        while read -r pid; do
            [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && fio_count=$(( fio_count + 1 ))
        done < "$PID_FIO_LIST"
        echo "    fio:            ${fio_count}/${fio_total} 进程运行中"
        if [ "$fio_total" -gt 0 ] && [ "$fio_count" -lt "$fio_total" ]; then
            echo "    *** 警告: $(( fio_total - fio_count )) 个 fio 进程已提前退出，请检查 ${LOG_DIR}/crash_fio.log ***"
        fi
    else
        echo "    fio:            未运行"
    fi

    if [ -f "$PID_STRESS" ] && kill -0 "$(cat "$PID_STRESS")" 2>/dev/null; then
        echo "    stress-ng CPU:  运行中 (PID: $(cat "$PID_STRESS"))"
    else
        echo "    stress-ng CPU:  未运行"
    fi

    if [ -s "$PID_STRESS_VM" ]; then
        local vm_alive=0 vm_total=0
        vm_total=$(awk 'NF{n++} END{print n+0}' "$PID_STRESS_VM")
        while read -r vpid; do
            [ -n "$vpid" ] && kill -0 "$vpid" 2>/dev/null && vm_alive=$(( vm_alive + 1 ))
        done < "$PID_STRESS_VM"
        if [ "$vm_alive" -gt 0 ]; then
            echo "    内存压测:       ${vm_alive}/${vm_total} 进程运行中"
        else
            echo "    内存压测:       未运行 (${vm_total} 记录)"
        fi
    else
        echo "    内存压测:       未运行"
    fi

    if [ -f "$PID_IPMI_MON" ] && [ -s "$PID_IPMI_MON" ]; then
        local ipmi_count=0
        while read -r pid; do
            [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ipmi_count=$(( ipmi_count + 1 ))
        done < "$PID_IPMI_MON"
        echo "    ipmitool 监控:  ${ipmi_count} 进程"
    else
        echo "    ipmitool 监控:  未运行"
    fi

    if [ -f "$PID_CPU_FREQ_MON" ] && [ -s "$PID_CPU_FREQ_MON" ] && kill -0 "$(head -1 "$PID_CPU_FREQ_MON")" 2>/dev/null; then
        echo "    CPU 频率监控:    运行中"
    else
        echo "    CPU 频率监控:    未运行"
    fi

    if [ -f "$PID_MEM_BW_MON" ] && [ -s "$PID_MEM_BW_MON" ] && kill -0 "$(head -1 "$PID_MEM_BW_MON")" 2>/dev/null; then
        echo "    内存带宽监控:    运行中"
    else
        echo "    内存带宽监控:    未运行"
    fi

    if [ -f "$PID_DMESG_MON" ] && [ -s "$PID_DMESG_MON" ] && kill -0 "$(head -1 "$PID_DMESG_MON")" 2>/dev/null; then
        echo "    dmesg 增量快照:  运行中"
    else
        echo "    dmesg 增量快照:  未运行"
    fi

    if [ -f "$PID_GUARDIAN" ] && kill -0 "$(cat "$PID_GUARDIAN")" 2>/dev/null; then
        echo "    进程守护:       运行中 (PID: $(cat "$PID_GUARDIAN"))"
    else
        echo "    进程守护:       未运行"
    fi

    echo "----------------------------------------------"

    local total_kb free_kb avail_kb swap_used_kb
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    free_kb=$(grep MemFree  /proc/meminfo | awk '{print $2}')
    avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_free_kb=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    swap_used_kb=$(( swap_total_kb - swap_free_kb ))

    echo "  内存快照:"
    echo "    总内存:      $(echo "scale=1; ${total_kb} / 1024 / 1024" | bc) GB"
    echo "    可用内存:    $(echo "scale=1; ${avail_kb} / 1024 / 1024" | bc) GB"
    echo "    空闲内存:    $(echo "scale=1; ${free_kb} / 1024 / 1024" | bc) GB"
    echo "    Swap 已用:   $(echo "scale=1; ${swap_used_kb} / 1024" | bc) MB"

    echo "----------------------------------------------"

    echo "  日志目录: ${LOG_DIR}"
    if [ -d "$LOG_DIR" ]; then
        echo "  日志文件:"
        ls -lh "${LOG_DIR}"/*.log 2>/dev/null || echo "    (无)"
    fi

    echo "=============================================="
}

usage() {
    echo "用法: $0 {start|stop|status}"
    echo ""
    echo "  start   - 启动 7x24H 整机混合压力测试"
    echo "  stop    - 停止测试并生成性能报告"
    echo "  status  - 查看测试状态"
    echo ""
    echo "  配置文件: ${CONF_FILE}"
    echo ""
    echo "  可配置参数 (在配置文件中设置):"
    echo "    TOTAL_DURATION_SEC    测试持续秒数 (默认: 604800 = 168H)"
    echo "    CPU_TARGET_PCT        CPU 压测目标百分比 (默认: 95)"
    echo "    MEM_TARGET_PCT        内存压测目标百分比 (默认: 90)"
    echo "    MEM_ACCESS_MODE       内存访问模式: all/rand/seq/flip/rowhammer/walk"
    echo "    CSV_MON_INTERVAL     OS内存监控间隔秒数 (默认: 10)"
    echo "    IPMI_MON_INTERVAL     ipmitool BMC 监控间隔秒数 (默认: 600 = 10min)"
    echo "    MEM_TOOL              内存压测工具: stress-ng/memtester/auto (默认: stress-ng，按用例要求；auto=优先 memtester)"
    echo "    FIO_REQUIRED_VERSION  fio 要求版本 (默认: 3.13)"
    echo "    FIO_VERSION_STRICT    是否强制校验 fio 版本 true/false (默认: true)"
    echo "    CPU_THROTTLE_PCT      疑似降频判定阈值% (默认: 90，任一核频率低于 max 该比例即标记)"
    echo "    MEM_BW_MON            内存带宽监控: auto/off (默认: auto，依赖 perf uncore 计数器)"
    echo "    DMESG_SNAP_INTERVAL   dmesg 中途增量快照间隔秒数 (默认: 1800 = 30min)"
    echo "    FIO_STEADY_WAIT       fio 稳态等待秒数 (默认: 45)"
    echo "    FIO_DISKS             指定测试盘 (空格分隔, 默认: 自动发现)"
    echo "    FIO_FILE_SIZE_MB      文件级 fio 文件大小 MB (默认: 10240)"
    echo "    FIO_FILE_NUMJOBS      文件级 fio 并发数 (默认: 1)"
    echo "    FIO_MOUNT_BASE        fio 挂载基础路径 (默认: /mnt/fio_pressure)"
    echo "    LOG_CLEANUP_MODE      日志目录清理策略: backup/delete/keep (默认: backup)"
    echo "    SYSTEM_LOG_ACTION     系统日志策略: backup/clear/none (默认: backup)"
}

case "${1:-}" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    status)
        do_status
        ;;
    *)
        usage
        exit 1
        ;;
esac

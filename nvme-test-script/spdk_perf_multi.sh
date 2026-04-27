#!/bin/bash
#***********************************************************
# SPDK NVMe Performance Test for hygon 7493 system
# Author: Prz1y
#
# Features:
#   - 自动发现 NUMA 拓扑和 NVMe 设备
#   - 自动绑核（同 NUMA 多设备时均分 CCD 核心，默认排除 CPU0）
#   - 自动配置大页内存（hugepages）
#   - Ctrl+C 自动清理后台 SPDK 进程
#   - 每设备独立日志文件，测试结束后自动汇总性能表格
#   - 全部测试项目整合，无外部脚本依赖
#
# Core Allocation Strategy:
#   同一 NUMA node 下的核心按 NVMe 设备数量均分，
#   例如 14 核 / 2 设备 = 每设备 7 核分区，
#   8 核测试时自动降为 min(8, 7) = 7 核。
#   CPU0 默认排除（承载系统中断），可通过 SKIP_CPU0=false 恢复。
#
# Note on "set -e" and "wait":
#   脚本启用 set -e，但 run_spdk_test 中的 wait 循环使用
#   "if ! wait $pid; then" 结构，if 条件内 errexit 自动抑制，
#   即使子进程退出非零也不会导致脚本提前终止。
#***********************************************************

set -euo pipefail

# ===================== 用户配置区 =====================
SPDK_PERF="/root/spdk2409/spdk/build/bin/spdk_nvme_perf"
SPDK_SETUP=""  # 留空则自动检测; 如 /root/spdk2409/spdk/scripts/setup.sh

#   如需使用 1GB 大页，重启前执行以下命令: 
#   sed -i 's/\(GRUB_CMDLINE_LINUX="[^"]*\)/\1 default_hugepagesz=1G hugepagesz=1G hugepages=64/' /etc/default/grub
#   注：hugepages=64根据机器配置可以设置到256
#   *hugepages=64 = 8个/节点 × 8个NUMA节点，对应 HUGEPAGES_PER_NUMA_NODE=8
#   grub2-mkconfig -o $(find /boot/efi/EFI -name grub.cfg -not -path "*/BOOT/*" | head -1)
#   reboot
#   重启后验证: cat /proc/cmdline | grep hugepages

# 大页配置（极限性能推荐 1GB 但需重启预留，通用场景推荐 2MB）
HUGEPAGE_SIZE="1GB"            # 可选: "2MB" 或 "1GB" (1GB 需启动时通过 GRUB 预留)
HUGEPAGES_PER_NUMA_NODE=8      # 1GB: 每节点 8 个 (8GB); 2MB: 每节点 4096 个 (8GB)
SPDK_SHM_SIZE=1024             # SPDK 共享内存大小 (MB)，对应 -s 参数
SLEEP_BETWEEN_TESTS=60         # 测试间隔（秒）
FORCE_BIND_ALL=true            # true: 强制将仍绑内核 nvme 驱动的设备解绑并重绑到用户态驱动
                               # false: 跳过无法被 setup.sh 绑定的设备（如系统盘）
SKIP_CPU0=true                 # true: CPU0 不参与绑核（避免系统中断干扰延迟测试）
                               # false: 所有核心均可分配（纯带宽/IOPS 场景可开启以榨取全部性能）

# ===================== 全局变量 =====================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/spdk_perf_logs_$(date +%Y%m%d_%H%M%S)"
SUMMARY_LOG=""

declare -a NVME_BDFS=()
declare -a NVME_NUMA=()
declare -A NUMA_CORES=()
declare -A NUMA_NVME_COUNT=()
declare -A NUMA_NVME_IDX=()
declare -A ALLOC_CACHE=()          # 预计算的核心分配缓存: [bdf:num]=csv hex count
declare -a SPDK_PIDS=()            # 全局：后台 spdk_nvme_perf 进程 PID，用于 Ctrl+C 清理
                                   # 每次 run_spdk_test 结束后自动清空，避免积累已退出 PID

# ===================== 输出格式 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[====]${NC} ${BOLD}$*${NC}"; }

# ===================== 信号处理：Ctrl+C 清理后台进程 =====================
cleanup_on_interrupt() {
    echo ""
    log_warn "收到中断信号 (Ctrl+C)，正在清理所有后台 SPDK 进程..."
    # 先杀脚本启动的进程
    for pid in "${SPDK_PIDS[@]:-}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    # 防止孤儿进程：杀掉所有 spdk_nvme_perf
    pkill -TERM -f spdk_nvme_perf 2>/dev/null || true
    sleep 2
    # 强制清理
    for pid in "${SPDK_PIDS[@]:-}"; do
        kill -KILL "$pid" 2>/dev/null || true
    done
    pkill -KILL -f spdk_nvme_perf 2>/dev/null || true
    log_info "清理完成，脚本已退出。"
    log_info "部分日志保存在: $LOG_DIR"
    exit 130
}

trap cleanup_on_interrupt SIGINT SIGTERM

# ===================== 前置检查 =====================
preflight_check() {
    log_step "前置检查"

    if [ "$(id -u)" -ne 0 ]; then
        log_err "必须以 root 身份运行"
        exit 1
    fi

    if [ ! -x "$SPDK_PERF" ]; then
        log_err "SPDK perf 工具未找到: $SPDK_PERF"
        log_err "请确认 SPDK 已编译，或修改脚本顶部 SPDK_PERF 路径"
        exit 1
    fi

    for cmd in python3 lspci; do
        if ! command -v "$cmd" &>/dev/null; then
            log_err "缺少必要工具: $cmd"
            exit 1
        fi
    done

    # 自动检测 SPDK setup.sh
    if [ -z "$SPDK_SETUP" ]; then
        local spdk_root
        spdk_root="$(dirname "$(dirname "$(dirname "$SPDK_PERF")")")"
        if [ -x "${spdk_root}/scripts/setup.sh" ]; then
            SPDK_SETUP="${spdk_root}/scripts/setup.sh"
            log_info "自动检测到 SPDK setup.sh: $SPDK_SETUP"
        fi
    fi

    mkdir -p "$LOG_DIR"
    SUMMARY_LOG="${LOG_DIR}/00_summary.log"
    log_info "日志目录: $LOG_DIR"
}

# ===================== 大页内存配置 =====================
setup_hugepages() {
    log_step "配置大页内存 (hugepages) - ${HUGEPAGE_SIZE}"

    # 根据大页类型确定路径和挂载参数
    local hp_dir pagesize_kb pagesize_mount
    if [ "$HUGEPAGE_SIZE" = "1GB" ]; then
        hp_dir="hugepages-1048576kB"
        pagesize_kb="1048576kB"
        pagesize_mount="1G"
    else
        hp_dir="hugepages-2048kB"
        pagesize_kb="2048kB"
        pagesize_mount="2M"
    fi

    # 遍历系统中所有 NUMA node，统一分配大页，避免 EAL "No free hugepages" 警告
    local all_nodes
    all_nodes=($(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | sed 's/.*node//' | sort -n || true))

    for node in "${all_nodes[@]}"; do
        local hp_path="/sys/devices/system/node/node${node}/hugepages/${hp_dir}/nr_hugepages"
        if [ ! -f "$hp_path" ]; then
            log_warn "NUMA node $node 不支持 $HUGEPAGE_SIZE 大页"
            continue
        fi

        local current
        current=$(cat "$hp_path" 2>/dev/null || echo 0)
        if [ "$current" -lt "$HUGEPAGES_PER_NUMA_NODE" ]; then
            echo "$HUGEPAGES_PER_NUMA_NODE" > "$hp_path" || {
                log_warn "NUMA node $node: 写入 nr_hugepages 失败（内存不足？）"
                continue
            }
            local actual
            actual=$(cat "$hp_path" 2>/dev/null || echo 0)
            log_info "NUMA node $node: ${HUGEPAGE_SIZE} hugepages $current -> $actual (目标 $HUGEPAGES_PER_NUMA_NODE)"
        else
            log_info "NUMA node $node: ${HUGEPAGE_SIZE} hugepages 已充足 ($current >= $HUGEPAGES_PER_NUMA_NODE)"
        fi
    done

    # 清理另一种大页，避免 EAL "N hugepages reserved but no mounted hugetlbfs" 警告
    local other_dir
    if [ "$HUGEPAGE_SIZE" = "1GB" ]; then
        other_dir="hugepages-2048kB"
    else
        other_dir="hugepages-1048576kB"
    fi
    for node in "${all_nodes[@]}"; do
        local other_path="/sys/devices/system/node/node${node}/hugepages/${other_dir}/nr_hugepages"
        if [ -f "$other_path" ]; then
            local other_cur
            other_cur=$(cat "$other_path" 2>/dev/null || echo 0)
            if [ "$other_cur" -gt 0 ]; then
                echo 0 > "$other_path" 2>/dev/null || true
                log_info "NUMA node $node: 已清除非目标大页 (${other_dir}: $other_cur -> 0)"
            fi
        fi
    done

    # 确保 hugetlbfs 已挂载（DPDK/SPDK 通过此文件系统访问大页）
    local mount_point="/dev/hugepages"
    local mount_pattern="hugetlbfs.*pagesize=${pagesize_mount}"
    
    if mount | grep -q "$mount_pattern" 2>/dev/null; then
        log_info "hugetlbfs 已挂载 (pagesize=${pagesize_mount})"
    else
        # 卸载不匹配的挂载
        if mount | grep -q "$mount_point" 2>/dev/null; then
            umount "$mount_point" 2>/dev/null || true
            log_info "已卸载旧的 hugetlbfs 挂载"
        fi
        
        if [ ! -d "$mount_point" ]; then
            mkdir -p "$mount_point"
        fi
        
        if mount -t hugetlbfs -o pagesize=${pagesize_mount} nodev "$mount_point" 2>/dev/null; then
            log_info "hugetlbfs 已挂载到 $mount_point (pagesize=${pagesize_mount})"
        else
            log_err "hugetlbfs 挂载失败！"
            log_err "请手动执行: mount -t hugetlbfs -o pagesize=${pagesize_mount} nodev /dev/hugepages"
            return 1
        fi
    fi

    # 验证实际分配结果（sysfs 写入不代表内核真正分配成功）
    local actual_total
    actual_total=$(grep -i "^HugePages_Total:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    if [ "${actual_total:-0}" -eq 0 ] && [ "$HUGEPAGE_SIZE" = "1GB" ]; then
        log_warn "1GB 大页实际分配为 0！(sysfs 写入被接受但内核无法分配连续 1GB 内存)"
        log_warn "1GB 大页需在启动时通过 GRUB 预留，参考脚本顶部注释配置后重启"
        log_warn "自动回退到 2MB 大页..."

        # 回退: 切换到 2MB 大页
        HUGEPAGE_SIZE="2MB"
        HUGEPAGES_PER_NUMA_NODE=4096
        hp_dir="hugepages-2048kB"
        pagesize_mount="2M"

        for node in "${all_nodes[@]}"; do
            local hp2_path="/sys/devices/system/node/node${node}/hugepages/hugepages-2048kB/nr_hugepages"
            [ -f "$hp2_path" ] || continue
            local cur2
            cur2=$(cat "$hp2_path" 2>/dev/null || echo 0)
            if [ "$cur2" -lt 4096 ]; then
                echo 4096 > "$hp2_path" || true
                log_info "NUMA node $node: 回退 2MB hugepages -> $(cat "$hp2_path" 2>/dev/null || echo '?')"
            fi
        done

        # 重新挂载 hugetlbfs 为 2M 模式
        if mount | grep -q "/dev/hugepages" 2>/dev/null; then
            umount /dev/hugepages 2>/dev/null || true
        fi
        if mount -t hugetlbfs -o pagesize=2M nodev /dev/hugepages 2>/dev/null; then
            log_info "hugetlbfs 已重新挂载 (pagesize=2M)"
        else
            log_err "hugetlbfs 2M 回退挂载失败！"
        fi
    else
        log_info "大页内存验证: HugePages_Total=${actual_total} (${HUGEPAGE_SIZE})"
    fi

    log_info "大页内存配置完成"
}

# ===================== SPDK 驱动绑定 =====================
setup_spdk_driver() {
    log_step "SPDK 驱动绑定"

    if [ -n "$SPDK_SETUP" ] && [ -x "$SPDK_SETUP" ]; then
        log_info "执行 SPDK setup.sh 绑定 NVMe 设备到用户态驱动..."
        # HUGEMEM 单位是 MB: 1GB 模式 8*1024=8192MB; 2MB 模式 4096*2=8192MB
        local page_mb
        if [ "$HUGEPAGE_SIZE" = "1GB" ]; then
            page_mb=1024
        else
            page_mb=2
        fi
        HUGEMEM=$((HUGEPAGES_PER_NUMA_NODE * page_mb)) "$SPDK_SETUP" 2>&1 | tail -5 || true
        log_info "SPDK 驱动绑定完成 (HUGEMEM=$((HUGEPAGES_PER_NUMA_NODE * page_mb))MB)"
    else
        log_warn "未找到 SPDK setup.sh，请确保已手动执行过驱动绑定"
        log_warn "通常需要运行: \$SPDK_DIR/scripts/setup.sh"
    fi

    # 对仍绑在内核 nvme 驱动的设备尝试强制解绑并重绑到用户态驱动
    if [ "$FORCE_BIND_ALL" = "true" ]; then
        # 检测其他设备使用的用户态驱动，优先复用已绑定设备的驱动类型
        local target_drv="uio_pci_generic"
        for bdf in "${NVME_BDFS[@]}"; do
            local drv
            drv=$(basename "$(readlink "/sys/bus/pci/devices/${bdf}/driver" 2>/dev/null)" 2>/dev/null || true)
            if [[ "$drv" == "vfio-pci" || "$drv" == "uio_pci_generic" ]]; then
                target_drv="$drv"
                break
            fi
        done
        log_info "强制绑定模式: 目标用户态驱动 = $target_drv"
        modprobe "$target_drv" 2>/dev/null || true

        for bdf in "${NVME_BDFS[@]}"; do
            local sysfs_drv="/sys/bus/pci/devices/${bdf}/driver"
            local drv_name=""
            [ -L "$sysfs_drv" ] && drv_name=$(basename "$(readlink "$sysfs_drv")" 2>/dev/null || true)
            if [ "$drv_name" = "nvme" ]; then
                log_warn "  $bdf 仍绑定 nvme 驱动，尝试强制解绑并绑到 $target_drv ..."
                echo "$bdf" > "/sys/bus/pci/devices/${bdf}/driver/unbind" 2>/dev/null || {
                    log_warn "    解绑失败（设备可能正在被挂载使用），跳过"
                    continue
                }
                echo "$target_drv" > "/sys/bus/pci/devices/${bdf}/driver_override" 2>/dev/null || true
                echo "$bdf" > "/sys/bus/pci/drivers/${target_drv}/bind" 2>/dev/null || {
                    local vendor device
                    vendor=$(cat "/sys/bus/pci/devices/${bdf}/vendor" 2>/dev/null || true)
                    device=$(cat "/sys/bus/pci/devices/${bdf}/device" 2>/dev/null || true)
                    if [ -n "$vendor" ] && [ -n "$device" ]; then
                        echo "${vendor#0x} ${device#0x}" > "/sys/bus/pci/drivers/${target_drv}/new_id" 2>/dev/null || true
                        echo "$bdf" > "/sys/bus/pci/drivers/${target_drv}/bind" 2>/dev/null || true
                    fi
                }
                local new_drv
                new_drv=$(basename "$(readlink "/sys/bus/pci/devices/${bdf}/driver" 2>/dev/null)" 2>/dev/null || echo "未绑定")
                if [ "$new_drv" = "$target_drv" ]; then
                    log_info "    $bdf 已成功绑定到 $target_drv"
                else
                    log_warn "    $bdf 绑定失败，当前驱动: $new_drv"
                fi
            fi
        done
    fi

    # 验证每个已发现的 NVMe 设备是否成功绑定到用户态驱动
    # FORCE_BIND_ALL=false 时，仍绑内核 nvme 驱动的设备（如系统盘）会被自动剔除
    log_info "验证设备驱动绑定状态..."
    local valid_bdfs=()
    local valid_numas=()
    declare -A new_nvme_count=()
    declare -A new_nvme_idx=()

    for ((i=0; i<${#NVME_BDFS[@]}; i++)); do
        local bdf=${NVME_BDFS[$i]}
        local numa=${NVME_NUMA[$i]}
        local sysfs_path="/sys/bus/pci/devices/${bdf}/driver"
        local drv_name=""
        if [ -L "$sysfs_path" ]; then
            drv_name=$(basename "$(readlink "$sysfs_path")" 2>/dev/null || true)
        fi

        if [[ "$drv_name" != "nvme" ]]; then
            local count=${new_nvme_count[$numa]:-0}
            new_nvme_idx[$bdf]=$count
            new_nvme_count[$numa]=$((count + 1))
            valid_bdfs+=("$bdf")
            valid_numas+=("$numa")
            log_info "  $bdf -> 驱动: $drv_name"
        else
            log_warn "  $bdf -> 驱动: nvme (仍绑定内核驱动，已跳过; 如需强制绑定请设置 FORCE_BIND_ALL=true)"
        fi
    done

    if [ ${#valid_bdfs[@]} -eq 0 ]; then
        log_err "没有任何 NVMe 设备成功绑定到用户态驱动！"
        log_err "请检查 SPDK setup.sh 输出，或手动绑定设备"
        exit 1
    fi

    if [ ${#valid_bdfs[@]} -lt ${#NVME_BDFS[@]} ]; then
        log_warn "已从 ${#NVME_BDFS[@]} 个设备中过滤掉 $(( ${#NVME_BDFS[@]} - ${#valid_bdfs[@]} )) 个未绑定设备"
        # 更新全局数组
        NVME_BDFS=("${valid_bdfs[@]}")
        NVME_NUMA=("${valid_numas[@]}")
        NUMA_NVME_COUNT=()
        NUMA_NVME_IDX=()
        for key in "${!new_nvme_count[@]}"; do
            NUMA_NVME_COUNT[$key]=${new_nvme_count[$key]}
        done
        for key in "${!new_nvme_idx[@]}"; do
            NUMA_NVME_IDX[$key]=${new_nvme_idx[$key]}
        done
        # 清空预计算缓存（设备列表已变）
        ALLOC_CACHE=()
    fi
}

# ===================== 系统性能调优 =====================
tune_system() {
    log_step "系统性能调优"

    # 1. CPU frequency governor -> performance
    if command -v cpupower &>/dev/null; then
        cpupower frequency-set -g performance &>/dev/null && \
            log_info "CPU governor -> performance (cpupower)" || \
            log_warn "cpupower frequency-set 失败"
    elif [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$gov" 2>/dev/null || true
        done
        log_info "CPU governor -> performance (sysfs)"
    else
        log_warn "无法设置 CPU governor (未找到 cpupower 或 cpufreq)"
    fi

    # 2. 禁用 NMI watchdog (减少测试核心上的中断干扰)
    if [ -f /proc/sys/kernel/nmi_watchdog ]; then
        local nmi_val
        nmi_val=$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo 0)
        if [ "$nmi_val" != "0" ]; then
            echo 0 > /proc/sys/kernel/nmi_watchdog 2>/dev/null || true
            log_info "NMI watchdog 已禁用 (原值: $nmi_val)"
        else
            log_info "NMI watchdog 已处于禁用状态"
        fi
    fi

    # 3. 清理文件系统缓存
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    log_info "文件系统缓存已清理"

    # 4. 关闭 transparent hugepages (避免后台内存整理影响延迟)
    local thp_path="/sys/kernel/mm/transparent_hugepage/enabled"
    if [ -f "$thp_path" ]; then
        local thp_current
        thp_current=$(cat "$thp_path" 2>/dev/null || echo "")
        if [[ "$thp_current" != *"[never]"* ]]; then
            echo never > "$thp_path" 2>/dev/null || true
            echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
            log_info "Transparent Hugepages 已禁用"
        else
            log_info "Transparent Hugepages 已处于禁用状态"
        fi
    fi
}

# ===================== 拓扑发现 =====================
discover_topology() {
    log_step "发现 NVMe 设备和 NUMA 拓扑"

    local idx=0
    # pipefail 安全: grep 未匹配时返回 1，用 || true 防止 set -e 触发
    local nvme_list
    nvme_list=$(lspci -D 2>/dev/null | { grep -i "Non-Volatile memory controller" || true; } | awk '{print $1}')
    if [ -z "$nvme_list" ]; then
        log_err "未发现任何 NVMe 设备！"
        exit 1
    fi

    # 使用 sysfs 读取 NUMA affinity，比 lspci -vvv 每个设备快几个数量级
    for bdf in $nvme_list; do
        local numa
        numa=$(cat "/sys/bus/pci/devices/${bdf}/numa_node" 2>/dev/null || echo "")
        # sysfs 在无 NUMA 系统上可能返回 -1，统一归入 node 0
        [[ -z "$numa" || "$numa" == "-1" ]] && numa=0

        NVME_BDFS+=("$bdf")
        NVME_NUMA+=("$numa")

        local count=${NUMA_NVME_COUNT[$numa]:-0}
        NUMA_NVME_IDX[$bdf]=$count
        NUMA_NVME_COUNT[$numa]=$((count + 1))

        idx=$((idx + 1))
    done

    if [ ${#NVME_BDFS[@]} -eq 0 ]; then
        log_err "未发现任何 NVMe 设备！"
        exit 1
    fi

    # 读取各 NUMA 节点的核心列表
    local numa_nodes
    numa_nodes=($(printf '%s\n' "${NVME_NUMA[@]}" | sort -un))

    for node in "${numa_nodes[@]}"; do
        local cpulist_file="/sys/devices/system/node/node${node}/cpulist"
        if [ -f "$cpulist_file" ]; then
            local raw
            raw=$(cat "$cpulist_file" 2>/dev/null || echo "")
            local cores
            cores=$(python3 -c "
raw = '${raw}'
cpus = []
for seg in raw.split(','):
    seg = seg.strip()
    if '-' in seg:
        s, e = seg.split('-')
        cpus.extend(range(int(s), int(e)+1))
    else:
        cpus.append(int(seg))
print(' '.join(str(c) for c in cpus))
" 2>/dev/null || echo "")
            NUMA_CORES[$node]="$cores"
        else
            log_warn "无法读取 NUMA node $node 的 cpulist"
        fi
    done

    # 打印拓扑摘要
    # 注: 循环变量已在函数作用域内，不再重复使用 "local" 声明（Bash local 是函数级作用域）
    echo ""
    log_info "NVMe 设备拓扑:"
    local cpu0_warning=false
    if [ "$SKIP_CPU0" = "true" ]; then
        log_info "CPU0 排除模式已启用 (SKIP_CPU0=true)，CPU0 不参与核心分配"
    fi
    printf "  %-14s %-10s %-12s %-12s %-16s\n" "BDF" "NUMA" "总核心数" "设备数" "每设备可用核心"
    printf "  %-14s %-10s %-12s %-12s %-16s\n" "-----------" "--------" "----------" "----------" "--------------"
    for ((i=0; i<${#NVME_BDFS[@]}; i++)); do
        bdf=${NVME_BDFS[$i]}
        numa=${NVME_NUMA[$i]}
        local core_arr=(${NUMA_CORES[$numa]})
        local core_count=${#core_arr[@]}
        local effective_count=$core_count
        if [ "$SKIP_CPU0" = "true" ] && [ "$numa" = "0" ]; then
            effective_count=$((core_count - 1))  # CPU0 在 NUMA0
            cpu0_warning=true
        fi
        local dev_count=${NUMA_NVME_COUNT[$numa]}
        local cores_per_dev=$((effective_count / dev_count))
        printf "  %-14s %-10s %-12s %-12s %-16s\n" "$bdf" "$numa" "$core_count" "$dev_count" "$cores_per_dev"
    done
    if $cpu0_warning; then
        log_info "注: NUMA0 的 '每设备可用核心' 已扣除 CPU0"
    fi
    echo ""

    # 写入摘要日志
    {
        echo "=== NVMe Topology ==="
        echo "Date: $(date)"
        echo "SKIP_CPU0: $SKIP_CPU0"
        for ((i=0; i<${#NVME_BDFS[@]}; i++)); do
            bdf=${NVME_BDFS[$i]}
            numa=${NVME_NUMA[$i]}
            echo "  $bdf -> NUMA $numa (idx ${NUMA_NVME_IDX[$bdf]}/${NUMA_NVME_COUNT[$numa]})"
        done
        echo ""
    } >> "$SUMMARY_LOG"
}

# ===================== 核心分配 =====================
# 参数: $1=BDF, $2=请求核心数
# 输出: "core1,core2,...,coreN hex_mask actual_count"
# 策略: 同 NUMA 设备均分核心，不够则用分区内全部核心
#       SKIP_CPU0=true 时从 NUMA0 的分区中剔除 CPU0
allocate_cores() {
    local bdf=$1
    local num_requested=$2
    local cache_key="${bdf}:${num_requested}"

    # 命中缓存直接返回
    if [ -n "${ALLOC_CACHE[$cache_key]:-}" ]; then
        echo "${ALLOC_CACHE[$cache_key]}"
        return 0
    fi

    local numa=""
    for ((i=0; i<${#NVME_BDFS[@]}; i++)); do
        if [ "${NVME_BDFS[$i]}" = "$bdf" ]; then
            numa=${NVME_NUMA[$i]}
            break
        fi
    done

    local dev_idx=${NUMA_NVME_IDX[$bdf]}
    local dev_count=${NUMA_NVME_COUNT[$numa]}
    local all_cores=(${NUMA_CORES[$numa]})

    # 如果启用 SKIP_CPU0 且当前在 NUMA0，则从可用核心列表中移除 CPU0
    if [ "$SKIP_CPU0" = "true" ] && [ "$numa" = "0" ]; then
        local filtered=()
        for cpu in "${all_cores[@]}"; do
            [ "$cpu" -ne 0 ] && filtered+=("$cpu")
        done
        all_cores=("${filtered[@]}")
    fi

    local total=${#all_cores[@]}
    local partition_size=$((total / dev_count))
    local start=$((dev_idx * partition_size))
    local actual=$((num_requested < partition_size ? num_requested : partition_size))

    if [ "$actual" -lt "$num_requested" ]; then
        log_warn "$bdf: 请求 $num_requested 核，分区仅有 $partition_size 核，实际使用 $actual 核"
    fi

    # 取出对应分区的核心
    local selected=()
    for ((j=start; j<start+actual; j++)); do
        selected+=("${all_cores[$j]}")
    done

    # Python 生成 hex mask（支持任意核心编号，不溢出）
    local result
    result=$(python3 -c "
cores = [$(IFS=,; echo "${selected[*]}")]
mask = 0
for c in cores:
    mask |= (1 << c)
csv = ','.join(str(c) for c in cores)
print(f'{csv} {hex(mask)} {len(cores)}')
") || {
        log_err "$bdf: Python3 核心分配计算失败（Python3 环境异常）"
        return 1
    }

    ALLOC_CACHE[$cache_key]="$result"
    echo "$result"
}

# 预计算全部设备在各核心数下的分配方案（避免测试中反复 fork python）
precompute_allocations() {
    log_step "预计算核心分配"
    local core_counts=(1 2 4 8)
    for bdf in "${NVME_BDFS[@]}"; do
        for n in "${core_counts[@]}"; do
            if ! allocate_cores "$bdf" "$n" > /dev/null; then
                log_err "核心预计算失败: $bdf $n 核"
                exit 1
            fi
        done
    done
    log_info "已缓存 ${#ALLOC_CACHE[@]} 条分配方案"
}

# ===================== 运行单项 SPDK 测试 =====================
# 参数: test_name num_cores io_size_bytes workload iodepth runtime_sec
# 每设备独立日志文件: ${LOG_DIR}/${test_name}_dev${i}_${bdf_sanitized}.log
# 注意: wait 循环使用 "if ! wait $pid; then" 结构，if 条件内 errexit 自动抑制
run_spdk_test() {
    local test_name=$1
    local num_cores=$2
    local io_size=$3
    local workload=$4
    local iodepth=$5
    local runtime=$6

    echo ""
    echo "================================================================"
    log_step "$test_name"
    log_info "核心数/设备: $num_cores | IO大小: $io_size | 模式: $workload | 队列深度: $iodepth | 时长: ${runtime}s"
    echo "Start: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"

    local pids=()
    for ((i=0; i<${#NVME_BDFS[@]}; i++)); do
        local bdf=${NVME_BDFS[$i]}
        local result
        if ! result=$(allocate_cores "$bdf" "$num_cores"); then
            log_err "  $bdf: 核心分配失败，跳过此设备"
            continue
        fi
        local core_csv hex_mask actual_count
        core_csv=$(echo "$result" | awk '{print $1}')
        hex_mask=$(echo "$result" | awk '{print $2}')
        actual_count=$(echo "$result" | awk '{print $3}')

        # BDF 中的冒号替换为下划线（文件名不含冒号），末尾 .function 保留原样
        # 例: 0000:c1:00.0 -> 0000_c1_00.0
        local bdf_sanitized="${bdf//:/_}"
        local dev_log="${LOG_DIR}/${test_name}_dev${i}_${bdf_sanitized}.log"

        log_info "  $bdf -> cores [$core_csv] (${actual_count}核) mask $hex_mask (dev $i) -> $dev_log"

        # -i $i: 为每个实例指定唯一的 EAL 共享内存 ID，避免多进程并行时相互冲突
        # 用进程替换确保 $! 捕获的是 SPDK 的 PID（而非 tee 的 PID）
        $SPDK_PERF \
            -q "$iodepth" \
            -s "$SPDK_SHM_SIZE" \
            -w "$workload" \
            -t "$runtime" \
            -c "$hex_mask" \
            -o "$io_size" \
            -i "$i" \
            -r "trtype:PCIe traddr:${bdf}" \
            > >(tee -a "$dev_log") 2>&1 &
        SPDK_PIDS+=($!)
        pids+=($!)
    done

    # 等待所有后台进程（if 条件内 errexit 自动抑制，子进程非零退出不会中断循环）
    local all_ok=true
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            log_warn "进程 $pid 退出非零"
            all_ok=false
        fi
    done

    # 清理已退出的 PID，防止 SPDK_PIDS 无限增长（避免 Ctrl+C 时误操作复用 PID）
    SPDK_PIDS=()

    echo "End: $(date '+%Y-%m-%d %H:%M:%S')"

    # 记录到汇总
    {
        if $all_ok; then
            echo "[PASS] $test_name  $(date '+%H:%M:%S')"
        else
            echo "[WARN] $test_name  $(date '+%H:%M:%S')  (部分进程退出非零)"
        fi
    } >> "$SUMMARY_LOG"

    log_info "$test_name 完成 -> ${LOG_DIR}/${test_name}_dev*_*.log"
}

# ===================== 结果汇总解析 =====================
# 从单个 SPDK 日志文件中提取 Total 行性能数据
# 输出格式: "IOPS|MiB/s|Avg(us)|Min(us)|Max(us)"
parse_spdk_log() {
    local log_file=$1
    local total_line
    # SPDK perf 输出 Total 行格式:
    # Total                                                  :       IOPS      MiB/s    Average       min       max
    total_line=$(grep -E "^[[:space:]]*Total[[:space:]]+:" "$log_file" 2>/dev/null | tail -1 || true)
    if [ -z "$total_line" ]; then
        echo "N/A|N/A|N/A|N/A|N/A"
        return 0
    fi
    # 按冒号分割取右半部分，再按空白分割取字段
    local values
    values=$(echo "$total_line" | awk -F':' '{print $2}' | awk '{print $1, $2, $3, $4, $5}')
    if [ -z "$values" ]; then
        echo "N/A|N/A|N/A|N/A|N/A"
        return 0
    fi
    # 验证至少有一个有效数字字段（IOPS 应包含数字）
    local iops_val
    iops_val=$(echo "$values" | awk '{print $1}')
    if [[ "$iops_val" =~ ^[0-9] ]] || [[ "$iops_val" =~ ^\.[0-9] ]]; then
        echo "$values" | tr ' ' '|'
    else
        echo "N/A|N/A|N/A|N/A|N/A"
    fi
}

# 测试全部完成后生成性能汇总表格
generate_summary() {
    log_step "生成性能汇总表格"

    local results_table="${LOG_DIR}/99_performance_summary.txt"

    # 收集所有设备日志（命名格式: *_dev*_*.log），排除 summary 自身
    local all_logs
    all_logs=($(find "$LOG_DIR" -maxdepth 1 -name "*_dev*_*.log" -type f 2>/dev/null | sort || true))

    if [ ${#all_logs[@]} -eq 0 ]; then
        log_warn "未找到设备日志文件，无法生成汇总"
        return 0
    fi

    # 按 test_name 分组
    declare -A test_groups=()
    declare -a test_order=()
    for log in "${all_logs[@]}"; do
        local fname
        fname=$(basename "$log")
        # 从文件名提取 test_name: 如 01_128k_seqwrite_precondition_dev0_0000_c1_00.0.log
        # test_name 是最后一个 _dev 之前的部分
        local test_name
        test_name=$(echo "$fname" | sed 's/_dev[0-9]\+_.*//')
        if [ -z "${test_groups[$test_name]:-}" ]; then
            test_groups[$test_name]="$log"
            test_order+=("$test_name")
        else
            test_groups[$test_name]="${test_groups[$test_name]} $log"
        fi
    done

    # 生成表格
    {
        echo ""
        echo "========================================================================================================="
        echo "                              SPDK Performance Test Results Summary"
        echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================================================================================="
        echo ""
        printf "%-42s | %-18s | %12s | %10s | %11s | %9s | %9s\n" \
            "Test Name" "Device BDF" "IOPS" "MiB/s" "Avg Lat(us)" "Min(us)" "Max(us)"
        printf "%-42s-+-%-18s-+-%12s-+-%10s-+-%11s-+-%9s-+-%9s\n" \
            "------------------------------------------" "------------------" "------------" "----------" "-----------" "---------" "---------"

        for test_name in "${test_order[@]}"; do
            local logs_for_test=(${test_groups[$test_name]})
            local first_row=true
            local total_iops=0
            local total_mbps=0
            local all_numeric=true

            for log in "${logs_for_test[@]}"; do
                local fname bdf_display
                fname=$(basename "$log")
                # 从文件名提取 BDF:
                # 文件名格式: ${test_name}_dev${i}_${bdf_sanitized}.log
                # bdf_sanitized 将 : 替换为 _，. 保留原样 (如 0000_c1_00.0)
                # 提取后反向恢复: _ -> : 得到原始 BDF (如 0000:c1:00.0)
                local bdf_raw
                bdf_raw=$(echo "$fname" | sed 's/.*_dev[0-9]\+_//; s/\.log$//')
                bdf_display=$(echo "$bdf_raw" | sed 's/_/:/g')

                local parsed
                parsed=$(parse_spdk_log "$log")
                local iops mbps avg_lat min_lat max_lat
                iops=$(echo "$parsed" | awk -F'|' '{print $1}')
                mbps=$(echo "$parsed" | awk -F'|' '{print $2}')
                avg_lat=$(echo "$parsed" | awk -F'|' '{print $3}')
                min_lat=$(echo "$parsed" | awk -F'|' '{print $4}')
                max_lat=$(echo "$parsed" | awk -F'|' '{print $5}')

                # 行标签：第一行显示 test_name，后续行缩进
                local label
                if $first_row; then
                    label="$test_name"
                    first_row=false
                else
                    label="  (同上)"
                fi

                printf "%-42s | %-18s | %12s | %10s | %11s | %9s | %9s\n" \
                    "$label" "$bdf_display" "$iops" "$mbps" "$avg_lat" "$min_lat" "$max_lat"

                # 累加汇总行（仅当所有设备都有有效数值时）
                if [[ "$iops" =~ ^[0-9] ]] && [[ "$mbps" =~ ^[0-9] ]]; then
                    total_iops=$(python3 -c "print($total_iops + $iops)" 2>/dev/null || echo "N/A")
                    total_mbps=$(python3 -c "print($total_mbps + $mbps)" 2>/dev/null || echo "N/A")
                else
                    all_numeric=false
                fi
            done

            # 输出聚合行（跨设备合计）
            if [ ${#logs_for_test[@]} -gt 1 ] && $all_numeric; then
                printf "%-42s | %-18s | %12s | %10s | %11s | %9s | %9s\n" \
                    ">>> 合计 (${#logs_for_test[@]} 设备)" "" "$total_iops" "$total_mbps" "-" "-" "-"
            fi
            echo ""
        done

        echo "========================================================================================================="
        echo "  注: 数值直接从 SPDK 输出 'Total' 行提取，未经修改。"
        echo "      合计行的 IOPS 和 MiB/s 为各设备算术和（多设备并行条件下有意义）。"
        echo "========================================================================================================="
        echo ""
    } > "$results_table"

    # 输出到终端
    cat "$results_table"
    log_info "汇总表格已保存: $results_table"

    # 同时追加到 SUMMARY_LOG
    cat "$results_table" >> "$SUMMARY_LOG"
}

# ===================== 测试执行计划 =====================
# !!! 重要: 每次修改 run_all_tests（注释/取消注释测试项）后，
# !!! 必须同步更新下方 print_time_estimate() 中的时间估算。
run_all_tests() {
    echo "" >> "$SUMMARY_LOG"
    echo "=== Test Execution Log ===" >> "$SUMMARY_LOG"
    echo "" >> "$SUMMARY_LOG"

    # ---------------------------------------------------------------
    # Phase 1: 128k 顺序写预处理 (1核/设备, QD=1024, 4小时)
    # ---------------------------------------------------------------
    run_spdk_test "01_128k_seqwrite_precondition" 1 131072 write 1024 14400
    sleep "$SLEEP_BETWEEN_TESTS"

    # ---------------------------------------------------------------
    # Phase 2: 128k 顺序带宽测试 (1核/设备, QD=1024, 各1小时)
    # ---------------------------------------------------------------
    run_spdk_test "02_128k_seq_read_bandwidth"  1 131072 read  1024 3600
    sleep "$SLEEP_BETWEEN_TESTS"
    run_spdk_test "03_128k_seq_write_bandwidth" 1 131072 write 1024 3600
    sleep "$SLEEP_BETWEEN_TESTS"

    # ---------------------------------------------------------------
    # Phase 3: 4k 随机写预处理 (4核/设备, QD=1024, 8小时)
    # ---------------------------------------------------------------
    run_spdk_test "04_4k_randwrite_precondition" 4 4096 randwrite 1024 28800
    sleep "$SLEEP_BETWEEN_TESTS"

    # ---------------------------------------------------------------
    # Phase 4: 4k 延迟测试 (1核/设备, QD=1, 各0.5小时)
    # ---------------------------------------------------------------
    #run_spdk_test "05_4k_randread_latency"  1 4096 randread  1 1800
    #sleep "$SLEEP_BETWEEN_TESTS"
    #run_spdk_test "06_4k_randwrite_latency" 1 4096 randwrite 1 1800
    #sleep "$SLEEP_BETWEEN_TESTS"

    # ---------------------------------------------------------------
    # Phase 5: 4k IOPS 测试 - 1核 (QD=1024, 各1小时)
    # ---------------------------------------------------------------
    run_spdk_test "07_4k_1core_randread_iops"  1 4096 randread  1024 3600
    sleep "$SLEEP_BETWEEN_TESTS"
    run_spdk_test "08_4k_1core_randwrite_iops" 1 4096 randwrite 1024 3600
    sleep "$SLEEP_BETWEEN_TESTS"

    # ---------------------------------------------------------------
    # Phase 6: 4k IOPS 测试 - 2核 (QD=1024, 各1小时)
    # ---------------------------------------------------------------
    #run_spdk_test "09_4k_2cores_randread_iops"  2 4096 randread  1024 3600
    #sleep "$SLEEP_BETWEEN_TESTS"
    #run_spdk_test "10_4k_2cores_randwrite_iops" 2 4096 randwrite 1024 3600
    #sleep "$SLEEP_BETWEEN_TESTS"

    # ---------------------------------------------------------------
    # Phase 7: 4k IOPS 测试 - 4核 (QD=1024, 各1小时)
    # ---------------------------------------------------------------
    run_spdk_test "11_4k_4cores_randread_iops"  4 4096 randread  1024 3600
    sleep "$SLEEP_BETWEEN_TESTS"
    run_spdk_test "12_4k_4cores_randwrite_iops" 4 4096 randwrite 1024 3600
    sleep "$SLEEP_BETWEEN_TESTS"

    # ---------------------------------------------------------------
    # Phase 8: 4k IOPS 测试 - 8核 (QD=1024, 各1小时)
    # ---------------------------------------------------------------
    run_spdk_test "13_4k_8cores_randread_iops"  8 4096 randread  1024 3600
    sleep "$SLEEP_BETWEEN_TESTS"
    run_spdk_test "14_4k_8cores_randwrite_iops" 8 4096 randwrite 1024 3600
}

# ===================== 时间估算 =====================
# !!! 警告: 以下为手工估算，修改 run_all_tests 中的测试项后必须同步更新 !!!
print_time_estimate() {
    log_step "预估总运行时间"

    # Active tests (uncommented):
    # 01: 14400s  02: 3600s  03: 3600s  04: 28800s
    # 07: 3600s   08: 3600s
    # 11: 3600s   12: 3600s
    # 13: 3600s   14: 3600s
    # Total test time: 14400+3600+3600+28800+3600*6 = 72000s
    # Sleep between: ~11 * 60s = 660s
    local total_sec=$((14400 + 3600 + 3600 + 28800 + 3600*6 + 11*SLEEP_BETWEEN_TESTS))
    local hours=$((total_sec / 3600))
    local mins=$(( (total_sec % 3600) / 60 ))

    log_info "活跃测试项: 10 项"
    log_info "注释测试项: 4 项 (延迟测试 + 2核IOPS测试)"
    log_info "预估总时长: 约 ${hours} 小时 ${mins} 分钟"
    log_warn "注意: 此时间为手工估算，如需修改测试项请同步更新 print_time_estimate()"
    echo ""
}

# ===================== Main =====================
main() {
    echo ""
    echo "========================================================"
    echo "  SPDK NVMe Performance Test Suite (All-in-One)"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================================"
    echo ""

    preflight_check
    discover_topology
    print_time_estimate

    # ---- 人工确认：以下操作将修改系统状态 ----
    echo ""
    log_warn "================================================================"
    log_warn "  即将进行以下系统变更:"
    log_warn "  1. 绑定所有 NVMe 设备到 SPDK 用户态驱动 (uio_pci_generic/vfio-pci)"
    log_warn "  2. 配置 ${HUGEPAGE_SIZE} 大页内存 (每 NUMA 节点 ${HUGEPAGES_PER_NUMA_NODE} 个)"
    log_warn "  3. 修改 CPU governor 为 performance"
    log_warn "  4. 禁用 NMI watchdog / THP"
    log_warn "  5. 开始全自动性能测试（时长见上方估算）"
    log_warn "  按 Ctrl+C 可随时中断测试并自动清理后台进程"
    log_warn "================================================================"
    read -r -p "  确认继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "用户取消，脚本退出。"
        exit 0
    fi
    echo ""

    # 先配大页，再绑驱动（setup.sh 依赖大页环境就绪）
    setup_hugepages
    setup_spdk_driver
    tune_system
    precompute_allocations

    log_step "开始执行全部测试..."
    echo "=== 按 Ctrl+C 可中断测试 ==="
    echo ""

    local start_ts
    start_ts=$(date +%s)

    run_all_tests

    local end_ts
    end_ts=$(date +%s)
    local elapsed_min=$(( (end_ts - start_ts) / 60 ))

    echo ""
    echo "========================================================"
    echo "  全部测试完成"
    echo "  总耗时: ${elapsed_min} 分钟"
    echo "  日志目录: $LOG_DIR"
    echo "========================================================"

    # 追加到汇总日志
    {
        echo ""
        echo "=== Summary ==="
        echo "Total elapsed: ${elapsed_min} minutes"
        echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    } >> "$SUMMARY_LOG"

    # 生成性能汇总表格
    generate_summary

    log_info "汇总日志: $SUMMARY_LOG"
}

main "$@"

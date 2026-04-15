#!/bin/bash
#***********************************************************
# SPDK NVMe Performance Test for hygon 7493 system
# Author: Prz1y
#
# Features:
#   - 自动发现 NUMA 拓扑和 NVMe 设备
#   - 自动绑核（同 NUMA 多设备时均分 CCD 核心）
#   - 自动配置大页内存（hugepages）
#   - 全部测试项目整合，无外部脚本依赖
#
# Core Allocation Strategy:
#   同一 NUMA node 下的核心按 NVMe 设备数量均分，
#   例如 14 核 / 2 设备 = 每设备 7 核分区，
#   8 核测试时自动降为 min(8, 7) = 7 核。
#***********************************************************

set -uo pipefail

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
    all_nodes=($(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | sed 's/.*node//' | sort -n))

    for node in "${all_nodes[@]}"; do
        local hp_path="/sys/devices/system/node/node${node}/hugepages/${hp_dir}/nr_hugepages"
        if [ ! -f "$hp_path" ]; then
            log_warn "NUMA node $node 不支持 $HUGEPAGE_SIZE 大页"
            continue
        fi

        local current
        current=$(cat "$hp_path" 2>/dev/null || echo 0)
        if [ "$current" -lt "$HUGEPAGES_PER_NUMA_NODE" ]; then
            echo "$HUGEPAGES_PER_NUMA_NODE" > "$hp_path"
            local actual
            actual=$(cat "$hp_path")
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
                echo 0 > "$other_path" 2>/dev/null
                log_info "NUMA node $node: 已清除非目标大页 (${other_dir}: $other_cur -> 0)"
            fi
        fi
    done

    # 确保 hugetlbfs 已挂载（DPDK/SPDK 通过此文件系统访问大页）
    local mount_point="/dev/hugepages"
    local mount_pattern="hugetlbfs.*pagesize=${pagesize_mount}"
    
    if mount | grep -q "$mount_pattern"; then
        log_info "hugetlbfs 已挂载 (pagesize=${pagesize_mount})"
    else
        # 卸载不匹配的挂载
        if mount | grep -q "$mount_point"; then
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
    actual_total=$(grep -i "^HugePages_Total:" /proc/meminfo | awk '{print $2}')
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
                echo 4096 > "$hp2_path"
                log_info "NUMA node $node: 回退 2MB hugepages -> $(cat "$hp2_path")"
            fi
        done

        # 重新挂载 hugetlbfs 为 2M 模式
        if mount | grep -q "/dev/hugepages"; then
            umount /dev/hugepages 2>/dev/null || true
        fi
        mount -t hugetlbfs -o pagesize=2M nodev /dev/hugepages 2>/dev/null && \
            log_info "hugetlbfs 已重新挂载 (pagesize=2M)" || \
            log_err "hugetlbfs 2M 回退挂载失败！"
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
        HUGEMEM=$((HUGEPAGES_PER_NUMA_NODE * page_mb)) "$SPDK_SETUP" 2>&1 | tail -5
        log_info "SPDK 驱动绑定完成 (HUGEMEM=$((HUGEPAGES_PER_NUMA_NODE * page_mb))MB)"
    else
        log_warn "未找到 SPDK setup.sh，请确保已手动执行过驱动绑定"
        log_warn "通常需要运行: \$SPDK_DIR/scripts/setup.sh"
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
            echo performance > "$gov" 2>/dev/null
        done
        log_info "CPU governor -> performance (sysfs)"
    else
        log_warn "无法设置 CPU governor (未找到 cpupower 或 cpufreq)"
    fi

    # 2. 禁用 NMI watchdog (减少测试核心上的中断干扰)
    if [ -f /proc/sys/kernel/nmi_watchdog ]; then
        local nmi_val
        nmi_val=$(cat /proc/sys/kernel/nmi_watchdog)
        if [ "$nmi_val" != "0" ]; then
            echo 0 > /proc/sys/kernel/nmi_watchdog
            log_info "NMI watchdog 已禁用 (原值: $nmi_val)"
        else
            log_info "NMI watchdog 已处于禁用状态"
        fi
    fi

    # 3. 清理文件系统缓存
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    log_info "文件系统缓存已清理"

    # 4. 关闭 transparent hugepages (避免后台内存整理影响延迟)
    local thp_path="/sys/kernel/mm/transparent_hugepage/enabled"
    if [ -f "$thp_path" ]; then
        local thp_current
        thp_current=$(cat "$thp_path")
        if [[ "$thp_current" != *"[never]"* ]]; then
            echo never > "$thp_path" 2>/dev/null
            echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
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
    for bdf in $(lspci 2>/dev/null | grep -i "Non-Volatile memory controller" | awk '{print $1}'); do
        local numa
        numa=$(lspci -s "$bdf" -vvv 2>/dev/null | grep -i "NUMA node" | awk '{print $NF}')
        [ -z "$numa" ] && numa=0

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
            raw=$(cat "$cpulist_file")
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
")
            NUMA_CORES[$node]="$cores"
        else
            log_warn "无法读取 NUMA node $node 的 cpulist"
        fi
    done

    # 打印拓扑摘要
    echo ""
    log_info "NVMe 设备拓扑:"
    printf "  %-14s %-10s %-12s %-12s %-16s\n" "BDF" "NUMA" "总核心数" "设备数" "每设备可用核心"
    printf "  %-14s %-10s %-12s %-12s %-16s\n" "-----------" "--------" "----------" "----------" "--------------"
    for ((i=0; i<${#NVME_BDFS[@]}; i++)); do
        local bdf=${NVME_BDFS[$i]}
        local numa=${NVME_NUMA[$i]}
        local core_arr=(${NUMA_CORES[$numa]})
        local core_count=${#core_arr[@]}
        local dev_count=${NUMA_NVME_COUNT[$numa]}
        local cores_per_dev=$((core_count / dev_count))
        printf "  %-14s %-10s %-12s %-12s %-16s\n" "$bdf" "$numa" "$core_count" "$dev_count" "$cores_per_dev"
    done
    echo ""

    # 写入摘要日志
    {
        echo "=== NVMe Topology ==="
        echo "Date: $(date)"
        for ((i=0; i<${#NVME_BDFS[@]}; i++)); do
            local bdf=${NVME_BDFS[$i]}
            local numa=${NVME_NUMA[$i]}
            echo "  $bdf -> NUMA $numa (idx ${NUMA_NVME_IDX[$bdf]}/${NUMA_NVME_COUNT[$numa]})"
        done
        echo ""
    } >> "$SUMMARY_LOG"
}

# ===================== 核心分配 =====================
# 参数: $1=BDF, $2=请求核心数
# 输出: "core1,core2,...,coreN hex_mask actual_count"
# 策略: 同 NUMA 设备均分核心，不够则用分区内全部核心
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
")
    ALLOC_CACHE[$cache_key]="$result"
    echo "$result"
}

# 预计算全部设备在各核心数下的分配方案（避免测试中反复 fork python）
precompute_allocations() {
    log_step "预计算核心分配"
    local core_counts=(1 2 4 8)
    for bdf in "${NVME_BDFS[@]}"; do
        for n in "${core_counts[@]}"; do
            allocate_cores "$bdf" "$n" > /dev/null
        done
    done
    log_info "已缓存 ${#ALLOC_CACHE[@]} 条分配方案"
}

# ===================== 运行单项 SPDK 测试 =====================
# 参数: test_name num_cores io_size_bytes workload iodepth runtime_sec
run_spdk_test() {
    local test_name=$1
    local num_cores=$2
    local io_size=$3
    local workload=$4
    local iodepth=$5
    local runtime=$6
    local log_file="${LOG_DIR}/${test_name}.log"

    echo ""
    echo "================================================================" | tee -a "$log_file"
    log_step "$test_name"
    log_info "核心数/设备: $num_cores | IO大小: $io_size | 模式: $workload | 队列深度: $iodepth | 时长: ${runtime}s"
    echo "Start: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$log_file"
    echo "================================================================" | tee -a "$log_file"

    local pids=()
    for ((i=0; i<${#NVME_BDFS[@]}; i++)); do
        local bdf=${NVME_BDFS[$i]}
        local result
        result=$(allocate_cores "$bdf" "$num_cores")
        local core_csv hex_mask actual_count
        core_csv=$(echo "$result" | awk '{print $1}')
        hex_mask=$(echo "$result" | awk '{print $2}')
        actual_count=$(echo "$result" | awk '{print $3}')

        log_info "  $bdf -> cores [$core_csv] (${actual_count}核) mask $hex_mask"

        # 用进程替换确保 $! 捕获的是 SPDK 的 PID（而非 tee 的 PID）
        $SPDK_PERF \
            -q "$iodepth" \
            -s "$SPDK_SHM_SIZE" \
            -w "$workload" \
            -t "$runtime" \
            -c "$hex_mask" \
            -o "$io_size" \
            -r "trtype:PCIe traddr:${bdf}" \
            > >(tee -a "$log_file") 2>&1 &
        pids+=($!)
    done

    # 等待所有后台进程
    local all_ok=true
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            log_warn "进程 $pid 退出非零"
            all_ok=false
        fi
    done

    echo "End: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$log_file"

    # 记录到汇总
    {
        if $all_ok; then
            echo "[PASS] $test_name  $(date '+%H:%M:%S')"
        else
            echo "[WARN] $test_name  $(date '+%H:%M:%S')  (部分进程退出非零)"
        fi
    } >> "$SUMMARY_LOG"

    log_info "$test_name 完成 -> $log_file"
}

# ===================== 测试执行计划 =====================
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
    setup_spdk_driver
    setup_hugepages
    tune_system
    precompute_allocations
    print_time_estimate

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
    echo "  日志: $LOG_DIR"
    echo "========================================================"

    # 追加到汇总日志
    {
        echo ""
        echo "=== Summary ==="
        echo "Total elapsed: ${elapsed_min} minutes"
        echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    } >> "$SUMMARY_LOG"

    log_info "汇总日志: $SUMMARY_LOG"
}

main "$@"

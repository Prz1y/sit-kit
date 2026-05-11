#!/bin/bash
# ============================================================================
# nvme_ali_qual_storage_perf.sh
# 版本   : 2.0
# 作者   : SIT-Kit / Prz1y
# 更新   : 2026-04
# ----------------------------------------------------------------------------
# 说明:
#   单盘 + 多盘联合测试，覆盖:
#     - 1024K 顺序读/写 (QD64, jobs=1/4)
#     - 4K 随机读/写 (QD64, jobs=1/4)
#     - 4K 随机读/写 Latency (QD1, jobs=1)
#   测试前: SMART 标准1 收集、OS/SEL 日志清除。
#   测试后: SMART 标准2 收集、OS/SEL 日志收集（不做判定）。
#
# 环境要求:
#   - RHEL 7 / 8 / 9
#   - Root 权限
#   - NVMe 直连硬盘（无 RAID 卡 / SAS 卡）
#   - fio、nvme-cli、smartmontools、ipmitool 已安装
#
# 使用方法:
#   1. 编辑下方 [ 核心配置区 ] 中的 TARGET_DEVS、RUN_* 开关。
#   2. sudo bash nvme_ali_qual_storage_perf.sh
# ============================================================================

set -euo pipefail

###############################################################################
# [ 核心配置区 ]  ← 运行前只需修改这里
###############################################################################

# 待测 NVMe 块设备列表（用空格分隔）
TARGET_DEVS=("/dev/nvme0n1" "/dev/nvme1n1")

# ---------- 功能开关 (yes/no) ----------
RUN_PRE_CHECK="yes"          # 一. 测试前: SMART标准1收集 + OS/SEL日志清除
RUN_SINGLE_DISK="yes"        # 单盘性能测试 (逐个盘跑)
RUN_MULTI_DISK="yes"         # 多盘联合性能测试 (所有盘一起跑)
RUN_POST_CHECK="yes"         # 七. 测试后: SMART标准2收集 + OS/SEL日志收集

# ---------- 测试参数 ----------
RUNTIME=600                  # 正式测试单轮时长（秒），10分钟

SEQ_THREADS=(1 4)            # 顺序读/写 线程数列表 (1024K)
RAND_THREADS=(1 4)           # 随机读/写 线程数列表 (4K)
QUEUE_DEPTH=64               # 带宽/IOPS 测试用队列深度

###############################################################################
# [ 工具函数 ]
###############################################################################
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/NVME_ALI_QUAL_${TIMESTAMP}"
LOG_DIR="${BASE_DIR}/logs"
SMART_DIR="${BASE_DIR}/smart_logs"
PERF_DIR="${BASE_DIR}/perf_data"
MON_DIR="${BASE_DIR}/monitor"
SEL_DIR="${BASE_DIR}/sel_logs"
RUN_LOG="${LOG_DIR}/run.log"
# 注: 目录创建移至 main() 中 require_root 之后，避免非 root 时在受保护路径上报错
log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$RUN_LOG"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$RUN_LOG" >&2; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$RUN_LOG" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 身份运行此脚本 (sudo bash $0)"
        exit 1
    fi
}

check_deps() {
    local missing_tools=()
    for tool in fio nvme smartctl lspci; do
        command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
    done
    command -v ipmitool >/dev/null 2>&1 || log_warn "ipmitool 未安装，将跳过 BMC SEL 采集"

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "缺少必要工具: ${missing_tools[*]}"
        log_error "请安装: yum/apt-get install -y fio nvme-cli smartmontools pciutils"
        exit 1
    fi
    log_info "依赖检查通过"
}

get_dev_tag() {
    basename "$1"
}

device_check() {
    for dev in "${TARGET_DEVS[@]}"; do
        if [[ ! -b "$dev" ]]; then
            log_error "块设备 '$dev' 不存在或无效"
            exit 1
        fi
    done
    log_info "待测设备: ${TARGET_DEVS[*]}"
}

###############################################################################
# [ 一. 测试前环境检查与准备 ]
###############################################################################

smart_standard1_collect() {
    log_info "===== SMART 标准1 收集（测试前）====="
    for dev in "${TARGET_DEVS[@]}"; do
        local dev_tag
        dev_tag="$(get_dev_tag "$dev")"
        local smart_out="${SMART_DIR}/pre_standard1_${dev_tag}.log"

        if [[ "$dev" =~ nvme ]]; then
            nvme smart-log "$dev" > "$smart_out" 2>&1 || {
                log_warn "$dev_tag: nvme smart-log 失败"
                continue
            }
        else
            smartctl -a "$dev" > "$smart_out" 2>&1 || {
                log_warn "$dev_tag: smartctl 失败"
                continue
            }
        fi
        log_info "$dev_tag: SMART 日志已保存 -> $smart_out"
    done
    log_info "SMART 标准1 收集完成"
}

os_log_clean() {
    log_info "===== OS 日志清除 ====="
    dmesg -C 2>/dev/null || log_warn "dmesg -C 失败"

    echo "$(date '+%Y-%m-%d %H:%M:%S')" > "${LOG_DIR}/os_log_clean_marker.txt"
    log_info "OS 日志已清除，标记时间: $(cat ${LOG_DIR}/os_log_clean_marker.txt)"
}

sel_log_clean() {
    log_info "===== SEL 日志清除 ====="
    if command -v ipmitool >/dev/null 2>&1; then
        ipmitool sel elist > "${SEL_DIR}/sel_pre_clear.elist" 2>&1 || true
        log_info "当前 SEL 已保存到 ${SEL_DIR}/sel_pre_clear.elist"

        ipmitool sel clear 2>&1 || log_warn "ipmitool sel clear 失败"
        log_info "SEL 日志已清除"
    else
        log_warn "ipmitool 未安装，跳过 SEL 清除"
    fi
}

###############################################################################
# [ FIO 通用执行引擎 ]
###############################################################################

run_fio() {
    local job_name="$1"
    local display_name="$2"
    local fio_filename="$3"
    local rw="$4"
    local bs="$5"
    local iodepth="$6"
    local numjobs="$7"
    local runtime="$8"
    local extra_flags="${9:-}"

    local json_out="${PERF_DIR}/${job_name}_${display_name}_${rw}_${bs/ /}_${numjobs}j_${iodepth}qd.json"
    local mon_out="${MON_DIR}/${job_name}_${display_name}_iostat.log"

    log_info "启动: $job_name | dev=$display_name | rw=$rw | bs=$bs | jobs=$numjobs | qd=$iodepth | runtime=${runtime}s"

    # 后台启动 iostat 监控
    local first_dev="${fio_filename%%:*}"
    iostat -xmt 10 "$first_dev" > "$mon_out" 2>&1 &
    local iostat_pid=$!

    fio --name="${job_name}" --filename="${fio_filename}" \
        --rw="${rw}" --bs="${bs}" \
        --iodepth="${iodepth}" --numjobs="${numjobs}" \
        --direct=1 --ioengine=libaio --thread=1 \
        --group_reporting --time_based=1 --runtime="${runtime}" \
        --size=100% \
        --norandommap=1 --randrepeat=0 \
        --output-format=json --output="${json_out}" \
        --end_fsync=0 --buffer_compress_percentage=0 \
        --invalidate=1 --refill_buffers --exitall \
        ${extra_flags:+$extra_flags} 2>&1 || log_warn "fio 退出码非0，请检查日志: ${json_out}"

    kill "$iostat_pid" 2>/dev/null || true
    wait "$iostat_pid" 2>/dev/null || true

    log_info "完成: $job_name -> ${json_out}"
}

###############################################################################
# [ 性能测试 — 单盘 ]
###############################################################################

run_single_disk_tests() {
    log_info "==================== 单盘性能测试 ===================="

    for dev in "${TARGET_DEVS[@]}"; do
        local dev_tag
        dev_tag="$(get_dev_tag "$dev")"
        log_info "--------------- 单盘: $dev_tag ---------------"

        local -a tests=()
        local tidx=0

        for nj in "${SEQ_THREADS[@]}"; do
            tests[$tidx]="sread|read|1024k|$nj|$QUEUE_DEPTH|"
            tidx=$((tidx + 1))
        done
        for nj in "${SEQ_THREADS[@]}"; do
            tests[$tidx]="swrite|write|1024k|$nj|$QUEUE_DEPTH|"
            tidx=$((tidx + 1))
        done
        for nj in "${RAND_THREADS[@]}"; do
            tests[$tidx]="rread|randread|4k|$nj|$QUEUE_DEPTH|"
            tidx=$((tidx + 1))
        done
        for nj in "${RAND_THREADS[@]}"; do
            tests[$tidx]="rwrite|randwrite|4k|$nj|$QUEUE_DEPTH|"
            tidx=$((tidx + 1))
        done

        # Latency 测试: QD1, jobs=1
        tests[$tidx]="rread_lat|randread|4k|1|1|"
        tidx=$((tidx + 1))
        tests[$tidx]="rwrite_lat|randwrite|4k|1|1|"
        tidx=$((tidx + 1))

        for entry in "${tests[@]}"; do
            IFS='|' read -r job_prefix rw bs nj qd xtra <<< "$entry"
            local job_name="single_${job_prefix}"
            run_fio "$job_name" "$dev_tag" "$dev" "$rw" "$bs" "$qd" "$nj" "$RUNTIME" "$xtra"
        done

        log_info "--------------- 单盘 $dev_tag 完成 ---------------"
    done

    log_info "==================== 单盘性能测试 全部完成 ===================="
}

###############################################################################
# [ 性能测试 — 多盘联合 ]
###############################################################################

run_multi_disk_tests() {
    log_info "==================== 多盘联合性能测试 ===================="

    local multi_filename=""
    for dev in "${TARGET_DEVS[@]}"; do
        if [[ -z "$multi_filename" ]]; then
            multi_filename="$dev"
        else
            multi_filename="${multi_filename}:${dev}"
        fi
    done
    log_info "多盘联合 filename: $multi_filename"

    local -a tests=()
    local tidx=0

    for nj in "${SEQ_THREADS[@]}"; do
        tests[$tidx]="sread|read|1024k|$nj|$QUEUE_DEPTH|"
        tidx=$((tidx + 1))
    done
    for nj in "${SEQ_THREADS[@]}"; do
        tests[$tidx]="swrite|write|1024k|$nj|$QUEUE_DEPTH|"
        tidx=$((tidx + 1))
    done
    for nj in "${RAND_THREADS[@]}"; do
        tests[$tidx]="rread|randread|4k|$nj|$QUEUE_DEPTH|"
        tidx=$((tidx + 1))
    done
    for nj in "${RAND_THREADS[@]}"; do
        tests[$tidx]="rwrite|randwrite|4k|$nj|$QUEUE_DEPTH|"
        tidx=$((tidx + 1))
    done

    # Latency 测试: QD1, jobs=1
    tests[$tidx]="rread_lat|randread|4k|1|1|"
    tidx=$((tidx + 1))
    tests[$tidx]="rwrite_lat|randwrite|4k|1|1|"
    tidx=$((tidx + 1))

    for entry in "${tests[@]}"; do
        IFS='|' read -r job_prefix rw bs nj qd xtra <<< "$entry"
        local job_name="multi_${job_prefix}"
        run_fio "$job_name" "multi" "$multi_filename" "$rw" "$bs" "$qd" "$nj" "$RUNTIME" "$xtra"
    done

    log_info "==================== 多盘联合性能测试 完成 ===================="
}

###############################################################################
# [ 七. 测试后日志检查（仅收集，不判定） ]
###############################################################################

os_log_post_collect() {
    log_info "===== OS 日志收集（测试后）====="

    dmesg > "${LOG_DIR}/dmesg_post.log" 2>&1 || true
    log_info "dmesg 已保存: ${LOG_DIR}/dmesg_post.log"

    local clean_marker="${LOG_DIR}/os_log_clean_marker.txt"
    if [[ -f "$clean_marker" ]]; then
        if command -v journalctl >/dev/null 2>&1; then
            journalctl --since="$(cat "$clean_marker")" --no-pager \
                > "${LOG_DIR}/journalctl_post.log" 2>&1 || true
            log_info "journalctl 已保存: ${LOG_DIR}/journalctl_post.log"
        fi
    fi

    if [[ -f /var/log/messages ]]; then
        cp /var/log/messages "${LOG_DIR}/messages_post.log" 2>/dev/null || true
        log_info "messages 已保存: ${LOG_DIR}/messages_post.log"
    fi

    log_info "OS 日志收集完成"
}

sel_log_post_collect() {
    log_info "===== SEL 日志收集（测试后）====="
    if command -v ipmitool >/dev/null 2>&1; then
        ipmitool sel elist > "${SEL_DIR}/sel_post.elist" 2>&1 || true
        log_info "测试后 SEL 已保存: ${SEL_DIR}/sel_post.elist"
    else
        log_warn "ipmitool 未安装，跳过 SEL 收集"
    fi
}

smart_standard2_collect() {
    log_info "===== SMART 标准2 收集（测试后）====="
    for dev in "${TARGET_DEVS[@]}"; do
        local dev_tag
        dev_tag="$(get_dev_tag "$dev")"
        local smart_out="${SMART_DIR}/post_standard2_${dev_tag}.log"

        if [[ "$dev" =~ nvme ]]; then
            nvme smart-log "$dev" > "$smart_out" 2>&1 || {
                log_warn "$dev_tag: nvme smart-log 失败"
                continue
            }
        else
            smartctl -a "$dev" > "$smart_out" 2>&1 || {
                log_warn "$dev_tag: smartctl 失败"
                continue
            }
        fi
        log_info "$dev_tag: 测试后 SMART 已保存 -> $smart_out"
    done
    log_info "SMART 标准2 收集完成"
}

###############################################################################
# [ 主流程 ]
###############################################################################

main() {
    require_root
    mkdir -p "$LOG_DIR" "$SMART_DIR" "$PERF_DIR" "$MON_DIR" "$SEL_DIR"
    check_deps
    device_check

    # 一. 测试前环境检查与准备
    if [[ "$RUN_PRE_CHECK" == "yes" ]]; then
        smart_standard1_collect
        os_log_clean
        sel_log_clean
    else
        log_info "跳过: 测试前环境检查与准备 (RUN_PRE_CHECK=no)"
    fi

    # 单盘性能测试
    if [[ "$RUN_SINGLE_DISK" == "yes" ]]; then
        run_single_disk_tests
    else
        log_info "跳过: 单盘性能测试 (RUN_SINGLE_DISK=no)"
    fi

    # 多盘联合性能测试
    if [[ "$RUN_MULTI_DISK" == "yes" ]]; then
        run_multi_disk_tests
    else
        log_info "跳过: 多盘联合性能测试 (RUN_MULTI_DISK=no)"
    fi

    # 七. 测试后日志检查
    if [[ "$RUN_POST_CHECK" == "yes" ]]; then
        os_log_post_collect
        sel_log_post_collect
        smart_standard2_collect
    else
        log_info "跳过: 测试后日志检查 (RUN_POST_CHECK=no)"
    fi

    log_info "============================================================"
    log_info " 测试完成，数据目录: $BASE_DIR"
    log_info " 性能 JSON: $PERF_DIR/"
    log_info " SMART 日志: $SMART_DIR/"
    log_info " 监控日志: $MON_DIR/"
    log_info " 系统日志: $LOG_DIR/"
    log_info " SEL 日志: $SEL_DIR/"
    log_info "============================================================"
}

main "$@"

#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/memory_pressure_logs"
START_FLAG="${LOG_DIR}/.test_running"
START_TIME_FILE="${LOG_DIR}/pressure_start_time.log"
END_TIME_FILE="${LOG_DIR}/pressure_end_time.log"
MEMTESTER_LOG="${LOG_DIR}/memtester.log"
NMON_PID_FILE="${LOG_DIR}/.nmon_pid"
MEMTESTER_PID_FILE="${LOG_DIR}/.memtester_pid"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S')  请使用 root 权限执行此脚本"
        exit 1
    fi
}

check_prerequisites() {
    local missing=0
    for cmd in memtester nmon bc dmidecode; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S')  缺少依赖: $cmd"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  所有依赖检查通过 (memtester / nmon / bc / dmidecode)"
}

check_test_running() {
    if [ -f "$START_FLAG" ]; then
        if pgrep -f "memtester" > /dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

do_start() {
    check_root
    check_prerequisites

    if check_test_running; then
        echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S')  内存压力测试已在运行中"
        echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S')  如需重新开始，请先执行: $0 stop"
        exit 1
    fi

    mkdir -p "$LOG_DIR"
    rm -f "${LOG_DIR}"/*.log "${LOG_DIR}"/.nmon_pid "${LOG_DIR}"/.memtester_pid
    exec &> >(tee -a "${LOG_DIR}/console_output.log")

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  Step 1: 清除历史日志..."
    dmesg -C
    echo "" > /var/log/messages 2>/dev/null || true
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  dmesg / messages 日志已清除"

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  Step 2: 记录测试开始时间..."
    date '+%Y-%m-%d %H:%M:%S' | tee "$START_TIME_FILE"
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  测试开始时间已记录: $(cat "$START_TIME_FILE")"

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  Step 3: 收集 dmidecode 内存信息..."
    dmidecode -t memory > "${LOG_DIR}/dmidecode_memory.log" 2>&1
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  dmidecode 内存信息已保存至: ${LOG_DIR}/dmidecode_memory.log"

    echo ""
    echo "========== 内存模块摘要 (dmidecode) =========="
    echo "Manufacturer :"
    grep -i "Manufacturer:" "${LOG_DIR}/dmidecode_memory.log" | grep -v "NO DIMM\|Not Specified\|Unknown\|\[Empty\]" | sort -u || echo "  (未找到)"
    echo "Size         :"
    grep -i "Size:" "${LOG_DIR}/dmidecode_memory.log" | grep -v "No Module Installed" | sort -u || echo "  (未找到)"
    echo "Speed        :"
    grep -i "Speed:" "${LOG_DIR}/dmidecode_memory.log" | grep -v "Unknown" | sort -u || echo "  (未找到)"
    echo "Part Number  :"
    grep -i "Part Number:" "${LOG_DIR}/dmidecode_memory.log" | grep -v "NO DIMM\|Not Specified\|\[Empty\]" | sort -u || echo "  (未找到)"
    echo "=============================================="
    echo ""

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  Step 4: 收集测试前温度传感器数据..."
    if command -v ipmitool &>/dev/null; then
        ipmitool sensor list > "${LOG_DIR}/sensor_before.log" 2>/dev/null || echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S')  ipmitool sensor list 执行失败"
        echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  传感器数据已保存至: ${LOG_DIR}/sensor_before.log"
    else
        echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  ipmitool not found, skipping temperature collection"
    fi

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  Step 5: 关闭 swap..."
    swapoff -a 2>/dev/null || true
    local swap_status
    swap_status=$(free -m | awk '/Swap/{print $2}')
    if [ "$swap_status" = "0" ]; then
        echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  swap 已成功关闭"
    else
        echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S')  swap 可能未完全关闭, 当前 swap 总量: ${swap_status}MB"
    fi

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  Step 6: 计算内存加压容量..."
    local total_kb total_gb test_mb
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_gb=$(echo "scale=2; $total_kb / 1024 / 1024" | bc)
    test_mb=$(echo "$total_kb * 0.9 / 1024" | bc | cut -d. -f1)
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  系统总内存: ${total_gb} GB (${total_kb} KB)"
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  加压容量:   ${test_mb} MB (总内存的 90%)"

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  Step 7: 启动 nmon 监控 (每60秒采集, 持续48H)..."
    nmon -f -s 60 -c 2880 -t -m "$LOG_DIR" &
    local nmon_pid=$!
    echo "$nmon_pid" > "$NMON_PID_FILE"
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  nmon 已启动, PID: $nmon_pid"

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  Step 8: 启动 memtester 压力测试 (48H 超时自动停止)..."
    nohup timeout 172800 memtester "${test_mb}M" 2>&1 | tr -d '\b' | grep -vE 'setting|testing' > "$MEMTESTER_LOG" &
    local memtester_pid=$!
    echo "$memtester_pid" > "$MEMTESTER_PID_FILE"
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  memtester 已启动, 管道 PID: $memtester_pid (172800s 后自动停止)"

    touch "$START_FLAG"

    echo ""
    echo "=============================================="
    echo "  内存压力测试 (48H) - 已启动"
    echo "=============================================="
    echo "  测试开始时间: $(cat "$START_TIME_FILE")"
    echo "  预计完成时间: $(date -d '+48 hours' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '48 小时后')"
    echo "----------------------------------------------"
    echo "  注意事项:"
    echo "  1. 锁定系统屏幕"
    echo "  2. 封条封闭机箱盖、外设接口、网络管理端口、电源风扇"
    echo "  3. 48 小时后执行: $0 stop"
    echo "  4. 查看状态:      $0 status"
    echo "=============================================="
    echo ""
}

do_stop() {
    check_root
    mkdir -p "$LOG_DIR"
    exec &> >(tee -a "${LOG_DIR}/console_output.log")

    if ! check_test_running; then
        if [ -f "$START_FLAG" ]; then
            echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S')  未检测到正在运行的测试进程, 但发现残留标记文件, 将继续收集日志"
        else
            echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S')  测试未在运行, 无需停止"
            exit 1
        fi
    fi

    echo ""
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  ========== 停止 48H 内存压力测试 =========="

    if [ -f "$MEMTESTER_PID_FILE" ]; then
        local pid
        pid=$(cat "$MEMTESTER_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  停止 memtester (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
            echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  memtester 已停止"
        else
            echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  memtester 已自行结束"
        fi
    fi

    if [ -f "$NMON_PID_FILE" ]; then
        local pid
        pid=$(cat "$NMON_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  停止 nmon (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  nmon 已停止"
        fi
    fi

    pkill -f "memtester" 2>/dev/null || true

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  记录测试结束时间..."
    date '+%Y-%m-%d %H:%M:%S' | tee "$END_TIME_FILE"
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  测试结束时间已记录: $(cat "$END_TIME_FILE")"

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  收集测试后温度传感器数据..."
    if command -v ipmitool &>/dev/null; then
        ipmitool sensor list > "${LOG_DIR}/sensor_after.log" 2>/dev/null || echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S')  ipmitool sensor list 执行失败"
        echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  传感器数据已保存至: ${LOG_DIR}/sensor_after.log"
    else
        echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  ipmitool not found, skipping temperature collection"
    fi

    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  收集主机日志..."
    dmesg > "${LOG_DIR}/dmesg_pressure.log"
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  已保存: ${LOG_DIR}/dmesg_pressure.log"

    cat /var/log/messages > "${LOG_DIR}/messages_pressure.log" 2>/dev/null || true
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  已保存: ${LOG_DIR}/messages_pressure.log"

    mcelog > "${LOG_DIR}/mcelog_pressure.log" 2>&1 || true
    echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  已保存: ${LOG_DIR}/mcelog_pressure.log"

    if [ -f "$MEMTESTER_LOG" ]; then
        echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S')  memtester 日志: $MEMTESTER_LOG"
    fi

    rm -f "$START_FLAG" "$MEMTESTER_PID_FILE" "$NMON_PID_FILE"

    echo ""
    echo "=============================================="
    echo "  内存压力测试 (48H) - 结果汇总"
    echo "=============================================="

    if [ -f "$START_TIME_FILE" ]; then
        echo "  开始时间: $(cat "$START_TIME_FILE")"
    fi
    if [ -f "$END_TIME_FILE" ]; then
        echo "  结束时间: $(cat "$END_TIME_FILE")"
    fi

    local swap_total
    swap_total=$(free -m | awk '/Swap/{print $2}')
    if [ "$swap_total" = "0" ]; then
        echo "  swap 状态: 已关闭 OK"
    else
        echo "  swap 状态: ${swap_total}MB (未关闭, 请检查)"
    fi

    if [ -f "$MEMTESTER_LOG" ]; then
        local last_line
        last_line=$(tail -1 "$MEMTESTER_LOG" 2>/dev/null || echo "")
        if echo "$last_line" | grep -qi "ok\|done\|success\|finished"; then
            echo "  memtester: 正常结束 OK"
        elif echo "$last_line" | grep -qi "fail\|error"; then
            echo "  memtester: 有错误, 请检查日志"
        fi
        local total_lines
        total_lines=$(wc -l < "$MEMTESTER_LOG")
        echo "  memtester 日志行数: ${total_lines}"
    fi

    local dmesg_err
    dmesg_err=$(grep -ciE "error|fail|warn|BUG|Call Trace|Oops" "${LOG_DIR}/dmesg_pressure.log" 2>/dev/null; true)
    dmesg_err=$(echo "$dmesg_err" | tr -d '[:space:]')
    if [ -z "$dmesg_err" ] || [ "$dmesg_err" = "0" ]; then
        echo "  dmesg 异常计数: 0 OK"
    else
        echo "  dmesg 异常计数: ${dmesg_err} (请检查日志)"
    fi

    echo "----------------------------------------------"
    echo "  日志文件列表:"
    if [ -d "$LOG_DIR" ]; then
        ls -lh "$LOG_DIR" 2>/dev/null | tail -n +2 | while read -r line; do
            echo "    $line"
        done
    fi
    echo "----------------------------------------------"
    echo "  所有日志保存在: ${LOG_DIR}"
    echo "=============================================="
    echo ""
}

do_status() {
    mkdir -p "$LOG_DIR"
    exec &> >(tee -a "${LOG_DIR}/console_output.log")
    echo ""
    echo "=============================================="
    echo "  内存压力测试 (48H) - 状态"
    echo "=============================================="

    echo "  日志目录: $LOG_DIR"
    echo ""

    if check_test_running; then
        local pid
        pid=$(cat "$MEMTESTER_PID_FILE" 2>/dev/null || echo "?")
        echo "  状态: 测试运行中  (memtester PID: $pid)"
        if [ -f "$START_TIME_FILE" ]; then
            local start_ts now_ts elapsed_sec elapsed_hour start_str
            start_str=$(cat "$START_TIME_FILE")
            start_ts=$(date -d "$start_str" +%s 2>/dev/null || echo 0)
            now_ts=$(date +%s)
            elapsed_sec=$((now_ts - start_ts))
            elapsed_hour=$(echo "scale=1; $elapsed_sec / 3600" | bc)
            echo "  开始时间: $start_str"
            echo "  已运行:   ${elapsed_hour} 小时 (目标: 48H)"
            echo "  剩余:     $(echo "scale=1; 48 - $elapsed_hour" | bc) 小时"
        fi

        echo ""
        echo "--- 当前内存使用 ---"
        free -h
    else
        echo "  状态: 测试未运行"
        if [ -f "$START_TIME_FILE" ] && [ -f "$END_TIME_FILE" ]; then
            echo "  开始时间: $(cat "$START_TIME_FILE")"
            echo "  结束时间: $(cat "$END_TIME_FILE")"
        elif [ -f "$START_TIME_FILE" ]; then
            echo "  开始时间: $(cat "$START_TIME_FILE")"
            echo "  (测试可能异常中断)"
        fi
    fi

    echo ""
    echo "--- 日志文件 ---"
    if [ -d "$LOG_DIR" ]; then
        ls -lh "$LOG_DIR" 2>/dev/null || echo "(空)"
    else
        echo "(日志目录不存在)"
    fi
}

usage() {
    echo "用法: $0 {start|stop|status}"
    echo ""
    echo "  start   启动 48H 内存压力测试 (memtester + nmon)"
    echo "  stop    停止测试并收集所有日志"
    echo "  status  查看当前测试状态"
    echo ""
    echo "示例:"
    echo "  $0 start          # 启动测试"
    echo "  $0 status         # 48 小时内随时查看状态"
    echo "  $0 stop           # 48 小时后停止并收集结果"
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

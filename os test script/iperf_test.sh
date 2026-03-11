#!/bin/bash

# 获取脚本所在目录
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 用户配置（直接修改这里）
SERVER_IP="127.0.0.1"
DURATION=14400

# 日志文件
REPORT_FILE="$SCRIPT_DIR/iperf_test_report_${TIMESTAMP}.log"
DMESG_LOG="$SCRIPT_DIR/dmesg_${TIMESTAMP}.log"
MESSAGE_LOG="$SCRIPT_DIR/message_${TIMESTAMP}.log"
BMC_LOG="$SCRIPT_DIR/bmc_${TIMESTAMP}.log"
IPERF_RAW="$SCRIPT_DIR/iperf_raw_${TIMESTAMP}.log"

# 全局 PID 变量
DMESG_PID=""
MESSAGE_PID=""
BMC_PID=""

start_log_collection() {
    dmesg -w > "$DMESG_LOG" 2>&1 &
    DMESG_PID=$!
    
    tail -f /var/log/messages > "$MESSAGE_LOG" 2>&1 &
    MESSAGE_PID=$!
    
    {
        while true; do
            echo "=== $(date) ===" >> "$BMC_LOG"
            ipmitool sel list >> "$BMC_LOG" 2>&1
            sleep 60
        done
    } &
    BMC_PID=$!
}

stop_log_collection() {
    local pids=()
    [ -n "$DMESG_PID" ] && kill "$DMESG_PID" 2>/dev/null && pids+=("$DMESG_PID")
    [ -n "$MESSAGE_PID" ] && kill "$MESSAGE_PID" 2>/dev/null && pids+=("$MESSAGE_PID")
    [ -n "$BMC_PID" ] && kill "$BMC_PID" 2>/dev/null && pids+=("$BMC_PID")
    [ ${#pids[@]} -gt 0 ] && wait "${pids[@]}" 2>/dev/null
}

{
    echo "================ iPerf 测试记录 - $(date '+%Y-%m-%d %H:%M:%S') ================"
    echo "--- 环境记录 ---"
    echo "内核版本: $(uname -a)"
    echo "操作系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'N/A')"
    echo "CPU信息: $(lscpu 2>/dev/null | grep 'Model name' | sed 's/Model name:[[:space:]]*//' || echo 'N/A')"
    echo "内存信息: $(free -h 2>/dev/null | grep Mem | awk '{print $2}' || echo 'N/A')"
    echo "iPerf版本: $(iperf3 --version 2>&1 | head -1 || echo 'N/A')"
    echo "------------------------------------------------"
    echo "服务器IP: $SERVER_IP"
    echo "测试时长: 4小时 ($DURATION 秒)"
    echo "测试开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "日志位置: $SCRIPT_DIR"
    echo "------------------------------------------------"
} >> "$REPORT_FILE" 2>&1

start_log_collection

iperf3 -c "$SERVER_IP" -t "$DURATION" --logfile "$IPERF_RAW" 2>&1 || true

sleep 2
stop_log_collection

{
    echo "测试结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================"
    echo "输出文件："
    echo "  - 测试报告: $(basename $REPORT_FILE)"
    echo "  - dmesg日志: $(basename $DMESG_LOG)"
    echo "  - message日志: $(basename $MESSAGE_LOG)"
    echo "  - BMC日志: $(basename $BMC_LOG)"
    echo "  - iPerf结果: $(basename $IPERF_RAW)"
    echo "================================================"
} >> "$REPORT_FILE" 2>&1

echo "✓ iPerf 测试已完成"
echo "✓ 所有结果已保存至: $SCRIPT_DIR"
echo "✓ 报告文件: $(basename $REPORT_FILE)"

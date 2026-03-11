#!/bin/bash

# 网络性能测试脚本
# 功能：测试TCP/UDP吞吐量、响应时间，收集环境信息及系统日志。
# 依赖：netperf, netserver

# 设置语言环境
export LC_ALL=C
export LANG=C

# 基础路径
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
RESULT_DIR="${SCRIPT_DIR}/network_test_${TIMESTAMP}"
LOG_FILE="${RESULT_DIR}/test_execution.log"

# 创建结果目录
mkdir -p "${RESULT_DIR}"

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

log "=================================================="
log "开始执行网络性能测试"
log "结果目录: ${RESULT_DIR}"
log "=================================================="

# 1. 环境信息收集
log "[1/5] 收集环境信息..."
{
    echo "--- 系统信息 ---"
    uname -a
    [ -f /etc/os-release ] && cat /etc/os-release
    echo -e "\n--- CPU信息 ---"
    lscpu
    echo -e "\n--- 内存信息 ---"
    free -h
    echo -e "\n--- 网络接口 ---"
    ip addr
    echo -e "\n--- 网卡硬件信息 ---"
    lspci | grep -i ether
} > "${RESULT_DIR}/env_info.txt"

# 2. 检查并启动 netserver
log "[2/5] 检查并启动 netserver..."
if ! command -v netperf &> /dev/null; then
    log "错误: 未找到 netperf 命令，请先安装 (例如: sudo apt install netperf)"
    exit 1
fi

# 尝试启动 netserver
netserver -p 12865 >> "${LOG_FILE}" 2>&1
if [ $? -ne 0 ]; then
    log "提示: netserver 启动返回非零值，可能已经在运行。"
fi

# 3. 执行 netperf 测试
TARGET_IP=${1:-"127.0.0.1"}
log "[3/5] 开始执行 netperf 测试 (测试目标: ${TARGET_IP})..."
TEST_DURATION=10

# TCP Stream (吞吐量)
log "正在进行 TCP_STREAM 测试 (吞吐量)..."
netperf -H ${TARGET_IP} -l ${TEST_DURATION} -t TCP_STREAM -- -m 1024 > "${RESULT_DIR}/tcp_stream.txt" 2>&1

# UDP Stream (吞吐量)
log "正在进行 UDP_STREAM 测试 (吞吐量)..."
netperf -H ${TARGET_IP} -l ${TEST_DURATION} -t UDP_STREAM -- -m 1024 > "${RESULT_DIR}/udp_stream.txt" 2>&1

# TCP Request/Response (响应时间/速率)
log "正在进行 TCP_RR 测试 (响应时间/速率)..."
netperf -H ${TARGET_IP} -l ${TEST_DURATION} -t TCP_RR -- -r 64,64 > "${RESULT_DIR}/tcp_rr.txt" 2>&1

# UDP Request/Response (响应时间/速率)
log "正在进行 UDP_RR 测试 (响应时间/速率)..."
netperf -H ${TARGET_IP} -l ${TEST_DURATION} -t UDP_RR -- -r 64,64 > "${RESULT_DIR}/udp_rr.txt" 2>&1

# 4. 收集系统日志
log "[4/5] 收集系统日志 (dmesg & messages)..."
dmesg > "${RESULT_DIR}/dmesg.log"
if [ -f /var/log/messages ]; then
    cp /var/log/messages "${RESULT_DIR}/messages.log"
elif [ -f /var/log/syslog ]; then
    cp /var/log/syslog "${RESULT_DIR}/syslog.log"
else
    log "警告: 未找到 /var/log/messages 或 /var/log/syslog"
fi

# 5. 生成简要报告
log "[5/5] 生成测试报告..."
{
    echo "=================================================="
    echo "            网络性能测试简报                     "
    echo "测试时间: $(date)"
    echo "测试目标: ${TARGET_IP}"
    echo "=================================================="
    echo ""
    echo "1. TCP 吞吐量 (TCP_STREAM) [10^6bits/sec]:"
    [ -f "${RESULT_DIR}/tcp_stream.txt" ] && tail -n 1 "${RESULT_DIR}/tcp_stream.txt" | awk '{print $NF}'
    echo ""
    echo "2. UDP 吞吐量 (UDP_STREAM) [10^6bits/sec]:"
    [ -f "${RESULT_DIR}/udp_stream.txt" ] && tail -n 2 "${RESULT_DIR}/udp_stream.txt" | head -n 1 | awk '{print $NF}'
    echo ""
    echo "3. TCP 响应速率 (TCP_RR) [Trans/sec]:"
    [ -f "${RESULT_DIR}/tcp_rr.txt" ] && tail -n 2 "${RESULT_DIR}/tcp_rr.txt" | head -n 1 | awk '{print $NF}'
    echo ""
    echo "4. UDP 响应速率 (UDP_RR) [Trans/sec]:"
    [ -f "${RESULT_DIR}/udp_rr.txt" ] && tail -n 2 "${RESULT_DIR}/udp_rr.txt" | head -n 1 | awk '{print $NF}'
    echo ""
    echo "=================================================="
    echo "详细日志及原始数据请查看目录: ${RESULT_DIR}"
} > "${RESULT_DIR}/test_report.txt"

# 清理 netserver (仅在测试本地时尝试停止)
if [ "${TARGET_IP}" == "127.0.0.1" ] || [ "${TARGET_IP}" == "localhost" ]; then
    pkill netserver > /dev/null 2>&1
fi

log "测试完成！"
log "结果已保存在目录: ${RESULT_DIR}"
chmod +x "${RESULT_DIR}"

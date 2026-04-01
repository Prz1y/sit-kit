#!/bin/bash
################################################################################
# Memtester 加严测试脚本 (CE阈值关闭)
# 
# 用途: 在CE阈值关闭的BIOS配置下，执行3小时内存压力测试，自动收集日志并检查ECC错误
#
# 使用要求:
#   1. 需要root权限运行
#   2. 内存需支持ECC
#   3. BIOS需配置: CE阈值关闭 (dont_log_ce=0)
#
# 执行流程:
#   1. 检查BIOS配置 (BIOS版本、BMC版本、内存容量、CE阈值状态)
#   2. 运行3小时memtester压力测试 (占用90%内存)
#   3. 收集日志 (dmesg、messages、BMC事件)
#   4. 日志保存在: /tmp/memtester_test_<时间戳>/
#
# 查看ECC错误:
#   grep -i ecc /tmp/memtester_test_<时间戳>/dmesg.log
################################################################################

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="/tmp/memtester_test_${TIMESTAMP}"
mkdir -p "${LOG_DIR}"

echo -e "${BLUE}========== Memtester 加严测试 ==========${NC}"

# 首先检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}需要root权限运行此脚本${NC}"
    exit 1
fi

check_bios_config() {
    # BIOS版本
    if command -v dmidecode &>/dev/null; then
        local bios_ver
        bios_ver=$(dmidecode -s bios-version 2>/dev/null || true)
        echo -e "  BIOS版本: ${bios_ver:-未获取到}"
    fi

    # BMC版本
    if command -v ipmitool &>/dev/null; then
        local bmc_fw
        bmc_fw=$(ipmitool bmc info 2>/dev/null | grep -i "Firmware Revision" | awk -F': ' '{print $2}' || true)
        echo -e "  BMC版本:  ${bmc_fw:-未获取到}"
    fi

    # 内存容量
    local mem_total
    mem_total=$(free -h | awk 'NR==2 {print $2}')
    echo -e "  内存容量: ${mem_total}"

    # 检查CE阈值是否关闭（通过MCE dont_log_ce，0=记录CE，1=忽略CE）
    local ce_status="${YELLOW}无法读取${NC}"
    if [ -f /sys/devices/system/machinecheck/machinecheck0/dont_log_ce ]; then
        local dont_log
        dont_log=$(cat /sys/devices/system/machinecheck/machinecheck0/dont_log_ce 2>/dev/null)
        if [ "$dont_log" = "0" ]; then
            ce_status="${GREEN}CE阈值已关闭（CE错误将被记录）${NC}"
        else
            ce_status="${RED}CE阈值未关闭（dont_log_ce=$dont_log，应为0）${NC}"
        fi
    fi
    echo -e "  CE阈值:   $(echo -e "$ce_status")"
}

# 检查memtester（先检查再做BIOS配置）
if ! command -v memtester &> /dev/null; then
    echo -e "${RED}memtester未安装${NC}"
    exit 1
fi
echo -e "${GREEN}memtester已安装${NC}"

echo -e "${BLUE}检查BIOS配置...${NC}"
check_bios_config
read -p "确认已完成BIOS配置，按Enter继续..."

# 清空dmesg
dmesg -C

# 运行3小时压测（timeout 10800秒 = 3小时，loops=0表示无限循环由timeout控制）
echo -e "${BLUE}启动3小时压力测试...${NC}"
TOTAL_MEM=$(free -m | awk 'NR==2 {print int($2 * 0.9)}')
EXIT_CODE=0
timeout 10800 memtester "${TOTAL_MEM}M" 0 || EXIT_CODE=$?
if [ $EXIT_CODE -eq 124 ]; then
    echo -e "${GREEN}3小时压测正常完成${NC}"
elif [ $EXIT_CODE -ne 0 ]; then
    echo -e "${RED}memtester异常退出，退出码: $EXIT_CODE${NC}"
    exit $EXIT_CODE
fi

# 收集日志
echo -e "${BLUE}收集日志...${NC}"
dmesg > "${LOG_DIR}/dmesg.log"
[ -f /var/log/messages ] && tail -n 10000 /var/log/messages > "${LOG_DIR}/messages.log"
[ -f /var/log/syslog ] && tail -n 10000 /var/log/syslog > "${LOG_DIR}/syslog.log"
command -v ipmitool &>/dev/null && ipmitool sel list > "${LOG_DIR}/bmc_event.log" 2>/dev/null || true

echo -e "${GREEN}压测完成，日志已保存到: ${LOG_DIR}${NC}"
echo ""
echo "查看ECC错误:"
echo "  grep -i ecc ${LOG_DIR}/dmesg.log"

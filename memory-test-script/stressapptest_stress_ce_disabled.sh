#!/bin/bash
################################################################################
# Stressapptest 加严测试脚本 (CE阈值关闭)
#
# 用途: 在内存错误管理加严的BIOS配置下，执行内存压力测试，自动收集日志并检查ECC错误
#
# 使用要求:
#   1. 需要root权限运行
#   2. 内存需支持ECC
#   3. BIOS需配置 (在"内存错误管理"界面):
#       - CE阈值关闭        (dont_log_ce=0)
#       - MCA错误数量控制   = 1
#       - 漏斗时间          = 0
#       - 内存CE错误小风暴时间 = 0
#
# 执行流程:
#   1. 检查stressapptest可执行文件（当前目录或PATH）
#   2. 检查BIOS配置 (BIOS版本、BMC版本、内存容量、CE阈值状态)
#   3. 提示人工确认内存错误管理的其余BIOS项
#   4. 运行压力测试 (默认3小时，占用94%内存，线程数=CPU核心数)
#   5. 收集日志 (dmesg、messages/syslog、stressapptest输出、BMC事件)
#   6. 日志保存在: /tmp/stressapptest_test_<时间戳>/
#
# 可调参数 (修改下方 "用户可调参数" 区域):
#   TEST_TIME    - 测试时长（秒），默认10800（3小时）
#
# 查看ECC错误:
#   grep -i ecc /tmp/stressapptest_test_<时间戳>/dmesg.log
################################################################################

set -euo pipefail

# ============================================================
# 用户可调参数
# ============================================================
TEST_TIME=10800       # 测试时长（秒）：3小时=10800，1小时=3600，6小时=21600
MEM_RATIO=0.94        # 内存占用比例，默认94%
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="/tmp/stressapptest_test_${TIMESTAMP}"
mkdir -p "${LOG_DIR}"

echo -e "${BLUE}========== Stressapptest 加严测试 ==========${NC}"

# ── 检查root权限 ──────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}需要root权限运行此脚本${NC}"
    exit 1
fi

# ── 查找stressapptest二进制文件 ──────────────────────────
# 优先使用当前目录，其次在PATH中查找
SAT_BIN=""
if [ -x "./stressapptest" ]; then
    SAT_BIN="./stressapptest"
elif command -v stressapptest &>/dev/null; then
    SAT_BIN="stressapptest"
else
    echo -e "${RED}未找到stressapptest：请将二进制文件放到当前目录，或确保其在PATH中${NC}"
    exit 1
fi
echo -e "${GREEN}stressapptest已找到: ${SAT_BIN}${NC}"

# ── 计算测试参数 ──────────────────────────────────────────
cpu_cores=$(nproc)
mem_total_mb=$(free -m | awk 'NR==2 {print $2}')
mem_test_mb=$(awk "BEGIN {printf \"%d\", ${mem_total_mb} * ${MEM_RATIO}}")
test_hours=$(awk "BEGIN {printf \"%.1f\", ${TEST_TIME} / 3600}")

echo -e "  CPU核心数:   ${CYAN}${cpu_cores}${NC}"
echo -e "  测试内存:    ${CYAN}${mem_test_mb} MB${NC} (总 ${mem_total_mb} MB 的 $(awk "BEGIN {printf \"%.0f\", ${MEM_RATIO}*100}")%)"
echo -e "  测试时长:    ${CYAN}${test_hours} 小时 (${TEST_TIME} 秒)${NC}"
echo ""

# ── 检查BIOS配置 ──────────────────────────────────────────
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
        if [ "${dont_log}" = "0" ]; then
            ce_status="${GREEN}CE阈值已关闭（CE错误将被记录）${NC}"
        else
            ce_status="${RED}CE阈值未关闭（dont_log_ce=${dont_log}，应为0）${NC}"
        fi
    fi
    echo -e "  CE阈值:   $(echo -e "${ce_status}")"
}

echo -e "${BLUE}检查BIOS配置...${NC}"
check_bios_config
read -p "确认已完成BIOS配置，按Enter继续..."

# ── 清空dmesg缓冲区 ───────────────────────────────────────
dmesg -C
echo -e "${GREEN}dmesg缓冲区已清空${NC}"

# ── 启动压力测试 ──────────────────────────────────────────
echo ""
echo -e "${BLUE}========== 启动压力测试 ==========${NC}"
echo -e "命令: ${CYAN}${SAT_BIN} -i ${cpu_cores} -C ${cpu_cores} -W -M ${mem_test_mb} -s ${TEST_TIME}${NC}"
echo -e "开始时间: $(date)"
echo ""

SAT_LOG="${LOG_DIR}/stressapptest_output.log"
EXIT_CODE=0

# stressapptest 自带计时（-s 参数），无需外部 timeout
# tee 同时输出到终端和日志文件
"${SAT_BIN}" \
    -i "${cpu_cores}" \
    -C "${cpu_cores}" \
    -W \
    -M "${mem_test_mb}" \
    -s "${TEST_TIME}" \
    2>&1 | tee "${SAT_LOG}" || EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo -e "结束时间: $(date)"

if [ "${EXIT_CODE}" -eq 0 ]; then
    echo -e "${GREEN}stressapptest 正常完成（退出码: 0）${NC}"
else
    echo -e "${RED}stressapptest 异常退出（退出码: ${EXIT_CODE}）${NC}"
    echo -e "${RED}请检查输出日志: ${SAT_LOG}${NC}"
fi

# ── 收集日志 ──────────────────────────────────────────────
echo ""
echo -e "${BLUE}========== 收集日志 ==========${NC}"

dmesg > "${LOG_DIR}/dmesg.log"
echo -e "  dmesg.log              → 已保存"

if [ -f /var/log/messages ]; then
    tail -n 10000 /var/log/messages > "${LOG_DIR}/messages.log"
    echo -e "  messages.log           → 已保存"
fi

if [ -f /var/log/syslog ]; then
    tail -n 10000 /var/log/syslog > "${LOG_DIR}/syslog.log"
    echo -e "  syslog.log             → 已保存"
fi

if command -v ipmitool &>/dev/null; then
    ipmitool sel list > "${LOG_DIR}/bmc_event.log" 2>/dev/null || true
    echo -e "  bmc_event.log          → 已保存"
fi

# 保存测试参数摘要
cat > "${LOG_DIR}/test_summary.txt" <<EOF
=== Stressapptest 加严测试摘要 ===
测试时间:     $(date)
stressapptest: ${SAT_BIN}
CPU核心数:    ${cpu_cores}
测试内存:     ${mem_test_mb} MB (共 ${mem_total_mb} MB)
测试时长:     ${TEST_TIME} 秒 (${test_hours} 小时)
退出码:       ${EXIT_CODE}
日志目录:     ${LOG_DIR}
EOF
echo -e "  test_summary.txt       → 已保存"

echo ""
echo -e "${GREEN}全部日志已保存到: ${LOG_DIR}${NC}"
echo ""
echo "快速检查ECC错误:"
echo -e "  ${CYAN}grep -i ecc ${LOG_DIR}/dmesg.log${NC}"
echo ""
echo "查看stressapptest完整输出:"
echo -e "  ${CYAN}cat ${LOG_DIR}/stressapptest_output.log${NC}"

# 若存在内存错误则以非0退出，方便CI/自动化调用
if [ "${EXIT_CODE}" -ne 0 ]; then
    exit "${EXIT_CODE}"
fi

#!/bin/bash

# ECC 内存 3 小时压测脚本
# Author : Prz1y
# 功能：启动 ECC 内存扫描、监控系统日志、BMC 日志，3 小时后自动关闭

cd common-all-all-server-hw-eccmem
LOG_DIR="../test_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

stop_pid() {
  local name="$1"
  local pid="$2"

  [ -z "$pid" ] && return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  echo "[$(date)] 停止 ${name}，PID=${pid}"
  kill "$pid" 2>/dev/null || true

  for _ in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "[$(date)] ${name} 未正常退出，执行强制终止"
  kill -9 "$pid" 2>/dev/null || true
}

cleanup_processes() {
  stop_pid "messages 监控" "${MESSAGES_PID:-}"
  stop_pid "dmesg 监控" "$DMESG_PID"
  stop_pid "ECC 压测" "$ECCMEM_PID"
  stop_pid "BMC 采集" "$BMC_PID"
}

echo "[$(date)] ========== ECC 内存压测开始 =========="

# 1. 配置脚本持续运行
echo "[$(date)] 配置脚本参数..."
sed -i 's/scan_time = [0-9]*/scan_time = 0/' eccmem.conf

# 2. 启动 ECC 内存扫描（3小时）
echo "[$(date)] 启动 ECC 内存扫描..."
timeout 3h python3 run.py --always True > "$LOG_DIR/eccmem_output.log" 2>&1 &
ECCMEM_PID=$!

# 3. 实时监控 dmesg（ECC 错误会显示在这里）
echo "[$(date)] 启动 dmesg 监控..."
dmesg -w > "$LOG_DIR/dmesg_realtime.log" 2>&1 &
DMESG_PID=$!

# 4. 监控 /var/log/messages
if [ -f /var/log/messages ]; then
  echo "[$(date)] 启动 messages 监控..."
  tail -f /var/log/messages > "$LOG_DIR/messages_monitor.log" 2>&1 &
  MESSAGES_PID=$!
fi

# 5. 每 30 分钟采集一次 BMC 日志
echo "[$(date)] 启动 BMC 日志采集..."
(
  for i in {1..6}; do
    sleep 30m
    echo "[$(date)] BMC 日志采集 - 第 $i/6 次" >> "$LOG_DIR/collect.log"
    ipmitool sel elist >> "$LOG_DIR/bmc_events.log" 2>&1
    ipmitool sdr >> "$LOG_DIR/bmc_sensors.log" 2>&1
  done
) &
BMC_PID=$!

echo "[$(date)] ========== 压测进程信息 =========="
echo "ECC 扫描 PID: $ECCMEM_PID"
echo "dmesg 监控 PID: $DMESG_PID"
echo "messages 监控 PID: $MESSAGES_PID"
echo "BMC 采集 PID: $BMC_PID"
echo "日志位置: $LOG_DIR"
echo "运行时间: 3 小时"
echo ""

on_interrupt() {
  echo "[$(date)] 收到中断信号，开始清理后台任务"
  cleanup_processes
  exit 130
}

trap on_interrupt INT TERM

# 6. 等待 ECC 压测完成（3小时后 timeout 会自动终止）
echo "[$(date)] 等待压测完成（3小时）..."
wait $ECCMEM_PID
TEST_STATUS=$?

echo "[$(date)] ========== 3 小时压测完成，开始清理 =========="

cleanup_processes

# 8. 导出最终日志
echo "[$(date)] 导出最终日志..."
dmesg > "$LOG_DIR/dmesg_final.log" 2>/dev/null
cp /var/log/messages "$LOG_DIR/messages_final.log" 2>/dev/null
cp log/*.log "$LOG_DIR/" 2>/dev/null

echo "[$(date)] ========== 测试完成 =========="
echo "返回码: $TEST_STATUS"
echo "日志保存位置: $LOG_DIR"
echo ""
echo "========== 日志文件列表 =========="
ls -lh "$LOG_DIR"
echo ""
echo "========== 关键日志查看命令 =========="
echo "查看 ECC 错误:"
echo "  grep -i 'ecc\|error\|fail' $LOG_DIR/dmesg_final.log | head -20"
echo ""
echo "查看完整 dmesg:"
echo "  tail -200 $LOG_DIR/dmesg_final.log"
echo ""
echo "查看 messages 日志:"
echo "  tail -200 $LOG_DIR/messages_final.log"
echo ""
echo "查看 ECC 扫描输出:"
echo "  tail -50 $LOG_DIR/eccmem_output.log"

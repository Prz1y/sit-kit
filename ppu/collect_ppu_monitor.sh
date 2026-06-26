#!/bin/bash

set -euo pipefail

# 检查必要命令
for cmd in ppudbg; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' not found."
        exit 1
    fi
done

# ===== 配置参数 =====
DEVICES=(0 1)   # 要监控的设备列表
LOG_DIR="ppu_stream_logs"
# ===================

mkdir -p "$LOG_DIR"

# 捕获退出并清理后台进程
cleanup() {
    echo -e "\n[INFO] Stopping all monitors and closing files..."
    if [ ${#PIDS[@]} -gt 0 ]; then
        kill "${PIDS[@]}" 2>/dev/null || true
        for pid in "${PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT INT TERM

echo "[INFO] Starting continuous PPU monitoring (stream to files)."
echo "[INFO] Devices: ${DEVICES[*]}"
echo "[INFO] Log directory: $LOG_DIR"
echo "[INFO] Press Ctrl+C to stop logging."
echo ""

# 启动所有监控进程，并将输出重定向到各自的文件
PIDS=()

for DEVICE_ID in "${DEVICES[@]}"; do
    echo "[DEBUG] Starting monitors for device $DEVICE_ID..."

    # CE/CU Stress
    ppudbg --device "$DEVICE_ID" --monitor \
        > "$LOG_DIR/dev${DEVICE_ID}_ce_cu_stress.txt" 2>&1 &
    local _pid=$!
    sleep 1
    if kill -0 "$_pid" 2>/dev/null; then
        PIDS+=("$_pid")
    else
        echo "[WARN] ppudbg --device $DEVICE_ID --monitor exited immediately" >&2
    fi

    # Power Info
    ppudbg --device "$DEVICE_ID" --monitor power \
        > "$LOG_DIR/dev${DEVICE_ID}_power_info.txt" 2>&1 &
    PIDS+=("$!")

    # ICN Info
    ppudbg --device "$DEVICE_ID" --monitor icn \
        > "$LOG_DIR/dev${DEVICE_ID}_icn_info.txt" 2>&1 &
    PIDS+=("$!")

    # Video Info
    ppudbg --device "$DEVICE_ID" --monitor video \
        > "$LOG_DIR/dev${DEVICE_ID}_video_info.txt" 2>&1 &
    PIDS+=("$!")
done

echo "[INFO] All monitors are now streaming data to their respective files."
echo "[INFO] Running in background. Press Ctrl+C to stop."

# 等待所有后台进程（它们会一直运行直到被 kill 或 Ctrl+C）
for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

echo "[INFO] Logging stopped."
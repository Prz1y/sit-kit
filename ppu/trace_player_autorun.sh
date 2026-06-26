#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACE_BIN="${SCRIPT_DIR}/trace_player"
TRACE_STREAM="${SCRIPT_DIR}/multi_stream.txt"

#配置
DURATION=30000  #秒

#日志文件名
LOG_FILE="trace_player_$(date +%Y%m%d_%H%M).log"


echo "日志: $LOG_FILE"
echo "----------------------------------------"

{
    start_time=$(date +%s)
    end_time=$((start_time + DURATION))
    failed=0

    echo "[$(date)] 启动"

    while [ "$(date +%s)" -lt $end_time ]; do
        echo "[$(date)] loops started..."

        "$TRACE_BIN" -s "$TRACE_STREAM" -n 22 -r 100000 || failed=1
        AlippuDeviceIndex=1 "$TRACE_BIN" -s "$TRACE_STREAM" -n 22 -r 100000 || failed=1

        echo "[$(date)] loop done..."
    done

    echo "[$(date)] ALLDONE！"
    exit $failed
} 2>&1 | tee "$LOG_FILE"

echo "----------------------------------------"
echo "日志：$LOG_FILE"
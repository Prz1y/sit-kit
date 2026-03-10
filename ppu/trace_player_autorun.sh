#!/bin/bash

#配置
DURATION=30000  #秒

#日志文件名
LOG_FILE="trace_player_$(date +%Y%m%d_%H%M).log"


echo "日志: $LOG_FILE"
echo "----------------------------------------"

{
    start_time=$(date +%s)
    end_time=$((start_time + DURATION))

    echo "[$(date)] 启动"

    while [ "$(date +%s)" -lt $end_time ]; do
        echo "[$(date)] loops started..."

        ./trace_player -s multi_stream.txt -n 22 -r 100000
        AlippuDeviceIndex=1 ./trace_player -s multi_stream.txt -n 22 -r 100000

        echo "[$(date)] loop done..."
    done

    echo "[$(date)] ALLDONE！"
} 2>&1 | tee "$LOG_FILE"

echo "----------------------------------------"
echo "日志：$LOG_FILE"
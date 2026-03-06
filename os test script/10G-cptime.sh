#!/bin/bash

# --- 配置参数 ---
FILE_SIZE="10G"              # 测试文件大小
TEST_DIR="."                 # 当前目录
LOG_DIR="$TEST_DIR/test_logs" # 日志存放文件夹
TEST_FILE="test_source_10G"
COPY_FILE="test_target_10G"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/copy_test_$TIMESTAMP.log"

# --- 创建日志目录 ---
mkdir -p "$LOG_DIR"

# 定义日志记录函数
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log "==========================================="
log "磁盘同盘拷贝测试开始 - $TIMESTAMP"
log "测试文件大小: $FILE_SIZE"
log "==========================================="

# 1. 生成测试文件 (如果不存在)
if [ ! -f "$TEST_FILE" ]; then
    log "[1/3] 正在生成 $FILE_SIZE 的测试文件..."
    # 使用 fallocate 快速分配空间，或者 dd 生成真实数据
    dd if=/dev/zero of="$TEST_FILE" bs=1M count=10240 status=progress 2>&1 | tee -a "$LOG_FILE"
    sync
else
    log "[1/3] 测试文件已存在，跳过创建。"
fi

# 2. 清除系统缓存 (必须 sudo，否则测试结果不准)
log "\n[2/3] 正在清除系统缓存 (需要 sudo 权限)..."
sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
log "缓存已清除。"

# 3. 开始拷贝测试并计时
log "\n[3/3] 开始拷贝文件..."
log "命令: cp $TEST_FILE $COPY_FILE && sync"

# 使用 time 命令记录耗时，注意 time 的输出通常重定向到 stderr
{ time ( cp "$TEST_FILE" "$COPY_FILE" && sync ) ; } 2>> "$LOG_FILE"

# 4. 计算并输出简要总结
END_TIME=$(date +%s)
log "\n-------------------------------------------"
log "测试完成！"
log "详细计时结果已保存至: $LOG_FILE"
log "运行以下命令删除测试文件:"
log "rm $TEST_FILE $COPY_FILE"
log "-------------------------------------------"
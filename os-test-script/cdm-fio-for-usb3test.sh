#!/bin/bash

# ==========================================
# 1. 基础配置
# ==========================================
DEV="/dev/sdb"               # 盘符
RESULT_DIR="fio_results_$(date +%Y%m%d_%H%M%S)"
SIZE="1G"                    # 1G数据范围循环读写
RAMP="10"                    # 10秒预热
RUN="60"                     # 60秒实测
ENGINE="libaio"
DIRECT=1

# 创建存放结果的文件夹
mkdir -p "$RESULT_DIR"

echo "================================================"
echo "测试开始，结果将存入文件夹: $RESULT_DIR"
echo "目标设备: $DEV"
echo "================================================"

# ==========================================
# 2. 定义测试核心函数
# ==========================================
run_fio() {
    local name=$1
    local rw=$2
    local bs=$3
    local qd=$4
    local nj=$5
    local output_file="$RESULT_DIR/${name}.txt"
    
    echo ">> 正在运行: $name ... (预热30s + 实测60s)"
    
    # 执行fio并将结果保存到文件
    fio --name="$name" \
        --filename="$DEV" \
        --ioengine=$ENGINE \
        --direct=$DIRECT \
        --rw="$rw" \
        --bs="$bs" \
        --iodepth="$qd" \
        --numjobs="$nj" \
        --size=$SIZE \
        --ramp_time=$RAMP \
        --runtime=$RUN \
        --time_based \
        --group_reporting \
        --output="$output_file"

    # 在终端简单显示一下这个项的结果，不用翻文件
    local bw=$(grep -E "READ:|WRITE:" "$output_file" | awk -F'bw=' '{print $2}' | awk -F',' '{print $1}')
    echo "   [完成] 平均带宽: $bw"
    echo "   [报告]: $output_file"
}

# ==========================================
# 3. 执行 CrystalDiskMark 标准四项测试
# ==========================================

# --- 顺序性能 (Sequential) ---
run_fio "SEQ1M_Q8T1_Read"  "read"  "1M" 8 1
run_fio "SEQ1M_Q8T1_Write" "write" "1M" 8 1

run_fio "SEQ1M_Q1T1_Read"  "read"  "1M" 1 1
run_fio "SEQ1M_Q1T1_Write" "write" "1M" 1 1

# --- 随机性能 (Random 4K) ---
# 注意：普通U盘跑这两项写测试可能会非常慢，请耐心等待
run_fio "RND4K_Q32T1_Read"  "randread"  "4k" 32 1
run_fio "RND4K_Q32T1_Write" "randwrite" "4k" 32 1

run_fio "RND4K_Q1T1_Read"  "randread"  "4k" 1 1
run_fio "RND4K_Q1T1_Write" "randwrite" "4k" 1 1

echo "================================================"
echo "所有测试已完成！"
echo "请查看文件夹 $RESULT_DIR 获取详细报告。"
ls -lh "$RESULT_DIR"
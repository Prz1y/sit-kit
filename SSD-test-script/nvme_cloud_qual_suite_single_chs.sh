#!/bin/bash
# ============================================================================
# NVMe 云准入测试套件-by Prz1y
# ============================================================================
# 测试前环境与配置要求说明 依赖工具检查：确保服务器已安装以下基础工具包：fio, nvme-cli, ipmitool, pciutils (用于 lspci)
# 确保 Python3 已安装以下依赖：pip install pandas openpyxl
# 务必使用防断开终端：yum/apt-get install -y tmux & tmux new -s nvme_test 或在OS终端下运行该脚本。
# 不要在系统盘以及含有重要资料的硬盘上运行该测试套件！否则数据将会丢失。
# ============================================================================

# ====================[ 1. 核心配置区 ] ====================
TARGET_DEVS=("/dev/nvme0n1") 
TEST_MODE="single"

# 测试时长 (单位：秒)
RUNTIME=300           # 常规顺序/随机遍历: 300秒 (5分钟)
MIX_RUNTIME=1800      # 混合读写测试: 1800秒 (30分钟)
QOS_RUNTIME=3600      # 一致性与QoS测试: 3600秒 (1小时)

# 预处理 (全盘容量读写)
DO_SEQ_PRECON="yes"   # 顺序读写前进行 128k 满盘写 2 遍
DO_RAND_PRECON="yes"  # 随机读写前进行 4k 满盘随机写 1 遍

SERVER_MODEL="Server"  # 服务器型号，这将作为 Excel 表格中的标识

# ====================[ 2. 环境初始化 ] ====================
BASE_DIR="$(pwd)/NVME_TEST_PROD_$(date +%Y%m%d_%H%M%S)"
RAW_DIR="${BASE_DIR}/raw_data"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "$RAW_DIR" "$LOG_DIR"
echo "[INFO] 测试数据与报表将存放于: $BASE_DIR"
echo "[INFO] 正在抓取系统测试前日志..."

dmesg -T > "$LOG_DIR/pre_dmesg.log"
lspci -vvv > "$LOG_DIR/pre_lspci.log"
nvme smart-log "${TARGET_DEVS[0]}" > "$LOG_DIR/pre_smart.log"
if command -v ipmitool >/dev/null 2>&1; then
    ipmitool sel elist > "$LOG_DIR/pre_ipmi_sel.log"
fi

# ==================== [ 3. Python 测试引擎注入 ] ====================
PYTHON_ENGINE="${BASE_DIR}/nvme_fio_engine.py"

cat << 'EOF' > "$PYTHON_ENGINE"
import os, sys, json, time, subprocess, argparse
from concurrent.futures import ThreadPoolExecutor
import pandas as pd

# 测试参数矩阵
BS_LIST =['4k', '8k', '16k', '32k', '64k', '128k', '256k', '512k', '1m']
NUMJOBS_LIST =[1, 2, 4, 8, 16, 32]
IODEPTH_LIST =[1, 2, 4, 8, 16, 32, 64, 128, 256, 512] 
MIX_RATIO_LIST =[10, 20, 30, 40, 50, 60, 70, 80, 90]

def run_cmd(cmd, log_file=None):
    print(f"    [RUN] {cmd}")
    try:
        res = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if log_file:
            with open(log_file, 'w') as f:
                f.write(res.stdout)
        return res.returncode == 0
    except Exception as e:
        print(f"    [ERROR] 执行失败: {e}")
        return False

def format_drive(dev):
    print(f"\n[WARN] 正在对 {dev} 执行 NVMe Secure Erase (Format -s 1)...")
    run_cmd(f"nvme format {dev} -s 1")
    time.sleep(10)

def run_fio(job_name, dev, rw, bs, iodepth, numjobs, runtime, raw_dir, loops=0, rwmixread=None):
    dev_name = os.path.basename(dev)
    json_out = os.path.join(raw_dir, f"{job_name}_{dev_name}_{rw}_{bs}_{numjobs}j_{iodepth}qd.json")
    
    cmd = f"fio --name={job_name} --filename={dev} --rw={rw} --bs={bs} --iodepth={iodepth} --numjobs={numjobs} --direct=1 --group_reporting --output-format=json --output={json_out}"
    
    if loops > 0:
        # 预处理
        cmd += f" --loops={loops} --size=100%"
    else:
        # 遍历
        cmd += f" --runtime={runtime} --time_based"
        
    if rwmixread is not None:
        cmd += f" --rwmixread={rwmixread}"

    run_cmd(cmd)
    return json_out

def parse_fio_json(json_file):
    try:
        if not os.path.exists(json_file):
            return {"iops": 0, "bw": 0, "min_lat": 0, "avg_lat": 0, "max_lat": 0, "p9999": 0}
        with open(json_file, 'r') as f:
            data = json.load(f)
        job = data['jobs'][0]
        read_iops = job['read']['iops']
        write_iops = job['write']['iops']
        
        is_read = read_iops > write_iops
        tgt = job['read'] if is_read else job['write']
        
        # 带宽转换为 MB/s
        bw_mb = tgt['bw_bytes'] / (1024 * 1024)
        iops = tgt['iops']
        
        # 延时统一转换为 us (微秒)
        min_lat = tgt['lat_ns']['min'] / 1000.0 if 'lat_ns' in tgt else 0
        avg_lat = tgt['lat_ns']['mean'] / 1000.0 if 'lat_ns' in tgt else 0
        max_lat = tgt['lat_ns']['max'] / 1000.0 if 'lat_ns' in tgt else 0
        
        clat_dict = tgt.get('clat_ns', {}).get('percentile', {})
        p9999 = clat_dict.get('99.990000', 0) / 1000.0
        if p9999 == 0: 
            p9999 = clat_dict.get('99.900000', 0) / 1000.0
            
        return {"iops": round(iops, 2), "bw": round(bw_mb, 2), "min_lat": round(min_lat, 2), 
                "avg_lat": round(avg_lat, 2), "max_lat": round(max_lat, 2), "p9999": round(p9999, 2)}
    except Exception as e:
        return {"iops": 0, "bw": 0, "min_lat": 0, "avg_lat": 0, "max_lat": 0, "p9999": 0}

def get_val(df, ptn, bs, nj, qd, metric):
    match = df[(df['pattern'] == ptn) & (df['bs'] == bs) & (df['nj'] == nj) & (df['qd'] == qd)]
    if not match.empty:
        return match.iloc[0][metric]
    return ""

def generate_strict_excel(df_all, mixed_results, out_excel, model):
    print("\n[INFO] 开始生成天翼云制式 Excel 报表...")
    
    QDS_STRICT =[1, 2, 4, 8, 16, 32, 64, 128, 256]
    MATRIX_COLS =[f"{n}_{q}" for n in NUMJOBS_LIST for q in QDS_STRICT]
    
    with pd.ExcelWriter(out_excel, engine='openpyxl') as writer:
        
        sheet_mapping = {
            'seq_read': '顺序读测试', 'seq_write': '顺序写测试', 
            'randread': '随机读测试', 'randwrite': '随机写测试'
        }
        for ptn, sheet_name in sheet_mapping.items():
            iops_dict = {bs: {c: "" for c in MATRIX_COLS} for bs in BS_LIST}
            lat_rows = []
            for bs in BS_LIST:
                lat_rows.extend([f"{bs}_min_lat", f"{bs}_avg_lat", f"{bs}_max_lat", f"{bs}_99.99th_lat"])
            lat_dict = {r: {c: "" for c in MATRIX_COLS} for r in lat_rows}

            ptn_df = df_all[df_all['pattern'] == ptn]
            for _, r in ptn_df.iterrows():
                c = f"{r['nj']}_{r['qd']}"
                if c in MATRIX_COLS:
                    bs = r['bs']
                    iops_dict[bs][c] = r['iops']
                    lat_dict[f"{bs}_min_lat"][c] = r['min_lat']
                    lat_dict[f"{bs}_avg_lat"][c] = r['avg_lat']
                    lat_dict[f"{bs}_max_lat"][c] = r['max_lat']
                    lat_dict[f"{bs}_99.99th_lat"][c] = r['p9999']

            df_iops = pd.DataFrame.from_dict(iops_dict, orient='index')
            df_iops.index.name = 'bs'
            df_lat = pd.DataFrame.from_dict(lat_dict, orient='index')
            df_lat.index.name = 'bs'
            
            pd.DataFrame([["iops:bs_thread_iodepth"]]).to_excel(writer, sheet_name=sheet_name, startrow=0, startcol=0, header=False, index=False)
            df_iops.to_excel(writer, sheet_name=sheet_name, startrow=1)
            
            lat_start_row = len(BS_LIST) + 3
            pd.DataFrame([["latency:bs_thread_iodepth"]]).to_excel(writer, sheet_name=sheet_name, startrow=lat_start_row, startcol=0, header=False, index=False)
            df_lat.to_excel(writer, sheet_name=sheet_name, startrow=lat_start_row+1)

        df_mixed = pd.DataFrame(mixed_results)
        df_mixed.to_excel(writer, sheet_name='混合读写', index=False)

        summary_sheet = "单盘_多盘测试数据"
        wb = writer.book
        ws = wb.create_sheet(summary_sheet)
        
        ws.cell(row=1, column=1, value="单盘/多盘测试数据")
        ws.cell(row=2, column=2, value="带宽测试")
        ws.cell(row=3, column=2, value="bandwidth: bs=128k numjobs=1 iodepth=256")
        ws.cell(row=4, column=2, value="read")
        ws.cell(row=5, column=2, value="write")
        ws.cell(row=4, column=3, value=get_val(df_all, "seq_read", "128k", 1, 256, "bw"))
        ws.cell(row=5, column=3, value=get_val(df_all, "seq_write", "128k", 1, 256, "bw"))

        row_cursor = 7
        
        seq_combos =[
            ('128k', 1, 32), ('128k', 1, 64), ('128k', 1, 128), ('128k', 1, 256), ('128k', 1, 512),
            ('4k', 2, 32), ('64k', 2, 32), ('256k', 2, 32), ('1m', 2, 32)
        ]
        
        rand_combos =[
            ('4k', 1, 1), ('4k', 1, 32), ('4k', 2, 32), ('4k', 2, 256), ('4k', 4, 32), ('4k', 4, 64), 
            ('4k', 8, 1), ('4k', 8, 32), ('4k', 8, 64), ('4k', 8, 256), ('4k', 16, 64),
            ('8k', 1, 32), ('8k', 4, 64), ('8k', 8, 1), ('8k', 8, 32), ('8k', 8, 64),
            ('64k', 2, 32), ('128k', 2, 64), ('256k', 2, 32), ('1m', 2, 32)
        ]

        def write_summary_block(start_row, title, pattern, combos):
            ws.cell(row=start_row, column=2, value=f"{model}-{title}")
            ws.cell(row=start_row+1, column=2, value="硬盘型号|FW版本")
            
            col = 3
            for combo in combos:
                ws.cell(row=start_row+1, column=col, value=f"{combo[0]}-{combo[1]}-{combo[2]}")
                ws.cell(row=start_row+2, column=col, value="iops")
                ws.cell(row=start_row+2, column=col+1, value="带宽")
                ws.cell(row=start_row+2, column=col+2, value="平均时延")
                col += 3
                
            ws.cell(row=start_row+3, column=2, value="SSD1")
            col = 3
            for combo in combos:
                ws.cell(row=start_row+3, column=col, value=get_val(df_all, pattern, combo[0], combo[1], combo[2], "iops"))
                ws.cell(row=start_row+3, column=col+1, value=get_val(df_all, pattern, combo[0], combo[1], combo[2], "bw"))
                ws.cell(row=start_row+3, column=col+2, value=get_val(df_all, pattern, combo[0], combo[1], combo[2], "avg_lat"))
                col += 3
            
            for i in range(2, 13):
                ws.cell(row=start_row+2+i, column=2, value=f"SSD{i}")
                
            return start_row + 16

        row_cursor = write_summary_block(row_cursor, "顺序读", "seq_read", seq_combos)
        row_cursor = write_summary_block(row_cursor, "顺序写", "seq_write", seq_combos)
        row_cursor = write_summary_block(row_cursor, "随机读", "randread", rand_combos)
        row_cursor = write_summary_block(row_cursor, "随机写", "randwrite", rand_combos)

        df_all.to_excel(writer, sheet_name="Raw_Matrix_Data", index=False)
        
    print(f"\n[SUCCESS] 测试报表已生成: {out_excel}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--devs', required=True)
    parser.add_argument('--runtime', type=int, default=300)
    parser.add_argument('--mix_runtime', type=int, default=1800)
    parser.add_argument('--qos_runtime', type=int, default=3600)
    parser.add_argument('--raw_dir', required=True)
    parser.add_argument('--seq_pre', required=True)
    parser.add_argument('--rand_pre', required=True)
    parser.add_argument('--out_excel', required=True)
    parser.add_argument('--model', required=True)
    args = parser.parse_args()

    devs = args.devs.split()
    results = [] 
    mixed_results =[]
    
    for d in devs:
        format_drive(d)

    # 1. 顺序读写测试
    if args.seq_pre == 'yes':
        print("\n===[预处理] 执行 128k 顺序写预处理 (全盘循环2遍) ===")
        for d in devs: run_fio("pre_seq", d, "write", "128k", 128, 1, 0, args.raw_dir, loops=2)

    for rw in['read', 'write']:
        print(f"\n=== [遍历测试] 顺序 {rw} ===")
        total_tasks = len(BS_LIST) * len(NUMJOBS_LIST) * len(IODEPTH_LIST)
        curr = 0
        for bs in BS_LIST:
            for nj in NUMJOBS_LIST:
                for qd in IODEPTH_LIST:
                    curr += 1
                    for d in devs:
                        print(f"  -> 进度[{curr}/{total_tasks}] | {rw} | BS={bs} | Jobs={nj} | QD={qd}")
                        j_file = run_fio("seq", d, rw, bs, qd, nj, args.runtime, args.raw_dir)
                        res = parse_fio_json(j_file)
                        res.update({"drive": os.path.basename(d), "pattern": f"seq_{rw}", "bs": bs, "nj": nj, "qd": qd})
                        results.append(res)

    # 2. 随机读写测试
    if args.rand_pre == 'yes':
        print("\n=== [预处理] 执行 4k 随机写预处理 (全盘循环1遍) ===")
        for d in devs: run_fio("pre_rand", d, "randwrite", "4k", 128, 4, 0, args.raw_dir, loops=1)

    for rw in ['randread', 'randwrite']:
        print(f"\n===[遍历测试] 随机 {rw} ===")
        curr = 0
        for bs in BS_LIST:
            for nj in NUMJOBS_LIST:
                for qd in IODEPTH_LIST:
                    curr += 1
                    for d in devs:
                        print(f"  -> 进度[{curr}/{total_tasks}] | {rw} | BS={bs} | Jobs={nj} | QD={qd}")
                        j_file = run_fio("rand", d, rw, bs, qd, nj, args.runtime, args.raw_dir)
                        res = parse_fio_json(j_file)
                        res.update({"drive": os.path.basename(d), "pattern": f"{rw}", "bs": bs, "nj": nj, "qd": qd})
                        results.append(res)

    # 3. 混合读写测试
    print("\n=== [遍历测试] 混合读写 (Mixed RW) ===")
    for bs in['4k', '8k', '16k', '32k']:
        for ratio in MIX_RATIO_LIST:
            for d in devs:
                print(f"  -> 混合读写 | BS={bs} | Ratio={ratio}R/{100-ratio}W")
                j_file = run_fio(f"mixed_{ratio}", d, "randrw", bs, 128, 8, args.mix_runtime, args.raw_dir, rwmixread=ratio)
                res = parse_fio_json(j_file)
                mixed_results.append({
                    "bs_ratio": f"{bs}_{ratio}", 
                    "read_8_128": res['iops'] * (ratio/100), 
                    "write_8_128": res['iops'] * ((100-ratio)/100)
                })

    # 4. QoS 测试
    print("\n===[遍历测试] 一致性和 QoS 测试 ===")
    for bs in['4k', '8k', '16k']:
        for d in devs:
            for rw in ['randread', 'randwrite']:
                print(f"  -> QoS 测试 | {rw} | BS={bs}")
                j_file = run_fio("qos", d, rw, bs, 64, 4, args.qos_runtime, args.raw_dir)
                res = parse_fio_json(j_file)
                res.update({"drive": os.path.basename(d), "pattern": f"qos_{rw}", "bs": bs, "nj": 4, "qd": 64})
                results.append(res)

    # 5. 生成 Excel 报告
    if not results:
        print("\n[ERROR] 数据集为空。测试未正常运行！")
        sys.exit(1)
        
    df_all = pd.DataFrame(results)
    generate_strict_excel(df_all, mixed_results, args.out_excel, args.model)

if __name__ == "__main__":
    main()
EOF

sed -i 's/^EOF.*/EOF/' "$PYTHON_ENGINE"

# ====================[ 4. 触发核心测试 ] ====================
EXCEL_REPORT="${BASE_DIR}/Cloud_qual_NVMe_Report_${SERVER_MODEL}.xlsx"

echo "=========================================================================="
echo "[警告] 即将抹除盘内数据并启动测试！"
echo "[提示] 请确认您当前正处于 screen / tmux / OS终端 会话中。"
echo "=========================================================================="
sleep 10

python3 "$PYTHON_ENGINE" \
    --devs "${TARGET_DEVS[*]}" \
    --runtime "$RUNTIME" \
    --mix_runtime "$MIX_RUNTIME" \
    --qos_runtime "$QOS_RUNTIME" \
    --raw_dir "$RAW_DIR" \
    --seq_pre "$DO_SEQ_PRECON" \
    --rand_pre "$DO_RAND_PRECON" \
    --out_excel "$EXCEL_REPORT" \
    --model "$SERVER_MODEL"

# ====================[ 5. 抓取日志 & 健康检查 ] ====================
echo "[INFO] 测试全部结束，正在抓取日志..."
dmesg -T > "$LOG_DIR/post_dmesg.log"
nvme smart-log "${TARGET_DEVS[0]}" > "$LOG_DIR/post_smart.log"

if command -v ipmitool >/dev/null 2>&1; then
    ipmitool sel elist > "$LOG_DIR/post_ipmi_sel.log"
fi

echo "[INFO] 执行异常自检 (PCIe Error / Timeout)..."
echo "[INFO] === 异常自检结果 === " > "$LOG_DIR/error_check_summary.txt"
err_count=$(grep -iE 'pcie bus error|aer|bad tlp|bad dllp|nvme.*timeout|i/o error' "$LOG_DIR/post_dmesg.log" | wc -l)
if [ "$err_count" -gt 0 ]; then
    echo "[WARN] 在 OS dmesg 日志中发现了 $err_count 处相关报错，请检查 $LOG_DIR/post_dmesg.log" | tee -a "$LOG_DIR/error_check_summary.txt"
    grep -iE 'pcie bus error|aer|bad tlp|bad dllp|nvme.*timeout|i/o error' "$LOG_DIR/post_dmesg.log" | tail -n 10 | tee -a "$LOG_DIR/error_check_summary.txt"
else
    echo "[PASS] OS dmesg 日志未检测到 PCIe / IO 异常。" | tee -a "$LOG_DIR/error_check_summary.txt"
fi

echo "=========================================================================="
echo "测试已全部完成。"
echo "原始数据存放于:  $RAW_DIR"
echo "日志目录存放于:  $LOG_DIR"
echo "报表存放于:  $EXCEL_REPORT"
echo "=========================================================================="
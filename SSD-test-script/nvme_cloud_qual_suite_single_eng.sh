#!/bin/bash
# ============================================================================
# NVMe Cloud Qualification Suite - by Prz1y
# ============================================================================
# Pre-test Environment & Configuration Requirements:
# 1. Required tools: fio, nvme-cli, ipmitool, pciutils (for lspci)
# 2. Required Python3 dependencies: pip install pandas openpyxl
# 3. Always run in a persistent session: yum/apt-get install -y tmux & tmux new -s nvme_test 
#    or run directly from a physical OS console.
# 4. DO NOT run this suite on a system drive or any drive containing important data! 
#    All data on the target drive WILL BE DESTROYED.
# ============================================================================

# ====================[ 1. Core Configuration ] ====================
TARGET_DEVS=("/dev/nvme0n1") 
TEST_MODE="single"

# Test Duration (Seconds)
RUNTIME=300           # Sequential/Random testing: 300s (5 mins)
MIX_RUNTIME=1800      # Mixed Read/Write testing: 1800s (30 mins)
QOS_RUNTIME=3600      # Consistency & QoS testing: 3600s (1 hour)

# Preconditioning (Full drive capacity)
DO_SEQ_PRECON="yes"   # 128k sequential write (2 loops) before seq testing
DO_RAND_PRECON="yes"  # 4k random write (1 loop) before rand testing

SERVER_MODEL="Server" # Server model, used as the identifier in the Excel report

# ====================[ 2. Environment Initialization ] ====================
BASE_DIR="$(pwd)/NVME_TEST_PROD_$(date +%Y%m%d_%H%M%S)"
RAW_DIR="${BASE_DIR}/raw_data"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "$RAW_DIR" "$LOG_DIR"
echo "[INFO] Test data and reports will be saved to: $BASE_DIR"
echo "[INFO] Capturing pre-test system logs..."

dmesg -T > "$LOG_DIR/pre_dmesg.log"
lspci -vvv > "$LOG_DIR/pre_lspci.log"
nvme smart-log "${TARGET_DEVS[0]}" > "$LOG_DIR/pre_smart.log"
if command -v ipmitool >/dev/null 2>&1; then
    ipmitool sel elist > "$LOG_DIR/pre_ipmi_sel.log"
fi

# ==================== [ 3. Python Testing Engine Injection ] ====================
PYTHON_ENGINE="${BASE_DIR}/nvme_fio_engine.py"

cat << 'EOF' > "$PYTHON_ENGINE"
import os, sys, json, time, subprocess, argparse
from concurrent.futures import ThreadPoolExecutor
import pandas as pd

# Test Parameter Matrix
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
        print(f"    [ERROR] Execution failed: {e}")
        return False

def format_drive(dev):
    print(f"\n[WARN] Performing NVMe Secure Erase (Format -s 1) on {dev}...")
    run_cmd(f"nvme format {dev} -s 1")
    time.sleep(10)

def run_fio(job_name, dev, rw, bs, iodepth, numjobs, runtime, raw_dir, loops=0, rwmixread=None):
    dev_name = os.path.basename(dev)
    json_out = os.path.join(raw_dir, f"{job_name}_{dev_name}_{rw}_{bs}_{numjobs}j_{iodepth}qd.json")
    
    cmd = f"fio --name={job_name} --filename={dev} --rw={rw} --bs={bs} --iodepth={iodepth} --numjobs={numjobs} --direct=1 --group_reporting --output-format=json --output={json_out}"
    
    if loops > 0:
        # Preconditioning
        cmd += f" --loops={loops} --size=100%"
    else:
        # Matrix Testing
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
        
        # Convert bandwidth to MB/s
        bw_mb = tgt['bw_bytes'] / (1024 * 1024)
        iops = tgt['iops']
        
        # Convert latency to us (microseconds)
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
    print("\n[INFO] Generating standard Excel report...")
    
    QDS_STRICT =[1, 2, 4, 8, 16, 32, 64, 128, 256]
    MATRIX_COLS =[f"{n}_{q}" for n in NUMJOBS_LIST for q in QDS_STRICT]
    
    with pd.ExcelWriter(out_excel, engine='openpyxl') as writer:
        
        sheet_mapping = {
            'seq_read': '顺序读测试', 'seq_write': '顺序写测试', 
            'randread': '随机读测试', 'randwrite': '随机写测试'
        }
        for ptn, sheet_name in sheet_mapping.items():
            iops_dict = {bs: {c: "" for c in MATRIX_COLS} for bs in BS_LIST}
            lat_rows =[]
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
        
    print(f"\n[SUCCESS] Test report generated: {out_excel}")


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

    # 1. Sequential Read/Write Testing
    if args.seq_pre == 'yes':
        print("\n=== [Preconditioning] Executing 128k Sequential Write (2 loops over the drive) ===")
        for d in devs: run_fio("pre_seq", d, "write", "128k", 128, 1, 0, args.raw_dir, loops=2)

    for rw in['read', 'write']:
        print(f"\n===[Matrix Testing] Sequential {rw} ===")
        total_tasks = len(BS_LIST) * len(NUMJOBS_LIST) * len(IODEPTH_LIST)
        curr = 0
        for bs in BS_LIST:
            for nj in NUMJOBS_LIST:
                for qd in IODEPTH_LIST:
                    curr += 1
                    for d in devs:
                        print(f"  -> Progress [{curr}/{total_tasks}] | {rw} | BS={bs} | Jobs={nj} | QD={qd}")
                        j_file = run_fio("seq", d, rw, bs, qd, nj, args.runtime, args.raw_dir)
                        res = parse_fio_json(j_file)
                        res.update({"drive": os.path.basename(d), "pattern": f"seq_{rw}", "bs": bs, "nj": nj, "qd": qd})
                        results.append(res)

    # 2. Random Read/Write Testing
    if args.rand_pre == 'yes':
        print("\n=== [Preconditioning] Executing 4k Random Write (1 loop over the drive) ===")
        for d in devs: run_fio("pre_rand", d, "randwrite", "4k", 128, 4, 0, args.raw_dir, loops=1)

    for rw in ['randread', 'randwrite']:
        print(f"\n=== [Matrix Testing] Random {rw} ===")
        curr = 0
        for bs in BS_LIST:
            for nj in NUMJOBS_LIST:
                for qd in IODEPTH_LIST:
                    curr += 1
                    for d in devs:
                        print(f"  -> Progress [{curr}/{total_tasks}] | {rw} | BS={bs} | Jobs={nj} | QD={qd}")
                        j_file = run_fio("rand", d, rw, bs, qd, nj, args.runtime, args.raw_dir)
                        res = parse_fio_json(j_file)
                        res.update({"drive": os.path.basename(d), "pattern": f"{rw}", "bs": bs, "nj": nj, "qd": qd})
                        results.append(res)

    # 3. Mixed Read/Write Testing
    print("\n===[Matrix Testing] Mixed Read/Write (Mixed RW) ===")
    for bs in['4k', '8k', '16k', '32k']:
        for ratio in MIX_RATIO_LIST:
            for d in devs:
                print(f"  -> Mixed RW | BS={bs} | Ratio={ratio}R/{100-ratio}W")
                j_file = run_fio(f"mixed_{ratio}", d, "randrw", bs, 128, 8, args.mix_runtime, args.raw_dir, rwmixread=ratio)
                res = parse_fio_json(j_file)
                mixed_results.append({
                    "bs_ratio": f"{bs}_{ratio}", 
                    "read_8_128": res['iops'] * (ratio/100), 
                    "write_8_128": res['iops'] * ((100-ratio)/100)
                })

    # 4. Consistency & QoS Testing
    print("\n=== [Matrix Testing] Consistency & QoS Test ===")
    for bs in['4k', '8k', '16k']:
        for d in devs:
            for rw in['randread', 'randwrite']:
                print(f"  -> QoS Test | {rw} | BS={bs}")
                j_file = run_fio("qos", d, rw, bs, 64, 4, args.qos_runtime, args.raw_dir)
                res = parse_fio_json(j_file)
                res.update({"drive": os.path.basename(d), "pattern": f"qos_{rw}", "bs": bs, "nj": 4, "qd": 64})
                results.append(res)

    # 5. Generate Excel Report
    if not results:
        print("\n[ERROR] Dataset is empty. Tests did not run properly!")
        sys.exit(1)
        
    df_all = pd.DataFrame(results)
    generate_strict_excel(df_all, mixed_results, args.out_excel, args.model)

if __name__ == "__main__":
    main()
EOF

sed -i 's/^EOF.*/EOF/' "$PYTHON_ENGINE"

# ====================[ 4. Trigger Core Tests ] ====================
EXCEL_REPORT="${BASE_DIR}/Cloud_qual_NVMe_Report_${SERVER_MODEL}.xlsx"

echo "=========================================================================="
echo "[WARNING] About to erase data on the drive(s) and start the test!"
echo "[NOTICE] Please confirm you are currently in a screen / tmux / OS console session."
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

# ====================[ 5. Capture Post-test Logs & Health Check ] ====================
echo "[INFO] All tests finished, capturing post-test logs..."
dmesg -T > "$LOG_DIR/post_dmesg.log"
nvme smart-log "${TARGET_DEVS[0]}" > "$LOG_DIR/post_smart.log"

if command -v ipmitool >/dev/null 2>&1; then
    ipmitool sel elist > "$LOG_DIR/post_ipmi_sel.log"
fi

echo "[INFO] Running anomaly self-check (PCIe Error / Timeout)..."
echo "[INFO] === Anomaly Self-Check Results === " > "$LOG_DIR/error_check_summary.txt"
err_count=$(grep -iE 'pcie bus error|aer|bad tlp|bad dllp|nvme.*timeout|i/o error' "$LOG_DIR/post_dmesg.log" | wc -l)
if[ "$err_count" -gt 0 ]; then
    echo "[WARNING] Found $err_count related error(s) in OS dmesg logs. Please check $LOG_DIR/post_dmesg.log" | tee -a "$LOG_DIR/error_check_summary.txt"
    grep -iE 'pcie bus error|aer|bad tlp|bad dllp|nvme.*timeout|i/o error' "$LOG_DIR/post_dmesg.log" | tail -n 10 | tee -a "$LOG_DIR/error_check_summary.txt"
else
    echo "[PASS] No PCIe / IO anomalies detected in OS dmesg logs." | tee -a "$LOG_DIR/error_check_summary.txt"
fi

echo "=========================================================================="
echo "Testing has been fully completed."
echo "Raw data saved to:      $RAW_DIR"
echo "Log directory:          $LOG_DIR"
echo "Generated report:       $EXCEL_REPORT"
echo "=========================================================================="
#!/bin/bash
# ============================================================================
# NVMe Storage Performance Test Suite
# ============================================================================
# Features:
# 1. 多盘同步并发测试，动态生成自适应的 Excel 报表。
# 2. 智能 NUMA 节点侦测与线程绑定 (支持 fio 原生或 numactl)。
# 3. 支持参数矩阵全量遍历、预热机制 (ramp_time) 及混合读写比例测试。
# 4. 包含严格的错误处理、依赖检查与自动重试机制。
# 5. 模块化测试大项开关与自定义块大小 (Block Size) 支持。
# 
# Dependencies:
# sudo yum/apt-get install -y fio nvme-cli pciutils python3 python3-pip numactl ipmitool
# pip3 install pandas openpyxl
# ============================================================================

# ============================================================================
# [ 核心配置区 ]
# ============================================================================

# 1. 运行模式设置 (TEST_MODE)
# - single : 全量遍历模式 (执行全部参数组合笛卡尔积，输出详细矩阵 Sheet)
# - multi  : 抽样模式 (仅执行特定负载组合，用于快速验证)
TEST_MODE="single"

# 2. 被测块设备阵列 (TARGET_DEVS)
# 支持填入多块盘，以空格分隔。例如: ("/dev/nvme0n1" "/dev/nvme1n1")
# [警告] 测试会执行格式化，禁止填入系统盘或存有重要数据的磁盘！
TARGET_DEVS=("/dev/nvme0n1")

# 3. 测试项目标识 (将作为生成的 Excel 文件名及表头标识)
SERVER_MODEL="Server"

# 4. 测试时长与预处理配置
RUNTIME=300           # 常规顺序/随机测试时长 (单位: 秒)
MIX_RUNTIME=1800      # 混合读写测试时长 (单位: 秒)
QOS_RUNTIME=3600      # QoS 一致性测试时长 (单位: 秒)

DO_SEQ_PRECON="yes"   # 顺序读写前是否进行预处理 (默认 128k 顺序写)
SEQ_PRE_LOOPS=2       # 顺序预处理的全盘循环遍数
DO_RAND_PRECON="yes"  # 随机读写前是否进行预处理 (默认 4k 随机写)
RAND_PRE_LOOPS=1      # 随机预处理的全盘循环遍数

# 5. 测试阶段模块开关 (yes / no)
RUN_SEQ_READ="yes"
RUN_SEQ_WRITE="yes"
RUN_RAND_READ="yes"
RUN_RAND_WRITE="yes"
RUN_MIXED_RW="yes"
RUN_QOS_TEST="no"     # 默认关闭多余的 QoS 稳定性长测

# 6. 块大小 (Block Size) 遍历列表 (以空格分隔)
TEST_BS_LIST="4k 8k 16k 32k 64k 128k 256k 512k 1m"

# 7. 断点续测配置 (RESUME_FROM)
# 若需从意外中断的测试中恢复，请填入上次生成的测试目录路径。为空则启动全新测试。
RESUME_FROM=""

# ============================================================================
# [ NUMA 智能绑定配置区 ]
# ============================================================================
ENABLE_NUMA_BIND="yes"       # 是否开启 NUMA 节点绑定
NUMA_BIND_METHOD="fio"       # 绑定方式: "fio" (--numa_cpu_nodes) 或 "numactl"
NUMA_FALLBACK_NODE="0"       # 兜底 NUMA 节点

# ============================================================================
# [ 环境与安全前置检查 ]
# ============================================================================

echo "[INFO] Commencing pre-flight system checks..."

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This suite requires root privileges. Please run as root."
    exit 1
fi

for tool in fio nvme lspci python3; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo "[ERROR] Required dependency '$tool' is not installed."
        exit 1
    fi
done

for dev in "${TARGET_DEVS[@]}"; do
    if [ ! -b "$dev" ]; then
        echo "[ERROR] Block device '$dev' does not exist or is invalid."
        exit 1
    fi
done

if [ -n "$RESUME_FROM" ] && [ -d "$RESUME_FROM" ]; then
    BASE_DIR="$RESUME_FROM"
    RESUME_FLAG="--resume"
    echo "[INFO] Resuming from existing workspace: $BASE_DIR"
else
    BASE_DIR="$(pwd)/NVME_TEST_$(date +%Y%m%d_%H%M%S)"
    RESUME_FLAG=""
    echo "[INFO] Test workspace created at: $BASE_DIR"
fi

RAW_DIR="${BASE_DIR}/raw_data"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "$RAW_DIR" "$LOG_DIR"

# 抓取初始系统日志用于异常对比
dmesg -T > "$LOG_DIR/pre_dmesg.log" 2>/dev/null || true
lspci -vvv > "$LOG_DIR/pre_lspci.log" 2>/dev/null || true
nvme smart-log "${TARGET_DEVS[0]}" > "$LOG_DIR/pre_smart.log" 2>/dev/null || true

# ==================== [ Python 测试引擎注入 ] ====================
PYTHON_ENGINE="${BASE_DIR}/nvme_fio_engine.py"

cat << 'EOF' > "$PYTHON_ENGINE"
import os, sys, json, time, subprocess, argparse, datetime
from concurrent.futures import ThreadPoolExecutor
import pandas as pd

# ----------------------------------------------------------------------------
# 参数矩阵定义
# ----------------------------------------------------------------------------
# 全量遍历基础参数
NUMJOBS_LIST =[1, 2, 4, 8]
IODEPTH_LIST =[1, 2, 4, 8, 16, 32, 64, 128, 256]
MIX_RATIO_LIST =[10, 20, 30, 40, 50, 60, 70, 80, 90]

# Multi 模式备用抽样组合 (Single 模式下不生效)
SEQ_COMBOS =[('128k', 1, 32)] 
RAND_COMBOS =[('4k', 1, 32)]

def log_print(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")

def get_drive_info(dev):
    """获取 NVMe 硬盘的型号与固件版本"""
    try:
        res = subprocess.run(f"nvme id-ctrl {dev}", shell=True, capture_output=True, text=True)
        mn, fr = "Unknown_Model", "Unknown_FW"
        for line in res.stdout.split('\n'):
            if line.strip().startswith('mn'):
                mn = line.split(':', 1)[1].strip()
            elif line.strip().startswith('fr'):
                fr = line.split(':', 1)[1].strip()
        return f"{mn} | {fr}"
    except Exception:
        return "Unknown | Unknown"

def get_numa_node(dev_path, fallback):
    """自动获取硬盘对应的 PCIe NUMA Node"""
    try:
        dev_name = os.path.basename(dev_path)
        ctrl_name = dev_name.split('n')[0]
        sysfs_path = f"/sys/class/nvme/{ctrl_name}/device/numa_node"
        if os.path.exists(sysfs_path):
            with open(sysfs_path, 'r') as f:
                node = int(f.read().strip())
                return node if node >= 0 else fallback
    except Exception:
        pass
    return fallback

def run_cmd(cmd, log_file=None):
    """执行 Shell 命令并记录日志"""
    try:
        res = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if log_file:
            with open(log_file, 'w') as f:
                f.write(f"COMMAND: {cmd}\n\n{res.stdout}")
        return res.returncode == 0
    except Exception as e:
        log_print(f"[ERROR] Subprocess failed: {e}")
        return False

def format_drive(dev):
    """执行 NVMe 安全擦除"""
    for attempt in range(1, 4):
        log_print(f"[INFO] Formatting {dev} (Attempt {attempt}/3)...")
        if run_cmd(f"nvme format {dev} -s 1"):
            time.sleep(10)
            return True
        time.sleep(5)
    log_print(f"[CRITICAL] Failed to secure erase {dev} after 3 attempts.")
    sys.exit(1)

def build_fio_cmd(job_name, dev, rw, bs, iodepth, numjobs, runtime, json_out, args, loops=0, rwmixread=None):
    """构建 FIO 测试命令"""
    cmd = f"fio --name={job_name} --filename={dev} --rw={rw} --bs={bs} --iodepth={iodepth} --numjobs={numjobs} --direct=1 --group_reporting --output-format=json --output={json_out}"
    
    if loops > 0:
        # 预处理模式：按全盘容量比例写入 (无预热)
        cmd += f" --loops={loops} --size=100%"
    else:
        # 常规测试模式：基于时间运行，并设置 30s 预热机制
        cmd += f" --ramp_time=30 --runtime={runtime} --time_based"
        
    if rwmixread is not None:
        cmd += f" --rwmixread={rwmixread}"

    # 应用 NUMA 节点绑定
    if args.enable_numa == 'yes':
        node = get_numa_node(dev, args.fallback_node)
        if args.numa_method == 'fio':
            cmd += f" --numa_cpu_nodes={node}"
        elif args.numa_method == 'numactl':
            cmd = f"numactl -N {node} -m {node} {cmd}"
            
    return cmd

def run_fio_task(task_args):
    """单体 FIO 任务执行包装器"""
    job_name, dev, rw, bs, iodepth, numjobs, runtime, raw_dir, args, loops, rwmixread = task_args
    dev_name = os.path.basename(dev)
    json_out = os.path.join(raw_dir, f"{job_name}_{dev_name}_{rw}_{bs}_{numjobs}j_{iodepth}qd.json")
    log_out = json_out.replace('.json', '.log')
    
    # 断点续测逻辑
    if args.resume and os.path.exists(json_out) and os.path.getsize(json_out) > 0:
        log_print(f"[RESUME] Skipping existing task: {os.path.basename(json_out)}")
        return (json_out, dev_name)

    cmd = build_fio_cmd(job_name, dev, rw, bs, iodepth, numjobs, runtime, json_out, args, loops, rwmixread)
    run_cmd(cmd, log_out)
    return (json_out, dev_name)

def execute_synchronized_parallel(devs, job_name, rw, bs, iodepth, numjobs, runtime, raw_dir, args, loops=0, rwmixread=None):
    """使用线程池实现多盘并发测试"""
    tasks =[(job_name, d, rw, bs, iodepth, numjobs, runtime, raw_dir, args, loops, rwmixread) for d in devs]
    json_results =[]
    with ThreadPoolExecutor(max_workers=len(devs)) as executor:
        for result in executor.map(run_fio_task, tasks):
            json_results.append(result)
    return json_results

def parse_fio_json(json_file, is_mixed=False):
    """解析 FIO 生成的 JSON 数据文件"""
    if not os.path.exists(json_file):
        return None
    try:
        with open(json_file, 'r') as f:
            data = json.load(f)
        job = data['jobs'][0]
        
        r_iops = job['read']['iops']
        w_iops = job['write']['iops']
        
        if is_mixed:
            return {"read_iops": round(r_iops, 2), "write_iops": round(w_iops, 2)}
            
        tgt = job['read'] if r_iops > w_iops else job['write']
        
        bw_mb = tgt['bw_bytes'] / (1024 * 1024)
        iops = tgt['iops']
        
        # 时延统一转换为 us (微秒)
        lat_dict = tgt.get('lat_ns', {})
        min_lat = lat_dict.get('min', 0) / 1000.0
        avg_lat = lat_dict.get('mean', 0) / 1000.0
        max_lat = lat_dict.get('max', 0) / 1000.0
        
        clat_dict = tgt.get('clat_ns', {}).get('percentile', {})
        p9999 = clat_dict.get('99.990000', 0) / 1000.0
        if p9999 == 0:
            p9999 = clat_dict.get('99.900000', 0) / 1000.0
            
        return {"iops": round(iops, 2), "bw": round(bw_mb, 2), "min_lat": round(min_lat, 2), 
                "avg_lat": round(avg_lat, 2), "max_lat": round(max_lat, 2), "p9999": round(p9999, 2)}
    except Exception as e:
        return None

def get_val(df, dev, ptn, bs, nj, qd, metric):
    match = df[(df['drive'] == dev) & (df['pattern'] == ptn) & (df['bs'] == bs) & (df['nj'] == nj) & (df['qd'] == qd)]
    return match.iloc[0][metric] if not match.empty else ""

def generate_excel(df_all, mixed_results, args, devs, drive_infos):
    """生成测试报告 Excel"""
    log_print("[INFO] Compiling data into standard Excel report...")
    out_excel = args.out_excel
    bs_list = args.bs_list.split()
    
    with pd.ExcelWriter(out_excel, engine='openpyxl') as writer:
        
        # 1. 详细矩阵数据 Sheet
        if args.mode == 'single':
            QDS_STRICT =[1, 2, 4, 8, 16, 32, 64, 128, 256]
            MATRIX_COLS =[f"{n}_{q}" for n in NUMJOBS_LIST for q in QDS_STRICT]
            
            sheet_mapping = {
                'seq_read': '顺序读测试', 'seq_write': '顺序写测试', 
                'randread': '随机读测试', 'randwrite': '随机写测试'
            }
            target_dev = os.path.basename(devs[0]) 
            
            for ptn, sheet_name in sheet_mapping.items():
                if ptn not in df_all['pattern'].values: continue
                
                iops_dict = {bs: {c: "" for c in MATRIX_COLS} for bs in bs_list}
                lat_rows =[]
                for bs in bs_list:
                    lat_rows.extend([f"{bs}_min_lat", f"{bs}_avg_lat", f"{bs}_max_lat", f"{bs}_99.99th_lat"])
                lat_dict = {r: {c: "" for c in MATRIX_COLS} for r in lat_rows}

                ptn_df = df_all[(df_all['pattern'] == ptn) & (df_all['drive'] == target_dev)]
                for _, r in ptn_df.iterrows():
                    c = f"{r['nj']}_{r['qd']}"
                    if c in MATRIX_COLS and r['bs'] in iops_dict:
                        bs = r['bs']
                        iops_dict[bs][c] = r['iops']
                        lat_dict[f"{bs}_min_lat"][c] = r['min_lat']
                        lat_dict[f"{bs}_avg_lat"][c] = r['avg_lat']
                        lat_dict[f"{bs}_max_lat"][c] = r['max_lat']
                        lat_dict[f"{bs}_99.99th_lat"][c] = r['p9999']

                df_iops = pd.DataFrame.from_dict(iops_dict, orient='index')
                df_lat = pd.DataFrame.from_dict(lat_dict, orient='index')
                
                pd.DataFrame([["iops:bs_thread_iodepth"]]).to_excel(writer, sheet_name=sheet_name, startrow=0, startcol=0, header=False, index=False)
                df_iops.to_excel(writer, sheet_name=sheet_name, startrow=1)
                
                lat_start_row = len(bs_list) + 3
                pd.DataFrame([["latency:bs_thread_iodepth"]]).to_excel(writer, sheet_name=sheet_name, startrow=lat_start_row, startcol=0, header=False, index=False)
                df_lat.to_excel(writer, sheet_name=sheet_name, startrow=lat_start_row+1)

        # 2. 混合读写数据 Sheet
        if mixed_results:
            pd.DataFrame(mixed_results).to_excel(writer, sheet_name='混合读写', index=False)

        # 3. 全局原始扁平数据 Sheet
        df_all.to_excel(writer, sheet_name="Raw_Matrix_Data", index=False)
        
    log_print(f"[SUCCESS] Report successfully generated: {out_excel}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--devs', required=True)
    parser.add_argument('--mode', required=True)
    parser.add_argument('--runtime', type=int, required=True)
    parser.add_argument('--mix_runtime', type=int, required=True)
    parser.add_argument('--qos_runtime', type=int, required=True)
    parser.add_argument('--raw_dir', required=True)
    parser.add_argument('--out_excel', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--bs_list', required=True)
    parser.add_argument('--seq_pre', required=True)
    parser.add_argument('--seq_loops', type=int, required=True)
    parser.add_argument('--rand_pre', required=True)
    parser.add_argument('--rand_loops', type=int, required=True)
    
    parser.add_argument('--enable_numa', required=True)
    parser.add_argument('--numa_method', required=True)
    parser.add_argument('--fallback_node', type=int, required=True)

    parser.add_argument('--run_seq_read', required=True)
    parser.add_argument('--run_seq_write', required=True)
    parser.add_argument('--run_rand_read', required=True)
    parser.add_argument('--run_rand_write', required=True)
    parser.add_argument('--run_mixed', required=True)
    parser.add_argument('--run_qos', required=True)
    parser.add_argument('--resume', action='store_true')
    
    args = parser.parse_args()
    devs = args.devs.split()
    bs_list = args.bs_list.split()
    results =[] 
    mixed_results = []
    
    log_print("[INFO] Initiating drive preparation...")
    drive_infos = {}
    for d in devs:
        if not args.resume:
            format_drive(d)
        drive_infos[d] = get_drive_info(d)

    # ----- 1. 顺序读写模块 -----
    if args.run_seq_read == 'yes' or args.run_seq_write == 'yes':
        if args.seq_pre == 'yes':
            log_print("\n[INFO] === Executing Sequential Preconditioning ===")
            execute_synchronized_parallel(devs, "pre_seq", "write", "128k", 128, 1, 0, args.raw_dir, args, loops=args.seq_loops)

        for rw, run_flag in[('read', args.run_seq_read), ('write', args.run_seq_write)]:
            if run_flag != 'yes': continue
            log_print(f"\n[INFO] === Matrix Testing: Sequential {rw} ===")
            
            combos_to_run = SEQ_COMBOS if args.mode == 'multi' else[(b, n, q) for b in bs_list for n in NUMJOBS_LIST for q in IODEPTH_LIST]
            combos_to_run = [c for c in combos_to_run if c[0] in bs_list]
            
            for i, (bs, nj, qd) in enumerate(combos_to_run, 1):
                log_print(f"  -> Progress[{i}/{len(combos_to_run)}] | {rw} | BS={bs} | Jobs={nj} | QD={qd}")
                json_files = execute_synchronized_parallel(devs, "seq", rw, bs, qd, nj, args.runtime, args.raw_dir, args)
                for jf, d_name in json_files:
                    res = parse_fio_json(jf)
                    if res:
                        res.update({"drive": d_name, "pattern": f"seq_{rw}", "bs": bs, "nj": nj, "qd": qd})
                        results.append(res)

    # ----- 2. 随机读写模块 -----
    if args.run_rand_read == 'yes' or args.run_rand_write == 'yes':
        if args.rand_pre == 'yes':
            log_print("\n[INFO] === Executing Random Preconditioning ===")
            execute_synchronized_parallel(devs, "pre_rand", "randwrite", "4k", 128, 4, 0, args.raw_dir, args, loops=args.rand_loops)

        for rw, run_flag in[('randread', args.run_rand_read), ('randwrite', args.run_rand_write)]:
            if run_flag != 'yes': continue
            log_print(f"\n[INFO] === Matrix Testing: Random {rw} ===")
            
            combos_to_run = RAND_COMBOS if args.mode == 'multi' else[(b, n, q) for b in bs_list for n in NUMJOBS_LIST for q in IODEPTH_LIST]
            combos_to_run = [c for c in combos_to_run if c[0] in bs_list]
            
            for i, (bs, nj, qd) in enumerate(combos_to_run, 1):
                log_print(f"  -> Progress[{i}/{len(combos_to_run)}] | {rw} | BS={bs} | Jobs={nj} | QD={qd}")
                json_files = execute_synchronized_parallel(devs, "rand", rw, bs, qd, nj, args.runtime, args.raw_dir, args)
                for jf, d_name in json_files:
                    res = parse_fio_json(jf)
                    if res:
                        res.update({"drive": d_name, "pattern": f"{rw}", "bs": bs, "nj": nj, "qd": qd})
                        results.append(res)

    # ----- 3. 混合读写模块 -----
    if args.run_mixed == 'yes':
        log_print("\n[INFO] === Matrix Testing: Mixed RW ===")
        mix_bs =[b for b in ['4k', '8k', '16k', '32k'] if b in bs_list]
        for bs in mix_bs:
            for ratio in MIX_RATIO_LIST:
                log_print(f"  -> Mixed RW | BS={bs} | Ratio={ratio}R/{100-ratio}W")
                json_files = execute_synchronized_parallel(devs, f"mixed_{ratio}", "randrw", bs, 64, 4, args.mix_runtime, args.raw_dir, args, rwmixread=ratio)
                for jf, d_name in json_files:
                    res = parse_fio_json(jf, is_mixed=True)
                    if res:
                        mixed_results.append({
                            "drive": d_name, "bs_ratio": f"{bs}_{ratio}", 
                            "read_8_128": res['read_iops'], "write_8_128": res['write_iops']
                        })

    if not results and not mixed_results:
        log_print("[ERROR] Final dataset is empty. Check log outputs.")
        sys.exit(1)
        
    generate_excel(pd.DataFrame(results) if results else pd.DataFrame(), mixed_results, args, devs, drive_infos)

if __name__ == "__main__":
    main()
EOF

# ====================[ 执行与触发 ] ====================
EXCEL_REPORT="${BASE_DIR}/Storage_Performance_Report_${SERVER_MODEL}.xlsx"

echo "=========================================================================="
echo "[WARNING] Enterprise NVMe Test Suite is armed and ready."
echo "[INFO] Matrix Test Mode: $TEST_MODE"
echo "[INFO] Drives targeted: ${TARGET_DEVS[*]}"
echo "=========================================================================="
sleep 10

python3 "$PYTHON_ENGINE" \
    --devs "${TARGET_DEVS[*]}" \
    --mode "$TEST_MODE" \
    --runtime "$RUNTIME" \
    --mix_runtime "$MIX_RUNTIME" \
    --qos_runtime "$QOS_RUNTIME" \
    --raw_dir "$RAW_DIR" \
    --out_excel "$EXCEL_REPORT" \
    --model "$SERVER_MODEL" \
    --bs_list "$TEST_BS_LIST" \
    --seq_pre "$DO_SEQ_PRECON" \
    --seq_loops "$SEQ_PRE_LOOPS" \
    --rand_pre "$DO_RAND_PRECON" \
    --rand_loops "$RAND_PRE_LOOPS" \
    --enable_numa "$ENABLE_NUMA_BIND" \
    --numa_method "$NUMA_BIND_METHOD" \
    --fallback_node "$NUMA_FALLBACK_NODE" \
    --run_seq_read "$RUN_SEQ_READ" \
    --run_seq_write "$RUN_SEQ_WRITE" \
    --run_rand_read "$RUN_RAND_READ" \
    --run_rand_write "$RUN_RAND_WRITE" \
    --run_mixed "$RUN_MIXED_RW" \
    --run_qos "$RUN_QOS_TEST" \
    $RESUME_FLAG

# ====================[ 测试后诊断信息收集 ] ====================
echo "[INFO] Capturing post-flight diagnostics..."
dmesg -T > "$LOG_DIR/post_dmesg.log" 2>/dev/null || true
nvme smart-log "${TARGET_DEVS[0]}" > "$LOG_DIR/post_smart.log" 2>/dev/null || true

if command -v ipmitool >/dev/null 2>&1; then
    ipmitool sel elist > "$LOG_DIR/post_ipmi_sel.log" 2>/dev/null || true
fi

echo "[INFO] Performing automated anomaly detection (PCIe/AER/Timeout)..."
echo "=== Anomaly Self-Check ===" > "$LOG_DIR/error_check_summary.txt"
err_count=$(grep -iE 'pcie bus error|aer|bad tlp|bad dllp|nvme.*timeout|i/o error' "$LOG_DIR/post_dmesg.log" | wc -l)

if [ "$err_count" -gt 0 ]; then
    echo "[WARNING] Found $err_count related hardware errors in dmesg. Inspect $LOG_DIR/post_dmesg.log" | tee -a "$LOG_DIR/error_check_summary.txt"
    grep -iE 'pcie bus error|aer|bad tlp|bad dllp|nvme.*timeout|i/o error' "$LOG_DIR/post_dmesg.log" | tail -n 10 | tee -a "$LOG_DIR/error_check_summary.txt"
else
    echo "[PASS] System logs are clean. No PCIe or IO anomalies detected." | tee -a "$LOG_DIR/error_check_summary.txt"
fi

echo "=========================================================================="
echo "Suite Execution Completed."
echo "Raw JSONs & Command Logs: $RAW_DIR"
echo "System Logs & Diags:      $LOG_DIR"
echo "Final Delivered Report:   $EXCEL_REPORT"
echo "=========================================================================="

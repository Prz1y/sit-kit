#!/bin/bash
# ============================================================================
# SNIA SSS PTS NVMe Performance Test Suite (Enterprise Grade) - FIXED VERSION
# ============================================================================
# 修复说明:
# 1. 修复了致命的 shebang 错误与 shell 语法格式错误。
# 2. 修复了 Pandas 在仅运行单项测试时由于空 DataFrame 导致的 KeyError 崩溃。
# 3. 严格区分顺序/随机负载：顺序负载强制使用单线程深队列(numjobs=1)，避免伪随机化覆盖。
# 4. 优化 FIO JSON P99.99 解析的向下兼容性，增加 --eta=never 防止并行刷屏。
# 5. WSAT 饱和时间默认提升至 8 小时，确保大容量企业盘真正进入稳态。
# ============================================================================

# ============================================================================
#[ 核心配置区 / Configuration Area ]
# ============================================================================

# 1. 被测设备列表 (TARGET_DEVS) - 支持多块硬盘并发
# [警告] 会执行底层格式化和全盘 TRIM，盘上所有数据将被永久销毁！
TARGET_DEVS=(/dev/nvme0n1)
SERVER_MODEL="Enterprise_SNIA_Report"

# 2. SNIA 稳态与预处理参数 (完全符合企业级标准)
SNIA_WIPC_LOOPS=2           # WIPC (工作负载无关预热): 128k 顺序写，写满全盘 2 遍容量
WSAT_RUNTIME=28800          # WSAT (写入饱和测试): 修改为 8 小时 (28800秒)，强制大容量企业盘进入稳态

# 3. 核心机制：稳态寻优与超时防卡死 (Steady State & Timeout)
SNIA_SS_LIMIT=20            # 稳态波动阈值: 连续波动的极差 <= 20%
SNIA_SS_DUR=300             # 稳态评估窗口: 5 分钟 (300秒)
MATRIX_SS_TIMEOUT=1800      # 矩阵单项超时时间: 30分钟 (1800秒)

# 4. OIO (Outstanding IO) 扫描列表 - 深度队列探测
TEST_OIO_LIST="1 4 16 64 128 256"

# 5. 测试大项开关 (yes / no)
RUN_WSAT=yes         # 写入饱和度与掉速曲线长测 (评估长期稳定性)
RUN_IOPS=yes         # 标准 4k-128k 随机 IOPS 矩阵测试
RUN_THROUGHPUT=yes   # 标准 128k/1024k 顺序吞吐量测试
RUN_LATENCY=yes      # QD=1 极致单线程时延测试

# ============================================================================
#[ 前置依赖与安全检查 / Pre-flight Checks ]
# ============================================================================
echo "=========================================================================="
echo "[INFO] Commencing Pre-flight Checks for Enterprise NVMe SSDs..."
echo "=========================================================================="

if [ "$EUID" -ne 0 ]; then 
    echo "[ERROR] Root privileges are required to run this suite! Exiting."
    exit 1
fi

# 检查系统底层依赖
for tool in fio nvme python3 blkdiscard; do
    if ! command -v $tool >/dev/null 2>&1; then 
        echo "[ERROR] Missing required dependency: $tool. Please install it first."
        exit 1
    fi
done

# 检查 Python 数据分析依赖库，若缺失则自动安装
if ! python3 -c "import pandas, openpyxl" >/dev/null 2>&1; then
    echo "[WARNING] pandas or openpyxl missing. Attempting to install via pip..."
    pip3 install pandas openpyxl || { echo "[ERROR] Pip install failed. Please manually install pandas and openpyxl."; exit 1; }
fi

# 创建测试目录与日志归档区
BASE_DIR="$(pwd)/SNIA_ENTERPRISE_$(date +%Y%m%d_%H%M%S)/"
RAW_DIR="${BASE_DIR}raw_data/"
LOG_DIR="${BASE_DIR}logs/"
mkdir -p "$RAW_DIR" "$LOG_DIR"

echo "[INFO] Test workspace initialized at: $BASE_DIR"

# ==================== [ Python SNIA 引擎注入 ] ====================
PYTHON_ENGINE="${BASE_DIR}snia_fio_engine.py"

cat << 'EOF' > "$PYTHON_ENGINE"
import os, sys, json, time, subprocess, argparse, datetime, glob
from concurrent.futures import ThreadPoolExecutor
import pandas as pd

# --- SNIA 测试矩阵定义 ---
IOPS_BS_LIST    =['4k', '8k', '16k', '32k', '64k', '128k']
MIX_READ_LIST   =[100, 95, 65, 50, 35, 5, 0]  # 混合读写比例
TPUT_BS_LIST    = ['128k', '1024k']
LAT_BS_LIST     =['4k', '8k']

def log_print(msg):
    """ 纯英文标准日志时间戳打印 """
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")

def run_cmd(cmd, log_file=None):
    """ 执行 Shell 命令并记录日志 """
    try:
        res = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if log_file:
            with open(log_file, 'w') as f:
                f.write(f"COMMAND: {cmd}\n\n{res.stdout}")
        return res.returncode == 0
    except Exception as e:
        log_print(f"[ERROR] Command execution failed: {e}")
        return False

def snia_purge_enterprise(dev):
    """ 
    企业级盘三重擦除兜底方案 (FOB 初始化)
    1. nvme format -s 1 (Secure Erase / Cryptographic) - 企业首选
    2. nvme format -s 0 (Standard Format) - 降级
    3. blkdiscard (Full Drive TRIM) - 极致兜底
    """
    log_print(f"[SNIA FOB] Executing Fresh-Out-of-Box (FOB) initialization for {dev}...")
    
    if run_cmd(f"nvme format {dev} -s 1"):
        log_print(f"[SNIA FOB] {dev} Format -s 1 (Secure Erase) SUCCESS.")
        time.sleep(5)
        return True
        
    log_print(f"[SNIA FOB] {dev} -s 1 failed. Attempting -s 0 (Standard Format)...")
    if run_cmd(f"nvme format {dev} -s 0"):
        log_print(f"[SNIA FOB] {dev} Format -s 0 SUCCESS.")
        time.sleep(5)
        return True
        
    log_print(f"[SNIA FOB] {dev} NVMe format failed. Falling back to blkdiscard (Full TRIM)...")
    if run_cmd(f"blkdiscard -f {dev}"):
        log_print(f"[SNIA FOB] {dev} blkdiscard SUCCESS.")
        time.sleep(5)
        return True
        
    log_print(f"[CRITICAL] All erase methods failed for {dev}. Steady state validity may be compromised!")
    sys.exit(1)

def get_nj_qd(oio, is_seq=False):
    """ 
    智能拆解 OIO，严格保障顺序负载必须是单线程 (numjobs=1) 深队列，
    防止多线程并发时打乱 LBA 变成伪随机导致测试结果严重失真。
    """
    oio = int(oio)
    if is_seq:
        return 1, oio  # 顺序负载强制单线程深队列
    if oio == 1: return 1, 1
    elif oio <= 4: return oio, 1
    else: return 4, max(1, oio // 4)

def build_fio_cmd(task_name, dev, rw, bs, oio, args, 
                  is_wipc=False, is_wsat=False, rwmixread=None, ss_metric=None):
    """ 构建 FIO 执行命令 """
    # 判定当前是否为大块顺序负载
    is_seq = ('128k' in bs or '1024k' in bs) and ('rand' not in rw)
    nj, qd = get_nj_qd(oio, is_seq=is_seq)
    
    dev_name = os.path.basename(dev)
    json_out = os.path.join(args.raw_dir, f"{task_name}_{dev_name}.json")
    
    # 加入 --eta=never 防止并发时 FIO 在控制台刷屏严重降低性能
    cmd = (f"fio --name={task_name} --filename={dev} --rw={rw} --bs={bs} "
           f"--iodepth={qd} --numjobs={nj} --direct=1 --group_reporting --eta=never "
           f"--output-format=json --output={json_out}")
    
    if rwmixread is not None:
        cmd += f" --rwmixread={rwmixread}"
        
    if is_wipc:
        # SNIA WIPC阶段：直接按容量比例写满全盘 2 遍
        cmd += f" --loops={args.wipc_loops} --size=100%"
    elif is_wsat:
        # SNIA WSAT阶段：长时写入并记录时间序列以绘制掉速曲线
        log_prefix = os.path.join(args.raw_dir, f"wsat_{dev_name}")
        cmd += (f" --runtime={args.wsat_runtime} --time_based "
                f"--write_iops_log={log_prefix} --log_avg_msec=60000")
    else:
        # SNIA WDPC 及矩阵测量阶段：配合超时上限的稳态探测
        cmd += f" --runtime={args.matrix_ss_timeout} --time_based --ramp_time=30 "
        if ss_metric:
            cmd += f" --ss={ss_metric}:{args.ss_limit}% --ss_dur={args.ss_dur} --ss_ramp=60"
            
    return cmd, json_out

def run_fio_task(task_args):
    """ 单盘测试执行器 """
    task_name, dev, rw, bs, oio, args, is_wipc, is_wsat, rwmixread, ss_metric = task_args
    dev_name = os.path.basename(dev)
    cmd, json_out = build_fio_cmd(task_name, dev, rw, bs, oio, args, is_wipc, is_wsat, rwmixread, ss_metric)
    log_out = json_out.replace('.json', '.log')

    run_cmd(cmd, log_out)
    return json_out, dev_name

def execute_parallel(devs, task_name, rw, bs, oio, args, 
                     is_wipc=False, is_wsat=False, rwmixread=None, ss_metric='iops'):
    """ 多盘并行测试派发器 """
    tasks =[(f"{task_name}_OIO{oio}", d, rw, bs, oio, args, is_wipc, is_wsat, rwmixread, ss_metric) for d in devs]
    results =[]
    with ThreadPoolExecutor(max_workers=len(devs)) as pool:
        for res in pool.map(run_fio_task, tasks):
            results.append(res)
    return results

def parse_fio_json(json_file):
    """ 提取 FIO 输出 JSON 的核心性能数据，并增加向下兼容 """
    if not os.path.exists(json_file): return None
    try:
        with open(json_file, 'r') as f:
            d = json.load(f)['jobs'][0]
        
        ri, wi = d['read']['iops'], d['write']['iops']
        rb, wb = d['read']['bw_bytes']/(1024**2), d['write']['bw_bytes']/(1024**2)
        
        rlat = d['read'].get('clat_ns', {}).get('mean', 0) / 1000.0
        wlat = d['write'].get('clat_ns', {}).get('mean', 0) / 1000.0
        
        # 兼容不同版本 FIO P99.99 字段名 (99.99 vs 99.990000)
        r_pct = d['read'].get('clat_ns', {}).get('percentile', {})
        w_pct = d['write'].get('clat_ns', {}).get('percentile', {})
        rp99 = next((v for k, v in r_pct.items() if k.startswith('99.99')), 0) / 1000.0
        wp99 = next((v for k, v in w_pct.items() if k.startswith('99.99')), 0) / 1000.0

        return {
            'total_iops': round(ri + wi, 2),
            'read_iops': round(ri, 2), 'write_iops': round(wi, 2),
            'total_mbps': round(rb + wb, 2),
            'read_lat_us': round(rlat, 2), 'write_lat_us': round(wlat, 2),
            'read_99.99_us': round(rp99, 2), 'write_99.99_us': round(wp99, 2)
        }
    except: return None

def build_excel_reports(raw_results, wsat_dir, args):
    """ 利用 Pandas 聚合生成标准企业级格式 Excel 透视表 """
    log_print("[INFO] Compiling standardized Excel Pivot Table report...")
    df = pd.DataFrame(raw_results)
    
    with pd.ExcelWriter(args.out_excel, engine='openpyxl') as writer:
        
        # 防止因未运行某项测试导致 DataFrame 无对应列引发 KeyError 崩溃
        if not df.empty and 'test_type' in df.columns:
            
            # 1. Random IOPS Matrix
            if not df[df['test_type'] == 'IOPS'].empty:
                iops_df = df[df['test_type'] == 'IOPS']
                pivot = iops_df.pivot_table(index='bs', columns=['mix', 'oio'], values='total_iops', aggfunc='mean')
                pivot.to_excel(writer, sheet_name='Random_IOPS_Matrix')

            # 2. Sequential Throughput
            if not df[df['test_type'] == 'TPUT'].empty:
                tput_df = df[df['test_type'] == 'TPUT']
                pivot = tput_df.pivot_table(index='bs', columns=['mix', 'oio'], values='total_mbps', aggfunc='mean')
                pivot.to_excel(writer, sheet_name='Seq_Throughput_Matrix')

            # 3. Latency Check
            if not df[df['test_type'] == 'LATENCY'].empty:
                lat_df = df[df['test_type'] == 'LATENCY']
                pivot_r = lat_df.pivot_table(index='bs', columns='mix', values='read_lat_us', aggfunc='mean')
                pivot_w = lat_df.pivot_table(index='bs', columns='mix', values='write_lat_us', aggfunc='mean')
                pivot_r.to_excel(writer, sheet_name='Latency_OIO1', startrow=0)
                pivot_w.to_excel(writer, sheet_name='Latency_OIO1', startrow=len(pivot_r)+3)

        # 4. WSAT Degradation Time-Series
        wsat_logs = glob.glob(os.path.join(wsat_dir, "wsat_*_iops.*.log"))
        if wsat_logs:
            log_print("[INFO] Processing WSAT logs for time-series degradation analysis...")
            wsat_data =[]
            for log in wsat_logs:
                try:
                    dev_id = os.path.basename(log).split('_')[1]
                    tmp_df = pd.read_csv(log, header=None, names=['time_ms', 'iops', 'dir', 'bs'])
                    tmp_df['minute'] = (tmp_df['time_ms'] / 60000).astype(int)
                    tmp_df['drive'] = dev_id
                    wsat_data.append(tmp_df[['minute', 'iops', 'drive']])
                except: pass
            if wsat_data:
                wsat_df = pd.concat(wsat_data)
                wsat_pivot = wsat_df.pivot_table(index='minute', columns='drive', values='iops')
                wsat_pivot.to_excel(writer, sheet_name='WSAT_Degradation_1min')

        # 5. Raw Flat Data
        if not df.empty:
            df.to_excel(writer, sheet_name='Raw_Data', index=False)

    log_print(f"[SUCCESS] Enterprise Report generated at: {args.out_excel}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--devs', required=True)
    parser.add_argument('--oio_list', required=True)
    parser.add_argument('--raw_dir', required=True)
    parser.add_argument('--out_excel', required=True)
    parser.add_argument('--wipc_loops', type=int, required=True)
    parser.add_argument('--ss_limit', type=int, required=True)
    parser.add_argument('--ss_dur', type=int, required=True)
    parser.add_argument('--matrix_ss_timeout', type=int, required=True)
    parser.add_argument('--wsat_runtime', type=int, required=True)
    
    parser.add_argument('--run_wsat', required=True)
    parser.add_argument('--run_iops', required=True)
    parser.add_argument('--run_tput', required=True)
    parser.add_argument('--run_lat', required=True)
    args = parser.parse_args()

    devs = args.devs.split()
    oio_list =[int(x) for x in args.oio_list.split()]
    results =[]

    # ========================================================================
    # 阶段 1: 随机工作负载预热 (FOB Purge -> WIPC -> WSAT)
    # ========================================================================
    if args.run_wsat == 'yes' or args.run_iops == 'yes' or args.run_lat == 'yes':
        for d in devs: snia_purge_enterprise(d)
        
        log_print("\n[Phase 1.1] WIPC: 128k Sequential Preconditioning (filling drive 2x capacity)...")
        execute_parallel(devs, "WIPC_Seq", "write", "128k", 128, args, is_wipc=True)

        if args.run_wsat == 'yes':
            log_print(f"\n[Phase 1.2] WSAT: 4k Random Write Saturation (Forcing Steady State for {args.wsat_runtime}s)...")
            execute_parallel(devs, "WSAT_4k", "randwrite", "4k", 128, args, is_wsat=True)

    # ========================================================================
    # 阶段 2: WDPC 与随机 IOPS 稳态矩阵测量
    # ========================================================================
    if args.run_iops == 'yes':
        log_print("\n[Phase 2] WDPC & Measurement: Random IOPS Matrix (Auto Steady-State Detection)...")
        for bs in IOPS_BS_LIST:
            for mix in MIX_READ_LIST:
                for oio in oio_list:
                    task_name = f"IOPS_{bs}_R{mix}"
                    log_print(f" -> Testing: {task_name} | OIO={oio}")
                    j_files = execute_parallel(devs, task_name, "randrw", bs, oio, args, rwmixread=mix, ss_metric='iops')
                    
                    for jf, dname in j_files:
                        r = parse_fio_json(jf)
                        if r:
                            r.update({'test_type': 'IOPS', 'drive': dname, 'bs': bs, 'mix': mix, 'oio': oio})
                            results.append(r)

    # ========================================================================
    # 阶段 3: 极致 OIO=1 时延极限测量
    # ========================================================================
    if args.run_lat == 'yes':
        log_print("\n[Phase 3] Measurement: OIO=1 Extreme Latency Test...")
        for bs in LAT_BS_LIST:
            for mix in [100, 65, 0]:
                task_name = f"LAT_{bs}_R{mix}"
                log_print(f" -> Testing: {task_name} | OIO=1")
                j_files = execute_parallel(devs, task_name, "randrw", bs, 1, args, rwmixread=mix, ss_metric='iops')
                for jf, dname in j_files:
                    r = parse_fio_json(jf)
                    if r:
                        r.update({'test_type': 'LATENCY', 'drive': dname, 'bs': bs, 'mix': mix, 'oio': 1})
                        results.append(r)

    # ========================================================================
    # 阶段 4: 顺序吞吐量测试 (必须重新 FOB 擦除，消除随机碎片影响)
    # ========================================================================
    if args.run_tput == 'yes':
        log_print("\n[Phase 4.1] TPUT Prep: Re-executing FOB and WIPC for Sequential Workloads...")
        for d in devs: snia_purge_enterprise(d)
        execute_parallel(devs, "WIPC_Seq_2", "write", "128k", 128, args, is_wipc=True)

        log_print("\n[Phase 4.2] Measurement: Sequential Throughput Matrix...")
        for bs in TPUT_BS_LIST:
            for mix in[100, 0]:
                rw_mode = "read" if mix == 100 else "write"
                for oio in oio_list:
                    task_name = f"TPUT_{bs}_{rw_mode}"
                    log_print(f" -> Testing: {task_name} | OIO={oio}")
                    j_files = execute_parallel(devs, task_name, rw_mode, bs, oio, args, ss_metric='bw')
                    
                    for jf, dname in j_files:
                        r = parse_fio_json(jf)
                        if r:
                            r.update({'test_type': 'TPUT', 'drive': dname, 'bs': bs, 'mix': mix, 'oio': oio})
                            results.append(r)

    if not results and args.run_wsat == 'no':
        log_print("[ERROR] No valid data points collected. Check FIO logs.")
        sys.exit(1)

    build_excel_reports(results, args.raw_dir, args)

if __name__ == "__main__":
    main()
EOF

# ====================[ 任务派发与执行引擎启动 ] ====================
EXCEL_REPORT="${BASE_DIR}Enterprise_SNIA_Report_${SERVER_MODEL}.xlsx"

echo "[INFO] Handing off execution to Python Engine..."
sleep 3

python3 "$PYTHON_ENGINE" \
    --devs "${TARGET_DEVS[*]}" \
    --oio_list "$TEST_OIO_LIST" \
    --raw_dir "$RAW_DIR" \
    --out_excel "$EXCEL_REPORT" \
    --wipc_loops "$SNIA_WIPC_LOOPS" \
    --ss_limit "$SNIA_SS_LIMIT" \
    --ss_dur "$SNIA_SS_DUR" \
    --matrix_ss_timeout "$MATRIX_SS_TIMEOUT" \
    --wsat_runtime "$WSAT_RUNTIME" \
    --run_wsat "$RUN_WSAT" \
    --run_iops "$RUN_IOPS" \
    --run_tput "$RUN_THROUGHPUT" \
    --run_lat "$RUN_LATENCY"

# ====================[ 测试后硬件完整性与异常诊断 ] ====================
echo "=========================================================================="
echo "[INFO] Execution complete. Auditing system hardware logs (AER / IO Timeout)..."
dmesg -T > "$LOG_DIR/post_dmesg.log" 2>/dev/null || true
err_count=$(grep -iE 'pcie bus error|aer|bad tlp|bad dllp|nvme.*timeout|io error' "$LOG_DIR/post_dmesg.log" | wc -l)

if [ "$err_count" -gt 0 ]; then
    echo "[WARNING] Detected $err_count hardware-level errors during stress testing!"
    echo "          Please review kernel logs at: $LOG_DIR/post_dmesg.log"
else
    echo "[PASS] No hardware-level IO or PCIe errors detected under extreme load."
fi

echo "=========================================================================="
echo "SNIA Enterprise Performance Suite Validation Finished."
echo "Full Report Output: $EXCEL_REPORT"
echo "=========================================================================="

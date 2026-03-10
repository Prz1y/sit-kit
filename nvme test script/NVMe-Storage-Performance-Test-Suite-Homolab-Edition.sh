#!/bin/bash
# ============================================================================
# NVMe Storage Performance Test Suite - Homolab Edition
# ============================================================================
# Dependencies / 依赖项:
# sudo yum/apt-get install -y fio nvme-cli pciutils python3 python3-pip numactl ipmitool libaio-devel
# pip3 install pandas openpyxl
# ============================================================================

# ============================================================================
#[ 核心配置区 / Core Configuration ]
# ============================================================================

TEST_MODE="single"
TARGET_DEVS=("/dev/nvme1n1")
SERVER_MODEL="Server"

# Fixed runtimes / 固定测试时长（取消动态计算）
RUNTIME=300
MIX_RUNTIME=1200
QOS_RUNTIME=3600
RAMP_TIME=30

DO_SEQ_PRECON="yes"
SEQ_PRE_LOOPS=2
DO_RAND_PRECON="yes"
RAND_PRE_LOOPS=2           # Minimum random precon loops / 随机预处理最少循环次数
RAND_PRE_MAX_LOOPS=5       # Maximum random precon loops / 随机预处理最多循环次数（安全上限）
ENABLE_STEADY_STATE_CHECK="yes"   # Enable steady-state detection; "no" = fixed 3-pass fill / 启用稳态检测；"no"=固定3次填充
STEADY_STATE_THRESHOLD=0.10  # CV threshold for steady-state / 稳态判定阈值（变异系数）
STEADY_STATE_WINDOW=5      # Consecutive stable samples required / 判定稳态所需连续样本数

RUN_SEQ_READ="yes"
RUN_SEQ_WRITE="yes"
RUN_RAND_READ="yes"
RUN_RAND_WRITE="yes"
RUN_MIXED_RW="yes"
RUN_QOS_TEST="yes"

TEST_BS_LIST="4k 8k 16k 32k 64k 128k"
RESUME_FROM=""

ENABLE_NUMA_BIND="yes"
NUMA_BIND_METHOD="fio"
NUMA_FALLBACK_NODE="0"

# Maximum Outstanding I/O cap / 最大未完成IO上限
MAX_OUTSTANDING_IO=1024

# ============================================================================
#[ 环境与安全前置检查 / Environment and Safety Pre-flight Checks ]
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

python3 -c "import pandas; import openpyxl" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "[ERROR] Required Python packages 'pandas' and/or 'openpyxl' are not installed."
    echo "[ERROR] Install with: pip3 install pandas openpyxl"
    exit 1
fi

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

dmesg -T > "$LOG_DIR/pre_dmesg.log" 2>/dev/null || true
lspci -vvv > "$LOG_DIR/pre_lspci.log" 2>/dev/null || true
nvme smart-log "${TARGET_DEVS[0]}" > "$LOG_DIR/pre_smart.log" 2>/dev/null || true

# ====================[ Python 测试引擎注入 / Python Test Engine Injection ] ====================
PYTHON_ENGINE="${BASE_DIR}/nvme_fio_engine.py"

cat << 'EOF' > "$PYTHON_ENGINE"
import os, sys, json, time, subprocess, argparse, datetime, statistics
from concurrent.futures import ThreadPoolExecutor
import pandas as pd

# ----------------------------------------------------------------------------
# 参数矩阵定义 / Parameter Matrix Definition
# ----------------------------------------------------------------------------
NUMJOBS_LIST = [1, 2, 4, 8, 16, 32]
IODEPTH_LIST = [1, 2, 4, 8, 16, 32, 64, 128]
QDS_STRICT   = [1, 2, 4, 8, 16, 32, 64, 128]   # Must match IODEPTH_LIST / 必须与 IODEPTH_LIST 保持一致
MIX_RATIO_LIST = [10, 20, 30, 40, 50, 60, 70, 80, 90]

SEQ_COMBOS = [('128k', 1, 32)]
RAND_COMBOS = [('4k', 1, 32)]

def log_print(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")

def get_drive_info(dev):
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
    # Attempt 1: Secure Erase (User Data Erase) / 尝试1：安全擦除（用户数据擦除）
    for attempt in range(1, 4):
        log_print(f"[INFO] Formatting {dev} with -s 1 (Attempt {attempt}/3)...")
        if run_cmd(f"nvme format {dev} -s 1"):
            log_print(f"[INFO] Format with -s 1 succeeded on {dev}.")
            time.sleep(10)
            return True
        time.sleep(5)
    log_print(f"[WARN] nvme format {dev} -s 1 failed after 3 attempts. Falling back to -s 0...")

    # Attempt 2: Format without secure erase / 尝试2：不执行安全擦除的格式化
    for attempt in range(1, 4):
        log_print(f"[INFO] Formatting {dev} with -s 0 (Attempt {attempt}/3)...")
        if run_cmd(f"nvme format {dev} -s 0"):
            log_print(f"[INFO] Format with -s 0 succeeded on {dev}.")
            time.sleep(10)
            return True
        time.sleep(5)
    log_print(f"[WARN] nvme format {dev} -s 0 failed after 3 attempts. Falling back to -n 1 -s 0...")

    # Attempt 3: Explicit namespace format / 尝试3：指定命名空间格式化
    for attempt in range(1, 4):
        log_print(f"[INFO] Formatting {dev} with -n 1 -s 0 (Attempt {attempt}/3)...")
        if run_cmd(f"nvme format {dev} -n 1 -s 0"):
            log_print(f"[INFO] Format with -n 1 -s 0 succeeded on {dev}.")
            time.sleep(10)
            return True
        time.sleep(5)

    log_print(f"[CRITICAL] All format attempts failed for {dev}. Aborting.")
    sys.exit(1)

def build_fio_cmd(job_name, dev, rw, bs, iodepth, numjobs, runtime, json_out, args, loops=0, rwmixread=None):
    """Build the fio command string.
    构建 fio 命令字符串。
    For loops>0 (preconditioning), uses loop/size mode; otherwise uses fixed ramp+runtime.
    loops>0 时（预处理阶段）使用循环/大小模式；否则使用固定 ramp_time 和 runtime。
    """
    cmd = (f"fio --name={job_name} --filename={dev} --rw={rw} --bs={bs} "
           f"--iodepth={iodepth} --numjobs={numjobs} --direct=1 --ioengine=libaio "
           f"--thread --end_fsync=0 --buffer_compress_percentage=0 --invalidate=1 "
           f"--norandommap --randrepeat=0 --refill_buffers --exitall "
           f"--percentile_list=50:99:99.9:99.99 "
           f"--group_reporting --output-format=json --output={json_out}")

    if bs == "512B":
        cmd += " --random_generator=tausworthe64"

    if loops > 0:
        # Preconditioning mode: full device sweep / 预处理模式：全盘扫描
        cmd += f" --loops={loops} --size=100%"
    else:
        # Fixed ramp and runtime — no dynamic calculation / 固定 ramp 和 runtime，不再动态计算
        cmd += f" --ramp_time={args.ramp_time} --runtime={runtime} --time_based"

    if rwmixread is not None:
        cmd += f" --rwmixread={rwmixread}"

    if args.enable_numa == 'yes':
        node = get_numa_node(dev, args.fallback_node)
        if args.numa_method == 'fio':
            cmd += f" --numa_cpu_nodes={node}"
        elif args.numa_method == 'numactl':
            cmd = f"numactl -N {node} -m {node} {cmd}"

    return cmd

def run_fio_task(task_args):
    job_name, dev, rw, bs, iodepth, numjobs, runtime, raw_dir, args, loops, rwmixread = task_args
    dev_name = os.path.basename(dev)
    json_out = os.path.join(raw_dir, f"{job_name}_{dev_name}_{rw}_{bs}_{numjobs}j_{iodepth}qd.json")
    log_out = json_out.replace('.json', '.log')

    if args.resume and os.path.exists(json_out) and os.path.getsize(json_out) > 0:
        try:
            with open(json_out, 'r') as f:
                data = json.load(f)
            if 'jobs' in data and len(data['jobs']) > 0:
                log_print(f"[RESUME] Skipping valid existing task: {os.path.basename(json_out)}")
                return (json_out, dev_name)
            else:
                log_print(f"[RESUME] Existing file invalid (no jobs data), re-running: {os.path.basename(json_out)}")
        except (json.JSONDecodeError, KeyError, IOError):
            log_print(f"[RESUME] Existing file corrupted, re-running: {os.path.basename(json_out)}")

    cmd = build_fio_cmd(job_name, dev, rw, bs, iodepth, numjobs, runtime, json_out, args, loops, rwmixread)
    run_cmd(cmd, log_out)
    return (json_out, dev_name)

def execute_synchronized_parallel(devs, job_name, rw, bs, iodepth, numjobs, runtime, raw_dir, args, loops=0, rwmixread=None):
    tasks = [(job_name, d, rw, bs, iodepth, numjobs, runtime, raw_dir, args, loops, rwmixread) for d in devs]
    json_results = []
    with ThreadPoolExecutor(max_workers=len(devs)) as executor:
        for result in executor.map(run_fio_task, tasks):
            json_results.append(result)
    return json_results

def parse_fio_json(json_file, is_mixed=False):
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

def parse_fio_json_qos(json_file, rw_pattern):
    """Extract QoS metrics including latency percentiles from a fio JSON output.
    从 fio JSON 输出中提取 QoS 指标，包括延迟百分位数。
    Returns a dict with iops, bw, p50, p99, p999, p9999, or None on failure.
    成功时返回包含 iops、bw、p50、p99、p999、p9999 的字典，失败时返回 None。
    """
    if not os.path.exists(json_file):
        return None
    try:
        with open(json_file, 'r') as f:
            data = json.load(f)
        job = data['jobs'][0]

        is_read = 'read' in rw_pattern
        tgt = job['read'] if is_read else job['write']

        iops = tgt['iops']
        bw_mb = tgt['bw_bytes'] / (1024 * 1024)

        clat_dict = tgt.get('clat_ns', {}).get('percentile', {})
        p50   = clat_dict.get('50.000000', 0) / 1000.0
        p99   = clat_dict.get('99.000000', 0) / 1000.0
        p999  = clat_dict.get('99.900000', 0) / 1000.0
        p9999 = clat_dict.get('99.990000', 0) / 1000.0

        return {
            "iops": round(iops, 2),
            "bw_mb": round(bw_mb, 2),
            "p50_us": round(p50, 2),
            "p99_us": round(p99, 2),
            "p99.9_us": round(p999, 2),
            "p99.99_us": round(p9999, 2),
        }
    except Exception:
        return None

def parse_probe_iops(json_file):
    """Extract IOPS from a short probe fio JSON output.
    从短时探测 fio JSON 输出中提取 IOPS 值。
    Returns IOPS as float, or 0.0 on failure / 返回浮点 IOPS，失败时返回 0.0。
    """
    if not os.path.exists(json_file):
        return 0.0
    try:
        with open(json_file, 'r') as f:
            data = json.load(f)
        job = data['jobs'][0]
        # Probe is always 4k randwrite; pick write IOPS / 探测始终是 4k randwrite，取写 IOPS
        return float(job['write']['iops'])
    except Exception:
        return 0.0

def check_steady_state(iops_history, threshold, window):
    """Check whether the drive has entered steady state using three criteria:
    使用三重条件判断磁盘是否进入稳态：
    1. CV (Coefficient of Variation) < threshold — measures dispersion
       变异系数 < 阈值 — 衡量离散度
    2. Range Ratio = (max - min) / mean < 0.20 — SNIA PTS core metric
       极差比 < 20% — SNIA PTS 核心指标
    3. Normalized Slope < 0.02 — detects monotonic trends
       归一化斜率 < 2% — 检测单调趋势

    Args:
        iops_history: list of IOPS samples from each probe loop
        threshold: CV threshold below which steady state is declared
        window: number of most recent samples to consider

    Returns:
        (is_stable, cv, range_ratio, slope_pct) tuple
        返回 (is_stable, cv, range_ratio, slope_pct) 元组
    """
    if len(iops_history) < window:
        return False, None, None, None
    recent = iops_history[-window:]
    if len(recent) < 2:
        return False, None, None, None
    mean_val = statistics.mean(recent)
    if mean_val == 0:
        return False, None, None, None

    # Criterion 1: CV (dispersion) / 条件1：变异系数（离散度）
    stdev_val = statistics.stdev(recent)
    cv = stdev_val / mean_val

    # Criterion 2: Range Ratio (SNIA-style) / 条件2：极差比（SNIA 风格）
    range_ratio = (max(recent) - min(recent)) / mean_val

    # Criterion 3: Normalized linear regression slope / 条件3：归一化线性回归斜率
    n = len(recent)
    x_mean = (n - 1) / 2.0
    numerator = sum((i - x_mean) * (recent[i] - mean_val) for i in range(n))
    denominator = sum((i - x_mean) ** 2 for i in range(n))
    slope = numerator / denominator if denominator != 0 else 0.0
    slope_pct = abs(slope / mean_val) if mean_val != 0 else 0.0

    is_stable = (cv < threshold and range_ratio < 0.20 and slope_pct < 0.02)
    return is_stable, cv, range_ratio, slope_pct

def run_rand_precon_with_steady_state(devs, raw_dir, args):
    """Run random preconditioning loops with optional steady-state detection.
    执行带可选稳态检测的随机预处理循环。

    When steady_state_check is 'yes': runs at least rand_loops iterations, up to
    rand_pre_max_loops, stopping early when the triple criteria (CV, Range, Slope)
    are all satisfied.
    当 steady_state_check='yes' 时：最少执行 rand_loops 次，最多 rand_pre_max_loops 次，
    三重条件全部满足时提前停止。

    When steady_state_check is 'no': always performs exactly 3 fixed full-disk fill
    passes with no probe or stability check.
    当 steady_state_check='no' 时：固定执行3次全盘填充，不进行探测或稳态检测。
    """
    min_loops = args.rand_loops
    max_loops = args.rand_pre_max_loops
    threshold = args.steady_threshold
    window = args.steady_window
    check_enabled = args.steady_state_check == 'yes'

    iops_history = []
    precon_log = []  # Records per-loop info for Excel sheet / 记录每轮信息用于 Excel 稳态页

    # When steady-state check is disabled: fixed 3-pass fill, no probe / 禁用稳态检测时：固定3次全盘填充，无探测
    if not check_enabled:
        fixed_loops = 3
        log_print(f"[PRECON] Steady-state check DISABLED. Running fixed {fixed_loops}-pass random preconditioning.")
        for loop_idx in range(1, fixed_loops + 1):
            log_print(f"[PRECON] Starting loop {loop_idx}/{fixed_loops} — full 4k randwrite pass (no steady-state check)...")
            execute_synchronized_parallel(devs, f"pre_rand_loop{loop_idx}", "randwrite", "4k",
                                          128, 4, 0, raw_dir, args, loops=1)
            log_print(f"[PRECON] Loop {loop_idx}/{fixed_loops} completed.")
            precon_log.append({
                "Loop#": loop_idx,
                "Probe_IOPS": "N/A",
                "Cumulative_CV": "N/A",
                "Range_Ratio": "N/A",
                "Slope_Pct": "N/A",
                "Status": "CHECK_DISABLED"
            })
        log_print(f"[PRECON] Fixed {fixed_loops}-pass preconditioning complete. Proceeding to tests.")
        return precon_log

    for loop_idx in range(1, max_loops + 1):
        # Full 4k randwrite preconditioning pass / 完整 4k randwrite 预处理扫描
        log_print(f"[PRECON] Starting loop {loop_idx}/{max_loops} — full 4k randwrite pass...")
        execute_synchronized_parallel(devs, f"pre_rand_loop{loop_idx}", "randwrite", "4k",
                                      128, 4, 0, raw_dir, args, loops=1)

        # Short probe to sample current IOPS / 短时探测采样当前 IOPS
        probe_jsons = []
        for dev in devs:
            dev_name = os.path.basename(dev)
            probe_json = os.path.join(raw_dir, f"probe_rand_loop{loop_idx}_{dev_name}.json")
            probe_log = probe_json.replace('.json', '.log')
            # 60s probe: 4k randwrite, iodepth=32, numjobs=4 / 60秒探测：4k randwrite，iodepth=32，numjobs=4
            cmd = (f"fio --name=probe --filename={dev} --rw=randwrite --bs=4k "
                   f"--iodepth=32 --numjobs=4 --direct=1 --ioengine=libaio "
                   f"--thread --norandommap --randrepeat=0 --refill_buffers "
                   f"--ramp_time=10 --runtime=60 --time_based "
                   f"--group_reporting --output-format=json --output={probe_json}")
            if args.enable_numa == 'yes':
                node = get_numa_node(dev, args.fallback_node)
                if args.numa_method == 'fio':
                    cmd += f" --numa_cpu_nodes={node}"
                elif args.numa_method == 'numactl':
                    cmd = f"numactl -N {node} -m {node} {cmd}"
            run_cmd(cmd, probe_log)
            probe_jsons.append(probe_json)

        # Average probe IOPS across all drives / 对所有磁盘的探测 IOPS 取平均
        probe_iops_vals = [parse_probe_iops(pj) for pj in probe_jsons]
        avg_probe_iops = sum(probe_iops_vals) / len(probe_iops_vals) if probe_iops_vals else 0.0
        iops_history.append(avg_probe_iops)

        log_print(f"[PRECON] Loop {loop_idx}/{max_loops} completed. "
                  f"Probe IOPS={avg_probe_iops:.0f}. History={[round(v, 0) for v in iops_history]}")

        # Determine stability status for logging / 判断稳定状态用于记录
        is_stable, cv, range_ratio, slope_pct = check_steady_state(iops_history, threshold, window)
        cv_pct = f"{cv * 100:.2f}%" if cv is not None else "N/A"
        range_pct = f"{range_ratio * 100:.2f}%" if range_ratio is not None else "N/A"
        slope_pct_str = f"{slope_pct * 100:.2f}%" if slope_pct is not None else "N/A"
        threshold_pct = f"{threshold * 100:.2f}%"
        status = "STABLE" if is_stable else "UNSTABLE"
        precon_log.append({
            "Loop#": loop_idx,
            "Probe_IOPS": round(avg_probe_iops, 0),
            "Cumulative_CV": cv_pct,
            "Range_Ratio": range_pct,
            "Slope_Pct": slope_pct_str,
            "Status": status
        })

        if loop_idx >= min_loops:
            if is_stable:
                log_print(f"[PRECON] Steady-state REACHED at loop {loop_idx}. "
                          f"CV={cv_pct}, Range={range_pct}, Slope={slope_pct_str} "
                          f"(threshold={threshold_pct}). Proceeding to tests.")
                break
            elif cv is not None:
                log_print(f"[PRECON] Steady-state check: CV={cv_pct}, Range={range_pct}, "
                          f"Slope={slope_pct_str} (threshold={threshold_pct}). "
                          f"NOT STABLE — continuing.")
            else:
                log_print(f"[PRECON] Steady-state check: insufficient history (need {window} samples). "
                          f"NOT STABLE — continuing.")

        if loop_idx == max_loops:
            _, final_cv, final_range, final_slope = check_steady_state(iops_history, threshold, window)
            final_cv_pct = f"{final_cv * 100:.2f}%" if final_cv is not None else "N/A"
            final_range_pct = f"{final_range * 100:.2f}%" if final_range is not None else "N/A"
            final_slope_pct = f"{final_slope * 100:.2f}%" if final_slope is not None else "N/A"
            log_print(f"[PRECON] WARNING: Max loops ({max_loops}) reached without steady state. "
                      f"CV={final_cv_pct}, Range={final_range_pct}, Slope={final_slope_pct}. Proceeding anyway.")

    return precon_log

def generate_excel(df_all, mixed_results, precon_log, args, devs, drive_infos, qos_results=None):
    log_print("[INFO] Compiling data into standard Excel report...")
    out_excel = args.out_excel
    bs_list = args.bs_list.split()

    with pd.ExcelWriter(out_excel, engine='openpyxl') as writer:

        if not df_all.empty:
            MATRIX_COLS = [f"{n}_{q}" for n in NUMJOBS_LIST for q in QDS_STRICT]

            sheet_mapping = {
                'seq_read': '顺序读测试', 'seq_write': '顺序写测试',
                'randread': '随机读测试', 'randwrite': '随机写测试'
            }

            if args.mode == 'single':
                # Single-drive mode: one sheet per pattern / 单盘模式：每个测试模式一个 Sheet
                target_dev = os.path.basename(devs[0])
                for ptn, sheet_name in sheet_mapping.items():
                    if ptn not in df_all['pattern'].values: continue

                    iops_dict = {bs: {c: "" for c in MATRIX_COLS} for bs in bs_list}
                    lat_rows = []
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
                    df_lat.to_excel(writer, sheet_name=sheet_name, startrow=lat_start_row + 1)

            else:
                # Multi-drive mode: one sheet per drive per pattern / 多盘模式：每块盘每个测试模式一个 Sheet
                all_drives = df_all['drive'].unique()
                for drive_name in all_drives:
                    for ptn, sheet_base_name in sheet_mapping.items():
                        drive_df = df_all[(df_all['pattern'] == ptn) & (df_all['drive'] == drive_name)]
                        if drive_df.empty: continue

                        # Truncate to 31-char Excel limit; append suffix on collision
                        # 截断至 Excel 31 字符限制；冲突时追加数字后缀
                        raw_sheet = f"{sheet_base_name}_{drive_name}"
                        base_truncated = raw_sheet[:31]
                        sheet_name = base_truncated
                        collision_idx = 1
                        while sheet_name in writer.sheets:
                            suffix = f"_{collision_idx}"
                            sheet_name = base_truncated[:31 - len(suffix)] + suffix
                            collision_idx += 1

                        iops_dict = {bs: {c: "" for c in MATRIX_COLS} for bs in bs_list}
                        lat_rows = []
                        for bs in bs_list:
                            lat_rows.extend([f"{bs}_min_lat", f"{bs}_avg_lat", f"{bs}_max_lat", f"{bs}_99.99th_lat"])
                        lat_dict = {r: {c: "" for c in MATRIX_COLS} for r in lat_rows}

                        for _, r in drive_df.iterrows():
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
                        df_lat.to_excel(writer, sheet_name=sheet_name, startrow=lat_start_row + 1)

        if mixed_results:
            pd.DataFrame(mixed_results).to_excel(writer, sheet_name='混合读写', index=False)

        # 保护性写入 Raw 数据页 / Write raw data sheet with guard
        if not df_all.empty:
            df_all.to_excel(writer, sheet_name="Raw_Matrix_Data", index=False)

        # 预处理稳态页 / Preconditioning Steady-State sheet
        # Columns: Loop#, Probe_IOPS, Cumulative_CV, Status (STABLE/UNSTABLE)
        # 列：循环编号、探测 IOPS、累计变异系数、状态（稳态/非稳态）
        if precon_log:
            df_precon = pd.DataFrame(precon_log, columns=["Loop#", "Probe_IOPS", "Cumulative_CV", "Range_Ratio", "Slope_Pct", "Status"])
            df_precon.to_excel(writer, sheet_name='预处理稳态', index=False)
        else:
            # Write empty placeholder if preconditioning was skipped / 若跳过预处理则写占位空表
            pd.DataFrame(columns=["Loop#", "Probe_IOPS", "Cumulative_CV", "Range_Ratio", "Slope_Pct", "Status"]).to_excel(
                writer, sheet_name='预处理稳态', index=False)

        # QoS 延迟测试页 / QoS Latency Test sheet
        if qos_results:
            pd.DataFrame(qos_results).to_excel(writer, sheet_name='QoS延迟测试', index=False)

    log_print(f"[SUCCESS] Report successfully generated: {out_excel}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--devs', required=True)
    parser.add_argument('--mode', required=True)
    parser.add_argument('--runtime', type=int, required=True)
    parser.add_argument('--mix_runtime', type=int, required=True)
    parser.add_argument('--qos_runtime', type=int, required=True)
    parser.add_argument('--ramp_time', type=int, required=True)
    parser.add_argument('--raw_dir', required=True)
    parser.add_argument('--out_excel', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--bs_list', required=True)
    parser.add_argument('--seq_pre', required=True)
    parser.add_argument('--seq_loops', type=int, required=True)
    parser.add_argument('--rand_pre', required=True)
    parser.add_argument('--rand_loops', type=int, required=True)
    parser.add_argument('--rand_pre_max_loops', type=int, required=True)
    parser.add_argument('--steady_state_check', required=True)
    parser.add_argument('--steady_threshold', type=float, required=True)
    parser.add_argument('--steady_window', type=int, required=True)
    parser.add_argument('--max_outstanding_io', type=int, required=True)
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

    # Input validation for new v2 parameters / 对新增 v2 参数进行合法性校验
    if args.steady_state_check not in ('yes', 'no'):
        print(f"[ERROR] --steady_state_check must be 'yes' or 'no', got '{args.steady_state_check}'.")
        sys.exit(1)
    if args.rand_pre_max_loops < args.rand_loops:
        print(f"[ERROR] --rand_pre_max_loops ({args.rand_pre_max_loops}) must be >= "
              f"--rand_loops ({args.rand_loops}).")
        sys.exit(1)
    if not (0.0 < args.steady_threshold < 1.0):
        print(f"[ERROR] --steady_threshold ({args.steady_threshold}) must be between 0.0 and 1.0.")
        sys.exit(1)
    if args.steady_window < 2:
        print(f"[ERROR] --steady_window ({args.steady_window}) must be >= 2 (required for stdev).")
        sys.exit(1)

    devs = args.devs.split()
    bs_list = args.bs_list.split()
    results = []
    mixed_results = []
    precon_log = []
    qos_results = []

    log_print("[INFO] Initiating drive preparation...")
    drive_infos = {}
    for d in devs:
        if not args.resume:
            format_drive(d)
        drive_infos[d] = get_drive_info(d)

    # Build filtered combo list — skip combos where numjobs*iodepth > MAX_OUTSTANDING_IO
    # 构建过滤后的测试组合列表 — 跳过 numjobs*iodepth > MAX_OUTSTANDING_IO 的组合
    # High OIO (Outstanding I/O) causes latency spikes and IOPS regression from queue saturation.
    # 过高的未完成 IO 数会导致延迟爆炸和 IOPS 回退，因此设置上限加以过滤。
    def build_combos(bs_list_local):
        combos = []
        for b in bs_list_local:
            for n in NUMJOBS_LIST:
                for q in IODEPTH_LIST:
                    oio = n * q
                    if oio > args.max_outstanding_io:
                        log_print(f"[SKIP] BS={b} NJ={n} QD={q} -> OIO={oio} exceeds limit "
                                  f"{args.max_outstanding_io}. Skipping.")
                        continue
                    combos.append((b, n, q))
        return combos

    if args.run_seq_read == 'yes' or args.run_seq_write == 'yes':
        if args.seq_pre == 'yes':
            log_print("\n[INFO] === Executing Sequential Preconditioning ===")
            execute_synchronized_parallel(devs, "pre_seq", "write", "128k", 128, 1, 0, args.raw_dir, args, loops=args.seq_loops)

        for rw, run_flag in [('read', args.run_seq_read), ('write', args.run_seq_write)]:
            if run_flag != 'yes': continue
            log_print(f"\n[INFO] === Matrix Testing: Sequential {rw} ===")

            if args.mode == 'multi':
                combos_to_run = [c for c in SEQ_COMBOS if c[0] in bs_list]
            else:
                combos_to_run = build_combos(bs_list)

            for i, (bs, nj, qd) in enumerate(combos_to_run, 1):
                log_print(f"  -> Progress[{i}/{len(combos_to_run)}] | {rw} | BS={bs} | Jobs={nj} | QD={qd}")
                json_files = execute_synchronized_parallel(devs, "seq", rw, bs, qd, nj, args.runtime, args.raw_dir, args)
                for jf, d_name in json_files:
                    res = parse_fio_json(jf)
                    if res:
                        res.update({"drive": d_name, "pattern": f"seq_{rw}", "bs": bs, "nj": nj, "qd": qd})
                        results.append(res)

    if args.run_rand_read == 'yes' or args.run_rand_write == 'yes':
        if args.rand_pre == 'yes':
            log_print("\n[INFO] === Executing Random Preconditioning (with Steady-State Detection) ===")
            # 带稳态检测的随机预处理 / Random preconditioning with steady-state detection
            precon_log = run_rand_precon_with_steady_state(devs, args.raw_dir, args)

        for rw, run_flag in [('randread', args.run_rand_read), ('randwrite', args.run_rand_write)]:
            if run_flag != 'yes': continue
            log_print(f"\n[INFO] === Matrix Testing: Random {rw} ===")

            if args.mode == 'multi':
                combos_to_run = [c for c in RAND_COMBOS if c[0] in bs_list]
            else:
                combos_to_run = build_combos(bs_list)

            for i, (bs, nj, qd) in enumerate(combos_to_run, 1):
                log_print(f"  -> Progress[{i}/{len(combos_to_run)}] | {rw} | BS={bs} | Jobs={nj} | QD={qd}")
                json_files = execute_synchronized_parallel(devs, "rand", rw, bs, qd, nj, args.runtime, args.raw_dir, args)
                for jf, d_name in json_files:
                    res = parse_fio_json(jf)
                    if res:
                        res.update({"drive": d_name, "pattern": f"{rw}", "bs": bs, "nj": nj, "qd": qd})
                        results.append(res)

    if args.run_mixed == 'yes':
        log_print("\n[INFO] === Matrix Testing: Mixed RW ===")
        mix_bs = [b for b in ['4k', '8k', '16k', '32k'] if b in bs_list]
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

    if args.run_qos == 'yes':
        log_print("\n[INFO] === QoS Latency Testing (4k RandRead/RandWrite, QD=32, NJ=4) ===")
        # QoS test: 4k randread and randwrite at QD=32, numjobs=4 / QoS 测试：4k 随机读写，QD=32，NJ=4
        for rw in ['randread', 'randwrite']:
            log_print(f"  -> QoS test | {rw} | BS=4k | QD=32 | NJ=4 | Runtime={args.qos_runtime}s")
            json_files = execute_synchronized_parallel(devs, "qos", rw, "4k", 32, 4, args.qos_runtime, args.raw_dir, args)
            for jf, d_name in json_files:
                res = parse_fio_json_qos(jf, rw)
                if res:
                    res.update({"drive": d_name, "workload": rw, "bs": "4k", "qd": 32, "nj": 4})
                    qos_results.append(res)
        if qos_results:
            log_print(f"[INFO] QoS test completed. Collected {len(qos_results)} result(s).")
        else:
            log_print("[WARN] QoS test produced no results. Check raw JSON files.")

    generate_excel(pd.DataFrame(results) if results else pd.DataFrame(), mixed_results, precon_log, args, devs, drive_infos, qos_results)

if __name__ == "__main__":
    main()
EOF

# ====================[ 执行与触发 / Execution and Trigger ] ====================
EXCEL_REPORT="${BASE_DIR}/Storage_Performance_Report_${SERVER_MODEL}.xlsx"

echo "=========================================================================="
echo "[WARNING] Enterprise NVMe Test Suite v2 is ready to go."
echo "[INFO] Matrix Test Mode: $TEST_MODE"
echo "[INFO] Drives targeted: ${TARGET_DEVS[*]}"
echo "[INFO] Fixed RUNTIME=${RUNTIME}s | RAMP_TIME=${RAMP_TIME}s"
echo "[INFO] Max Outstanding IO cap: ${MAX_OUTSTANDING_IO}"
echo "=========================================================================="
sleep 10

python3 "$PYTHON_ENGINE" \
    --devs "${TARGET_DEVS[*]}" \
    --mode "$TEST_MODE" \
    --runtime "$RUNTIME" \
    --mix_runtime "$MIX_RUNTIME" \
    --qos_runtime "$QOS_RUNTIME" \
    --ramp_time "$RAMP_TIME" \
    --raw_dir "$RAW_DIR" \
    --out_excel "$EXCEL_REPORT" \
    --model "$SERVER_MODEL" \
    --bs_list "$TEST_BS_LIST" \
    --seq_pre "$DO_SEQ_PRECON" \
    --seq_loops "$SEQ_PRE_LOOPS" \
    --rand_pre "$DO_RAND_PRECON" \
    --rand_loops "$RAND_PRE_LOOPS" \
    --rand_pre_max_loops "$RAND_PRE_MAX_LOOPS" \
    --steady_state_check "$ENABLE_STEADY_STATE_CHECK" \
    --steady_threshold "$STEADY_STATE_THRESHOLD" \
    --steady_window "$STEADY_STATE_WINDOW" \
    --max_outstanding_io "$MAX_OUTSTANDING_IO" \
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

# ====================[ 测试后诊断信息收集 / Post-flight Diagnostics Collection ] ====================
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

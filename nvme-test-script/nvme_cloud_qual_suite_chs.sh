#!/bin/bash
# ============================================================================
# nvme_cloud_qual_suite_chs
# 版本   : 2.0
# 作者   : SIT-Kit / Prz1y
# 更新   : 2026-04
# ----------------------------------------------------------------------------
# 说明:
#   面向云场景的 NVMe 存储性能自动化测试套件。
#   覆盖顺序读写、随机读写、混合读写全矩阵，并采集测试前后 SMART 日志、
#   PCIe AER 异常检测及 IPMI SEL 事件。
#   测试结果自动汇总为结构化 Excel 报告，包含各模式下的 IOPS 矩阵
#   和 clat（盘侧完成延迟）矩阵。
#
#   随机 I/O 使用 FIO 3.41+ 新增的 sprandom (Xoshiro256+) 随机数生成器，
#   相比传统 tausworthe64 在大容量 NVMe 上具有更均匀的 LBA 分布。
#
# 环境要求:
#   - FIO >= 3.41  （sprandom 随机数生成器支持）
#   - Root 权限
#
# 系统依赖:
#   sudo yum/apt-get install -y fio nvme-cli pciutils python3 python3-pip \
#                               numactl ipmitool libaio-devel
#   pip3 install pandas openpyxl
#
# 使用方法:
#   1. 编辑下方 [ 核心配置区 ]，按实际测试环境填写参数。
#   2. 以 root 运行:  sudo bash nvme_cloud_qual_suite_chs.sh
#   3. 断点续测: 将 RESUME_FROM 设为已有的测试工作目录路径后重新执行即可。
# ============================================================================

# ============================================================================
#[ 核心配置区 ]  ← 运行前只需修改这里
# ============================================================================

# 测试模式: "single" = 单盘全矩阵(numjobs×iodepth 完整扫描)
#           "multi"  = 多盘并发(仅跑 SEQ_COMBOS/RAND_COMBOS 代表性组合)
TEST_MODE="single"

# 目标块设备列表。single 模式填1个，multi 模式可填多个，用空格分隔数组元素
# 示例(多盘): TARGET_DEVS=("/dev/nvme0n1" "/dev/nvme1n1")
TARGET_DEVS=("/dev/nvme1n1")

# 服务器型号标识，用于生成报告文件名，不含空格
SERVER_MODEL="Server"

# 单个顺序/随机测试点的运行时长（秒）。建议 ≥ 300s 以保证稳态数据
RUNTIME=300

# 混合读写每个测试点的运行时长（秒）。需更长时间平衡读写队列
MIX_RUNTIME=1200

# 是否在顺序测试前执行顺序写预调教 (yes/no)
# 目的：将盘内部映射表刷新到稳定状态，排除空盘性能虚高
DO_SEQ_PRECON="yes"

# 顺序预调教循环次数。每次 loop 以 128k/QD128 顺序写填满 100% 容量
SEQ_PRE_LOOPS=2

# 是否在随机测试前执行随机写预调教 (yes/no)
DO_RAND_PRECON="yes"

# 随机预调教循环次数。以 4k/QD128/4jobs 随机写覆盖一次全盘
RAND_PRE_LOOPS=1

# 以下开关控制各测试阶段是否执行，设为 "no" 可跳过对应阶段
RUN_SEQ_READ="yes"   # 顺序读矩阵
RUN_SEQ_WRITE="yes"  # 顺序写矩阵
RUN_RAND_READ="yes"  # 随机读矩阵
RUN_RAND_WRITE="yes" # 随机写矩阵
RUN_MIXED_RW="yes"   # 混合读写矩阵 (4k/8k/16k/32k × 9种读写比)

# 块大小列表，空格分隔，所有阶段均遍历此列表
TEST_BS_LIST="4k 8k 16k 32k 64k 128k 256k 512k 1m"

# 断点续测：填写已有的测试工作目录路径（如 /path/to/NVME_TEST_20260401_120000）
# 留空则新建工作目录并从头开始
RESUME_FROM=""

# 是否启用 NUMA 绑定，将 fio 进程绑定到 NVMe 控制器所在的 NUMA 节点
# 多 NUMA 架构（如 2-socket 或 Hygon/AMD）下建议开启，避免跨节点内存访问带来性能抖动
ENABLE_NUMA_BIND="yes"

# NUMA 绑定实现方式:
#   "fio"     - 通过 fio 内置 --numa_cpu_nodes 参数绑定（推荐，无需额外依赖）
#   "numactl" - 通过 numactl 命令包装整个 fio 进程（需已安装 numactl）
NUMA_BIND_METHOD="fio"

# 当 sysfs 中读不到 NUMA 节点信息时的回退节点编号
NUMA_FALLBACK_NODE="0"

# ============================================================================
#[ 环境与安全前置检查 ]
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

# FIO version validation — sprandom random generator requires FIO >= 3.41
FIO_VER_RAW=$(fio --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
FIO_MAJOR=$(echo "$FIO_VER_RAW" | cut -d'.' -f1)
FIO_MINOR=$(echo "$FIO_VER_RAW" | cut -d'.' -f2)
if ! [[ "$FIO_MAJOR" =~ ^[0-9]+$ ]] || ! [[ "$FIO_MINOR" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Unable to determine FIO version. Output was: $(fio --version 2>/dev/null | head -1)"
    echo "[ERROR] Please verify your FIO installation."
    exit 1
fi
if [ "$FIO_MAJOR" -lt 3 ] || { [ "$FIO_MAJOR" -eq 3 ] && [ "$FIO_MINOR" -lt 41 ]; }; then
    echo "[ERROR] FIO version ${FIO_VER_RAW} is not supported."
    echo "[ERROR] This suite requires FIO >= 3.41 for sprandom I/O generator support."
    exit 1
fi
echo "[INFO] FIO version check passed: ${FIO_VER_RAW} (>= 3.41 required)"

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
for dev in "${TARGET_DEVS[@]}"; do
    dev_tag=$(basename "$dev")
    nvme smart-log "$dev" > "$LOG_DIR/pre_smart_${dev_tag}.log" 2>/dev/null || true
done

# ====================[ Python 测试引擎注入 ] ====================
PYTHON_ENGINE="${BASE_DIR}/nvme_fio_engine.py"

cat << 'EOF' > "$PYTHON_ENGINE"
import os, sys, json, time, subprocess, argparse, datetime
from concurrent.futures import ThreadPoolExecutor
import pandas as pd

# ----------------------------------------------------------------------------
# I/O 参数矩阵定义 (single 模式全量扫描, multi 模式仅跑代表性组合)
# ----------------------------------------------------------------------------
NUMJOBS_LIST = [1, 2, 4, 8]
IODEPTH_LIST = [1, 2, 4, 8, 16, 32, 64, 128, 256]
MIX_RATIO_LIST = [10, 20, 30, 40, 50, 60, 70, 80, 90]

# multi 模式代表性顺序组合 (bs, numjobs, iodepth)
SEQ_COMBOS = [
    ('128k', 1, 32), ('128k', 1, 64), ('128k', 1, 128), ('128k', 1, 256), ('128k', 1, 512),
    ('4k', 2, 32), ('64k', 2, 32), ('256k', 2, 32), ('1m', 2, 32),
]
# multi 模式代表性随机组合 (bs, numjobs, iodepth)
RAND_COMBOS = [
    ('4k', 1, 32), ('4k', 1, 64), ('4k', 1, 128), ('4k', 1, 256),
    ('4k', 4, 32), ('8k', 4, 32), ('16k', 4, 32),
]

def log_print(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)

def get_drive_info(dev):
    try:
        res = subprocess.run(f"nvme id-ctrl {dev}", shell=True, capture_output=True, text=True)
        mn, fr = "Unknown_Model", "Unknown_FW"
        for line in res.stdout.split('\n'):
            parts = line.split(':', 1)
            field = parts[0].strip()
            if field == 'mn' and len(parts) == 2:
                mn = parts[1].strip()
            elif field == 'fr' and len(parts) == 2:
                fr = parts[1].strip()
        return f"{mn} | {fr}"
    except Exception:
        return "Unknown | Unknown"

def get_numa_node(dev_path, fallback):
    try:
        dev_name = os.path.basename(dev_path)
        # "nvme0n1" → "nvme0": skip the leading 'n' in "nvme", find namespace separator 'n'
        ctrl_name = dev_name[:dev_name.index('n', 1)]
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
    for attempt in range(1, 4):
        log_print(f"[INFO] Formatting {dev} (Attempt {attempt}/3)...")
        if run_cmd(f"nvme format {dev} -s 1"):
            time.sleep(10)
            return True
        time.sleep(5)
    log_print(f"[CRITICAL] Failed to secure erase {dev} after 3 attempts.")
    sys.exit(1)

def calc_ramp_time(iodepth, numjobs):
    """Dynamically calculate ramp time based on I/O concurrency level.
    Mid-range concurrency (32-127 total IOs) reaches steady-state fastest.
    At extreme concurrency (128+ total IOs), a slightly longer ramp is used to
    allow the controller's internal queue management to fully stabilize.
    Low concurrency requires the longest ramp to build a representative access pattern."""
    total = iodepth * numjobs
    if total >= 128:
        return 20
    elif total >= 32:
        return 15
    elif total >= 8:
        return 30
    else:
        return 60

def calc_runtime(base_runtime, iodepth, numjobs):
    """Dynamically calculate test runtime based on I/O concurrency level.
    High concurrency produces stable data faster, so shorter runtime suffices."""
    total = iodepth * numjobs
    if total >= 128:
        return max(180, base_runtime // 2)
    elif total >= 32:
        return max(180, int(base_runtime * 0.6))
    else:
        return base_runtime

def build_fio_cmd(job_name, dev, rw, bs, iodepth, numjobs, runtime, json_out, args, loops=0, rwmixread=None):
    cmd = (f"fio --name={job_name} --filename={dev} --rw={rw} --bs={bs} "
           f"--iodepth={iodepth} --numjobs={numjobs} --direct=1 --ioengine=libaio "
           f"--thread --end_fsync=0 --buffer_compress_percentage=0 --invalidate=1 "
           f"--randrepeat=0 --refill_buffers "
           f"--percentile_list=50:99:99.9:99.99 "
           f"--group_reporting --output-format=json --output={json_out}")
    
    if 'rand' in rw:
        # sprandom (Xoshiro256+) requires FIO >= 3.41; provides superior LBA
        # distribution for large NVMe devices vs. legacy tausworthe64.
        cmd += " --random_generator=sprandom"

    if loops > 0:
        # Preconditioning: use size=100% to ensure full device coverage.
        # --norandommap is intentionally omitted here so FIO tracks visited LBAs
        # and guarantees every block is written exactly once per loop.
        # --exitall is also omitted: with numjobs > 1, we must not kill sibling
        # jobs early just because one job finishes its loop first.
        cmd += f" --loops={loops} --size=100%"
    else:
        # Performance test: disable LBA tracking to eliminate bookkeeping overhead
        # and allow unrestricted re-access for steady-state measurement.
        # --exitall ensures all jobs terminate together when the runtime expires.
        cmd += f" --norandommap --exitall"
        ramp = calc_ramp_time(iodepth, numjobs)
        actual_runtime = calc_runtime(runtime, iodepth, numjobs)
        cmd += f" --ramp_time={ramp} --runtime={actual_runtime} --time_based"
        
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
        log_print(f"[RESUME] Skipping existing task: {os.path.basename(json_out)}")
        return (json_out, dev_name)

    cmd = build_fio_cmd(job_name, dev, rw, bs, iodepth, numjobs, runtime, json_out, args, loops, rwmixread)
    success = run_cmd(cmd, log_out)
    if not success:
        log_print(f"[WARNING] fio exited with error for task: {os.path.basename(json_out)}. Check log: {log_out}")
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
        
        # Use clat_ns (device-side completion latency) for all metrics so that
        # min/avg/max and percentile columns share the same measurement dimension.
        # lat_ns includes kernel scheduling overhead and is intentionally excluded.
        clat_ns = tgt.get('clat_ns', {})
        min_lat = clat_ns.get('min', 0) / 1000.0
        avg_lat = clat_ns.get('mean', 0) / 1000.0
        max_lat = clat_ns.get('max', 0) / 1000.0

        clat_dict = clat_ns.get('percentile', {})
        p9999 = clat_dict.get('99.990000', 0) / 1000.0
        if p9999 == 0:
            p9999 = clat_dict.get('99.900000', 0) / 1000.0
            
        return {"iops": round(iops, 2), "bw": round(bw_mb, 2), "min_lat": round(min_lat, 2), 
                "avg_lat": round(avg_lat, 2), "max_lat": round(max_lat, 2), "p9999": round(p9999, 2)}
    except Exception as e:
        log_print(f"[WARNING] Failed to parse fio JSON '{json_file}': {e}")
        return None

def generate_multi_sheet(writer, df_all, pattern, sheet_name, combos, devs, drive_infos, model):
    """Generate a multi-drive comparison sheet in the grouped horizontal format:
    Row 0: title  (e.g. 机型-配置-硬盘型号-顺序读)
    Row 1: group headers  (128k-1-32, 128k-1-64, ...)
    Row 2: sub-headers    (iops, 带宽(MB/s), 平均时延(μs) per group)
    Row 3+: one row per drive, index = 型号/FW
    """
    ptn_df = df_all[df_all['pattern'] == pattern] if not df_all.empty else pd.DataFrame()

    # Build column structure
    combo_labels = [f"{bs}-{nj}-{qd}" for bs, nj, qd in combos]
    sub_cols = ['iops', '带宽(MB/s)', '平均时延(μs)']
    # MultiIndex columns: level-0 = combo label, level-1 = metric
    mi = pd.MultiIndex.from_tuples(
        [(cl, sc) for cl in combo_labels for sc in sub_cols],
        names=['测试组合', '指标']
    )

    rows_data = []
    row_index = []
    for d in devs:
        d_name = os.path.basename(d)
        info = drive_infos.get(d, 'Unknown | Unknown')
        row_index.append(info)
        row = []
        for bs, nj, qd in combos:
            match = ptn_df[(ptn_df['drive'] == d_name) & (ptn_df['bs'] == bs) &
                           (ptn_df['nj'] == nj) & (ptn_df['qd'] == qd)]
            if not match.empty:
                r = match.iloc[0]
                row.extend([r['iops'], r['bw'], r['avg_lat']])
            else:
                row.extend(['', '', ''])
        rows_data.append(row)

    df_sheet = pd.DataFrame(rows_data, columns=mi, index=row_index)
    df_sheet.index.name = '硬盘型号/FW版本'

    # Row 0: title
    rw_cn = {'seq_read': '顺序读', 'seq_write': '顺序写', 'randread': '随机读', 'randwrite': '随机写'}
    title = f"{model}-{rw_cn.get(pattern, pattern)}（记录所有硬盘结果）"
    pd.DataFrame([[title]]).to_excel(writer, sheet_name=sheet_name, startrow=0, startcol=0, header=False, index=False)
    # Row 1+: data with MultiIndex header
    df_sheet.to_excel(writer, sheet_name=sheet_name, startrow=1)

def generate_excel(df_all, mixed_results, args, devs, drive_infos):
    log_print("[INFO] Compiling data into standard Excel report...")
    out_excel = args.out_excel
    bs_list = args.bs_list.split()
    
    with pd.ExcelWriter(out_excel, engine='openpyxl') as writer:

        # 盘信息摘要页（写在第一个 sheet）
        info_rows = []
        for d in devs:
            info_rows.append({"device": d, "model_firmware": drive_infos.get(d, "Unknown"),
                               "server_model": args.model, "test_mode": args.mode,
                               "bs_list": args.bs_list, "runtime_s": args.runtime,
                               "mix_runtime_s": args.mix_runtime})
        pd.DataFrame(info_rows).to_excel(writer, sheet_name="盘信息", index=False)
        
        if not df_all.empty and args.mode == 'single':
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
                pd.DataFrame([["latency(μs):bs_thread_iodepth"]]).to_excel(writer, sheet_name=sheet_name, startrow=lat_start_row, startcol=0, header=False, index=False)
                df_lat.to_excel(writer, sheet_name=sheet_name, startrow=lat_start_row+1)

        if not df_all.empty and args.mode == 'multi':
            multi_sheet_map = {
                'seq_read': ('顺序读测试', SEQ_COMBOS), 'seq_write': ('顺序写测试', SEQ_COMBOS),
                'randread': ('随机读测试', RAND_COMBOS), 'randwrite': ('随机写测试', RAND_COMBOS),
            }
            for ptn, (sname, combos) in multi_sheet_map.items():
                if ptn in df_all['pattern'].values:
                    generate_multi_sheet(writer, df_all, ptn, sname, combos, devs, drive_infos, args.model)

        if mixed_results:
            pd.DataFrame(mixed_results).to_excel(writer, sheet_name='混合读写', index=False)

        # 保护性写入 Raw 数据页
        if not df_all.empty:
            df_all.to_excel(writer, sheet_name="Raw_Matrix_Data", index=False)
        
    log_print(f"[SUCCESS] Report successfully generated: {out_excel}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--devs', required=True)
    parser.add_argument('--mode', required=True)
    parser.add_argument('--runtime', type=int, required=True)
    parser.add_argument('--mix_runtime', type=int, required=True)
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
    parser.add_argument('--resume', action='store_true')
    
    args = parser.parse_args()
    devs = args.devs.split()
    bs_list = args.bs_list.split()
    results = [] 
    mixed_results = []
    
    log_print("[INFO] Initiating drive preparation...")
    drive_infos = {}
    for d in devs:
        if not args.resume:
            format_drive(d)
        drive_infos[d] = get_drive_info(d)

    if args.run_seq_read == 'yes' or args.run_seq_write == 'yes':
        if args.seq_pre == 'yes':
            log_print("\n[INFO] === Executing Sequential Preconditioning ===")
            execute_synchronized_parallel(devs, "pre_seq", "write", "128k", 128, 1, 0, args.raw_dir, args, loops=args.seq_loops)

        for rw, run_flag in [('read', args.run_seq_read), ('write', args.run_seq_write)]:
            if run_flag != 'yes': continue
            log_print(f"\n[INFO] === Matrix Testing: Sequential {rw} ===")
            
            combos_to_run = SEQ_COMBOS if args.mode == 'multi' else [(b, n, q) for b in bs_list for n in NUMJOBS_LIST for q in IODEPTH_LIST]
            combos_to_run = [c for c in combos_to_run if c[0] in bs_list]
            
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
            log_print("\n[INFO] === Executing Random Preconditioning ===")
            execute_synchronized_parallel(devs, "pre_rand", "randwrite", "4k", 128, 4, 0, args.raw_dir, args, loops=args.rand_loops)

        for rw, run_flag in [('randread', args.run_rand_read), ('randwrite', args.run_rand_write)]:
            if run_flag != 'yes': continue
            log_print(f"\n[INFO] === Matrix Testing: Random {rw} ===")
            
            combos_to_run = RAND_COMBOS if args.mode == 'multi' else [(b, n, q) for b in bs_list for n in NUMJOBS_LIST for q in IODEPTH_LIST]
            combos_to_run = [c for c in combos_to_run if c[0] in bs_list]
            
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
                            "read_iops_4j_64qd": res['read_iops'], "write_iops_4j_64qd": res['write_iops']
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
echo "[WARNING] Enterprise NVMe Test Suite is ready to go."
echo "[INFO] Matrix Test Mode: $TEST_MODE"
echo "[INFO] Drives targeted: ${TARGET_DEVS[*]}"
echo "=========================================================================="
sleep 10

python3 "$PYTHON_ENGINE" \
    --devs "${TARGET_DEVS[*]}" \
    --mode "$TEST_MODE" \
    --runtime "$RUNTIME" \
    --mix_runtime "$MIX_RUNTIME" \
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
    $RESUME_FLAG

# ====================[ 测试后诊断信息收集 ] ====================
echo "[INFO] Capturing post-flight diagnostics..."
dmesg -T > "$LOG_DIR/post_dmesg.log" 2>/dev/null || true
for dev in "${TARGET_DEVS[@]}"; do
    dev_tag=$(basename "$dev")
    nvme smart-log "$dev" > "$LOG_DIR/post_smart_${dev_tag}.log" 2>/dev/null || true
done

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

#!/usr/bin/env bash
set -euo pipefail

# 脚本所在目录（即日志根目录的父目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_ROOT="${SCRIPT_DIR}/cpupower_results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

DURATION=10
STRESS=false

usage() {
  cat <<EOF
Usage: $0 [--duration 秒] [--stress]

--duration 秒    : 压力测试持续时长，默认 ${DURATION}s
--stress         : 在每个调度器测试时运行短时CPU繁忙负载以观察频率变化

脚本会按顺序测试：ondemand, conservative, performance, userspace, powersave
需要 root 权限或使用 sudo 运行 cpupower 命令。
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --duration)
      [[ $# -gt 1 ]] || { echo "错误：--duration 需要一个参数" >&2; exit 1; }
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "错误：--duration 必须为正整数，得到: $2" >&2; exit 1; }
      DURATION="$2"; shift 2;;
    --stress) STRESS=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

# 检查 cpupower 是否存在（不存在时降级为直接写 /sys）
if ! command -v cpupower >/dev/null 2>&1; then
  echo "警告：未检测到 cpupower，将降级为直接写 /sys/devices/system/cpu/*/cpufreq/scaling_governor。"
  echo "建议安装 cpupower（通常在 linux-tools 或 cpufrequtils 软件包中）并以 root 执行。"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "建议以 root 或通过 sudo 运行此脚本以确保能设置 governor。"
fi

# 创建结果目录（每个 governor 一个子目录）
for _g in ondemand conservative performance userspace powersave; do
  mkdir -p "${RESULT_ROOT}/${_g}"
done
echo "测试记录将保存至: ${RESULT_ROOT}"

# 预检：确认 cpufreq 子系统可用
if [ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  echo "提示：未找到 cpufreq 接口，尝试加载驱动..."
  modprobe acpi-cpufreq 2>/dev/null || modprobe intel_pstate 2>/dev/null || true
  sleep 1
fi
if [ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  echo "错误：此系统不支持 cpufreq 频率调节，或驱动未加载。" >&2
  echo "可能原因：" >&2
  echo "  1. 这是虚拟机且宿主机未向 guest 暴露 cpufreq 接口" >&2
  echo "  2. 请尝试：modprobe acpi-cpufreq  或  modprobe intel_pstate" >&2
  echo "  3. 该平台（如部分 ARM/RISC-V 板）本身不支持软件调频" >&2
  exit 3
fi

# 目标调度器及说明
declare -A DESC
DESC[ondemand]="按需响应模式：有计算量立即升频，空闲回落最低"
DESC[conservative]="保守模式：随着负荷逐步提升频率，再逐步下降"
DESC[performance]="高性能模式：固定最高频，不动态调节，耗电最大"
DESC[userspace]="用户空间模式：允许用户态程序控制频率（通常不建议，且需额外设定目标频率）"
DESC[powersave]="省电模式：固定最低频，节能但性能低"

GOVS=(ondemand conservative performance userspace powersave)

# 记录并备份现有第0核调度器，以便恢复
ORIG_GOV=""
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
  ORIG_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
fi

restore() {
  if [ -n "$ORIG_GOV" ]; then
    echo "恢复原始 governor: $ORIG_GOV"
    if command -v cpupower >/dev/null 2>&1; then
      if [ "$(id -u)" -eq 0 ]; then
        cpupower frequency-set -g "$ORIG_GOV" || true
      else
        sudo cpupower frequency-set -g "$ORIG_GOV" || true
      fi
    else
      for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$ORIG_GOV" > "$f" 2>/dev/null || true
      done
    fi
  fi
}
trap restore EXIT

cpu_count() {
  nproc --all 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

cpu_stress() {
  local dur="$1"
  local n
  n=$(cpu_count)
  echo "启动 $n 个 busy-loop 线程，持续 ${dur}s 来观察频率变化"
  local PIDS=()
  local i
  for i in $(seq 1 "$n"); do
    ( while :; do :; done ) &
    PIDS+=("$!")
  done
  sleep "$dur"
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
}

available=""
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
  available=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || true)
fi

echo "可用 governor: ${available:-(unknown)}"

if [ -z "$available" ]; then
  echo "错误：无法读取可用 governor 列表（scaling_available_governors 为空）。" >&2
  echo "请确认 cpufreq 驱动已正确加载（cpupower frequency-info 查看详情）。" >&2
  exit 3
fi

for gov in "${GOVS[@]}"; do
  if [[ -n "$available" && ! " $available " =~ " $gov " ]]; then
    echo "跳过 $gov（不可用）"
    continue
  fi

  LOG_FILE="${RESULT_ROOT}/${gov}/${TIMESTAMP}.log"

  # --- 设置 governor（在 tee 块外，continue 才能生效）---
  echo "========================" | tee -a "$LOG_FILE"
  echo "测试 governor: $gov" | tee -a "$LOG_FILE"
  echo "说明: ${DESC[$gov]}" | tee -a "$LOG_FILE"
  echo "测试时间: $(date)" | tee -a "$LOG_FILE"
  echo "内核版本: $(uname -r)" | tee -a "$LOG_FILE"
  echo "应用中..." | tee -a "$LOG_FILE"
  if command -v cpupower >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      cpupower frequency-set -g "$gov" 2>&1 | tee -a "$LOG_FILE" || true
    else
      sudo cpupower frequency-set -g "$gov" 2>&1 | tee -a "$LOG_FILE" || true
    fi
  else
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo "$gov" > "$f" 2>/dev/null || true
    done
  fi

  # 校验是否生效（在外层循环中，continue 有效）
  ACTUAL_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
  if [ "$ACTUAL_GOV" != "$gov" ]; then
    MSG="警告：governor 设置失败（期望 $gov，实际 ${ACTUAL_GOV:-未知}），跳过本轮测试。"
    echo "$MSG" | tee -a "$LOG_FILE"
    echo "--- $gov 测试跳过（设置失败）---" | tee -a "$LOG_FILE"
    echo
    continue
  fi

  {
    # userspace 模式需额外指定频率，否则频率状态不确定
    if [ "$gov" = "userspace" ]; then
      MAX_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || true)
      if [ -n "$MAX_FREQ" ]; then
        echo "userspace 模式：将频率固定至最大值 ${MAX_FREQ} KHz"
        if command -v cpupower >/dev/null 2>&1; then
          if [ "$(id -u)" -eq 0 ]; then
            cpupower frequency-set -f "${MAX_FREQ}" || true
          else
            sudo cpupower frequency-set -f "${MAX_FREQ}" || true
          fi
        else
          for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_setspeed; do
            echo "$MAX_FREQ" > "$f" 2>/dev/null || true
          done
        fi
      else
        echo "警告：无法获取最大频率，userspace 模式下频率状态不确定"
      fi
    fi
    sleep 1

    echo "当前每核 governor (示例):"
    grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sed -n '1,5p' || echo "（无法读取 /sys cpufreq 信息）"

    if [ "$STRESS" = true ]; then
      cpu_stress "$DURATION"
    else
      echo "未启用压力测试，等待 2s 以便观察默认行为"
      sleep 2
    fi

    if command -v cpupower >/dev/null 2>&1; then
      echo "频率信息（cpu0 示例）:"
      cpupower frequency-info 2>/dev/null | sed -n '1,10p' || true
    else
      echo "检查 /sys 获取频率（cpu0）:"
      if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        awk '{print $1/1000 " kHz"}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || true
      fi
    fi
    echo "--- $gov 测试结束 ---"
  } 2>&1 | tee -a "$LOG_FILE"
  echo
done

echo
echo "测试完成，退出时将尝试恢复原始 governor。"
exit 0

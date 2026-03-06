#!/bin/bash

# 设置为中文环境
export LC_ALL=zh_CN.UTF-8
export LANG=zh_CN.UTF-8

# 获取操作系统的内核版本
OS_KERNEL=$(uname -r)

echo "=================================================="
echo "开始执行操作系统功能专项测试 (共9项)..."
echo "当前内核版本(uname -r): $OS_KERNEL"
echo "=================================================="

# 检查是否为root用户，给予提示
if [ "$EUID" -ne 0 ]; then
  echo "【警告】您当前不是 root 用户！部分硬件扫描(如fdisk, dmidecode)和日志查看可能因权限不足而无输出。"
  echo "建议按 Ctrl+C 终止，并使用 sudo ./os_9_features_test.sh 执行。"
  echo "--------------------------------------------------"
  sleep 3
fi

# 定义一个核心函数：创建独立文件夹、初始化日志并执行多个指令
run_test_item() {
    local folder_name="$1"
    local test_desc="$2"
    shift 2
    local cmds=("$@")

    # 1. 创建独立的测试结果文件夹
    mkdir -p "$folder_name"
    local log_file="${folder_name}/execution.log"
    > "$log_file"

    echo "正在测试并生成目录: $folder_name ..."

    # 2. 写入测试项描述和 uname -r
    echo "测试项需求: $test_desc" >> "$log_file"
    echo "==================================================" >> "$log_file"
    echo "[系统版本]: uname -r = $OS_KERNEL" >> "$log_file"
    echo "==================================================" >> "$log_file"

    # 3. 遍历执行该项的具体指令
    for cmd in "${cmds[@]}"; do
        echo "--------------------------------------------------" >> "$log_file"
        echo "[执行指令]: $cmd" >> "$log_file"
        echo "--------------------------------------------------" >> "$log_file"
        
        # 使用 bash -c 执行以支持管道符和复杂参数，同时捕获标准输出和错误
        bash -c "$cmd" >> "$log_file" 2>&1
        echo "" >> "$log_file"
    done
}


# ---------------------------------------------------------
# 测试项 1
# ---------------------------------------------------------
desc1="操作系统实现对国产CPU的识别，主要包括CPU基本信息的获取与显示功能(保留相关截图)"
cmds1=(
    "lscpu"
    "cat /proc/cpuinfo | grep -E 'model name|vendor_id|cpu cores' | head -n 10"
)
run_test_item "01_CPU_Identification" "$desc1" "${cmds1[@]}"

# ---------------------------------------------------------
# 测试项 2
# ---------------------------------------------------------
desc2="是否正确标明进程状态，是否存在cpu空闲情况，能否进行进程调度并正确修改进程状态，是否提供进程中断或结束接口"
cmds2=(
    "top -b -n 1 | head -n 15"
    "ps -aux | head -n 10"
    "renice --help"
    "kill --help"
)
run_test_item "02_Process_Management" "$desc2" "${cmds2[@]}"

# ---------------------------------------------------------
# 测试项 3
# ---------------------------------------------------------
desc3="能够完成系统时区、日期、时间的调整，设置日期、时间格式，同步机制：自动与手动"
cmds3=(
    "date"
    "timedatectl status"
    "timedatectl --help"
    "hwclock --help"
)
run_test_item "03_Time_And_Date" "$desc3" "${cmds3[@]}"

# ---------------------------------------------------------
# 测试项 4
# ---------------------------------------------------------
desc4="能够提供添加、删除用户的功能；提供对用户信息显示与编辑的功能；提供设置用户密码的功能，并可以设置帐户和密码的过期时间"
cmds4=(
    "useradd --help"
    "userdel --help"
    "usermod --help"
    "passwd --help"
    "chage --help"
)
run_test_item "04_User_Management" "$desc4" "${cmds4[@]}"

# ---------------------------------------------------------
# 测试项 5
# ---------------------------------------------------------
desc5="系统提供用户或用户组权限管理功能"
cmds5=(
    "chmod --help"
    "chown --help"
    "setfacl --help 2>/dev/null || echo '未安装 ACL 扩展权限工具'"
)
run_test_item "05_Permission_Management" "$desc5" "${cmds5[@]}"

# ---------------------------------------------------------
# 测试项 6
# ---------------------------------------------------------
desc6="能够查看系统提供的服务；可更改服务状态和启动类别"
cmds6=(
    "systemctl list-units --type=service --state=running | head -n 15"
    "systemctl --help | grep -E 'start |stop |restart |enable |disable '"
)
run_test_item "06_Service_Management" "$desc6" "${cmds6[@]}"

# ---------------------------------------------------------
# 测试项 7
# ---------------------------------------------------------
desc7="能够显示系统的概要信息、硬件信息、分区信息"
cmds7=(
    "uname -a"
    "free -h"
    "lsblk"
    "fdisk -l"
)
run_test_item "07_System_And_Partition_Info" "$desc7" "${cmds7[@]}"

# ---------------------------------------------------------
# 测试项 8
# ---------------------------------------------------------
desc8="可以扫描系统硬件，查看硬件属性"
cmds8=(
    "lspci | head -n 10"
    "lsusb | head -n 10"
    "dmidecode -t system"
)
run_test_item "08_Hardware_Scan" "$desc8" "${cmds8[@]}"

# ---------------------------------------------------------
# 测试项 9
# ---------------------------------------------------------
desc9="系统支持日志记录功能，能对日志文件查看"
cmds9=(
    "ls -lh /var/log/ | head -n 15"
    "journalctl -n 20"
    "tail -n 10 /var/log/messages 2>/dev/null || tail -n 10 /var/log/syslog 2>/dev/null"
)
run_test_item "09_System_Logging" "$desc9" "${cmds9[@]}"

echo "--------------------------------------------------"
echo "所有 9 项测试已执行完毕！"
echo "请查看当前目录下生成的 9 个独立文件夹（01至09），每个文件夹内包含对应的 execution.log。"

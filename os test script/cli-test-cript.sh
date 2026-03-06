#!/bin/bash

# 设置为中文环境以触发中文报错“未找到命令”
export LC_ALL=zh_CN.UTF-8
export LANG=zh_CN.UTF-8

# 获取操作系统的内核版本
OS_KERNEL=$(uname -r)

# 对应测试用例
group1=("ls" "cd" "pwd" "mkdir" "mv" "rmdir" "cp" "vi" "cat" "touch" "file" "ln" "grep" "chown" "chmod" "sort" "wc" "fdisk" "df" "mount" "mkfs" "tar" "dd" "zip" "unzip" "gzip")
group2=("ps" "vmstat" "top" "iostat" "sar")
group3=("ifconfig" "ping" "ssh" "scp" "telnet")
group4=("kill" "man" "who" "date" "more" "ps" "su" "sudo" "uname" "service" "chkconfig" "systemctl")
group5=("useradd" "userdel" "usermod" "groupadd" "groupdel" "groupmod" "id")

# 测试执行核心函数
run_test() {
    local folder_name=$1
    shift
    local cmds=("$@")

    # 1. 创建对应的结果文件夹
    mkdir -p "$folder_name"
    local log_file="${folder_name}/execution.log"

    # 清空并初始化日志文件
    > "$log_file"

    echo "正在执行测试并生成日志: ${folder_name}/execution.log ..."
    
    # 将 uname -r 写入日志头部
    echo "==================================================" >> "$log_file"
    echo "系统内核版本 (uname -r): $OS_KERNEL" >> "$log_file"
    echo "==================================================" >> "$log_file"

    # 2. 遍历执行每一个命令
    for cmd in "${cmds[@]}"; do
        # 记录具体的执行指令
        echo "--------------------------------------------------" >> "$log_file"
        echo "执行指令: $cmd --help" >> "$log_file"
        echo "--------------------------------------------------" >> "$log_file"

        # 执行 [命令名称] --help，将标准输出和标准错误全部追加到日志中
        $cmd --help >> "$log_file" 2>&1
        echo "" >> "$log_file"
    done

    # 3. 自动化测试检查逻辑 (直接检查生成的日志文件)
    echo "==================================================" >> "$log_file"
    # 搜索日志中是否出现“未找到命令”或英文系统的“command not found”
    if grep -Eiq "未找到命令|command not found" "$log_file"; then
        echo "自动化测试结论: 测试不通过，检查结果日志中发现了“未找到命令”关键字。" >> "$log_file"
    else
        echo "自动化测试：程序成功执行完成，检查结果日志中不包含“未找到命令”关键字" >> "$log_file"
    fi
}

echo "开始执行系统命令探测自动化测试..."
echo "当前内核版本: $OS_KERNEL"
echo "--------------------------------------------------"

run_test "01_TestResult_File_And_Disk" "${group1[@]}"
run_test "02_TestResult_System_Monitor" "${group2[@]}"
run_test "03_TestResult_Network" "${group3[@]}"
run_test "04_TestResult_System_Admin" "${group4[@]}"
run_test "05_TestResult_User_And_Group" "${group5[@]}"

echo "--------------------------------------------------"
echo "所有测试脚本执行完毕！"
echo "请查看当前目录下生成的 5 个文件夹中的 execution.log 文件获取结果。"

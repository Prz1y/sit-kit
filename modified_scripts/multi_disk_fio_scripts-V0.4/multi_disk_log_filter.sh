#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
# ********************************************************************
# Version V0.1
# Author: zhouq32@chinatelecom.cn
# Filter Results for multi disks fio test according to ctc io pattern
# ********************************************************************
CPWD="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$CPWD" || exit 1
#rm -f ssd_symbol_set hdd_symbol_set nvme_symbol_set filter_multi*.csv

IS_NVME_FILTER=false
IS_SSD_FILTER=false
IS_HDD_FILTER=false

usage()
{
    echo "$0 [-h help] [-N nvme_log_filter] [-S ssd_log_filter] [-H hdd_log_filter]"
    echo "examples:"
    echo "$0 -h, usage"
    echo "$0 -N, filter multi nvme ssds fio log"
    echo "$0 -S, filter multi ssds fio log"
    echo "$0 -H, filter multi hdds fio log"
    exit 1
}
while getopts "hNSH" arg
do
    case $arg in
        h)
        usage;;
        N)
        IS_NVME_FILTER=true;;
        S)
        IS_SSD_FILTER=true;;
        H)
        IS_HDD_FILTER=true;;
        *)
        usage;;
    esac
done

# require_log: exit with error if log file missing or empty
require_log() {
    local log_file="$1"
    if [[ ! -s "$log_file" ]]; then
        echo "ERROR: missing or empty log file: $log_file" >&2
        exit 1
    fi
}

# extract_metric: extract a single FIO metric from a log file block.
# Usage: extract_metric <log_file> <pattern> <metric_type>
# metric_type: iops | bandwidth | latency_value | latency_unit
extract_metric() {
    local log_file="$1"
    local pattern="$2"
    local metric_type="$3"
    local block
    block=$(grep -A4 "${pattern}: \\(groupid=" "$log_file" 2>/dev/null || true)
    case "$metric_type" in
        iops)
            echo "$block" | grep IOPS | tr -d ' ' | awk -F"," '{print $1}' | awk -F"=" '{print $2}'
            ;;
        bandwidth)
            echo "$block" | grep IOPS | grep -Eo "[0-9]+\.?[0-9]*[GgMmKk]?B/s" | head -1
            ;;
        latency_value)
            echo "$block" | grep -w lat | tr -d ' ' | awk -F"," '{print $(NF-1)}' | awk -F"=" '{print $2}'
            ;;
        latency_unit)
            echo "$block" | grep -w lat | tr -d ' ' | awk -F"," '{print $1}' | grep -Eo "[umn]?sec"
            ;;
    esac
}


filter_ssd_hdd_nvme_set()
{
    rm -f ssd_symbol_set hdd_symbol_set nvme_symbol_set
    os_disk_symbol=$(lsblk | grep -B1 -E "part|boot" | grep -E "^sd[a-z]+|^nvme" | awk '{print $1}' | xargs | sed 's/ /|/g')
    non_os_disk_set=$(lsscsi -g |grep -E "ATA|TOSHIBA" |awk '{print $(NF-1)}' |grep -Ewv -- "$os_disk_symbol")
    if [[ -n $non_os_disk_set ]];then
        for i in $(echo "$non_os_disk_set")
        do
            rotationRate=$(smartctl -i "$i" |awk -F":" '/Rotation Rate/{print $2}')
            if [[ $rotationRate =~ "Solid State Device" ]];then
                echo "$i" |awk -F"/" '{print $3}' >> ssd_symbol_set
            elif [[ $rotationRate =~ "rpm" ]];then
                echo "$i" |awk -F"/" '{print $3}' >> hdd_symbol_set
            fi
       done
    fi
	
    is_os_nvme=$(echo "$os_disk_symbol" |grep nvme)
    if [[ -n $is_os_nvme ]];then
        os_nvme_symbol=$(echo "$is_os_nvme" |grep -Eo "nvme[0-9]+n1")
    else
        os_nvme_symbol='^$'
    fi
    nvme_info_set=$(nvme list |grep -E "nvme[0-9]+n1" |grep -v -- "$os_nvme_symbol")
    if [[ -n $nvme_info_set ]];then
        echo "$nvme_info_set" |awk '{print $1}' |awk -F"/" '{print $3}' > nvme_symbol_set
    fi
}

# ***********************************
# filter multi nvme disk fio log
# ***********************************
filter_multi_nvme_log()
{
    rm -f filter_multi*.csv
    filter_multi_nvme_sequence_log
    filter_multi_nvme_random_log
    cat filter_multi_nvme_read.csv filter_multi_nvme_write.csv filter_multi_nvme_randread.csv filter_multi_nvme_randwrite.csv 2>/dev/null > filter_multi_nvme_Result.csv
}
# ***********************************

filter_multi_nvme_sequence_log()
{
    for rw in read write
    do
        echo "${rw}_test_data" >> filter_multi_nvme_${rw}.csv
        printf '%s\n' "Model|FW,128k_1_32,,,128k_1_64,,,128k_1_128,,,128k_1_256,,,128k_1_512,,,4k_2_32,,,64k_2_32,,,256k_2_32,,,1m_2_32,,," >> filter_multi_nvme_${rw}.csv
        echo -n "," >> filter_multi_nvme_${rw}.csv
        for i in $(seq 1 9)
        do
            echo -n "iops,bandwidth,latency," >> filter_multi_nvme_${rw}.csv
        done
        echo "" >> filter_multi_nvme_${rw}.csv

        for dev in $(cat nvme_symbol_set)
        do
            echo -n "ssd_${dev}," >> filter_multi_nvme_${rw}.csv
            local log_file="ssd_${dev}_${rw}.log"
            require_log "$log_file"
            for pattern in 128k_1_32 128k_1_64 128k_1_128 128k_1_256 128k_1_512 4k_2_32 64k_2_32 256k_2_32 1m_2_32
            do
                iops=$(extract_metric "$log_file" "${rw}_${pattern}" iops)
                bandWidth=$(extract_metric "$log_file" "${rw}_${pattern}" bandwidth)
                avgLatValue=$(extract_metric "$log_file" "${rw}_${pattern}" latency_value)
                avgLatUnit=$(extract_metric "$log_file" "${rw}_${pattern}" latency_unit)
                avgLat=${avgLatValue}${avgLatUnit}
                echo -n "${iops},${bandWidth},${avgLat}," >> filter_multi_nvme_${rw}.csv
            done
           echo "" >> filter_multi_nvme_${rw}.csv
        done
        echo "" >> filter_multi_nvme_${rw}.csv 
    done  
}

filter_multi_nvme_random_log()
{   
    for rw in randread randwrite
    do
        echo "${rw}_test_data" >> filter_multi_nvme_${rw}.csv  
        printf '%s\n' "Model|FW,4k_1_1,,,4k_1_32,,,4k_2_32,,,4k_2_256,,,4k_4_32,,,4k_4_64,,,4k_8_1,,,4k_8_32,,,4k_8_64,,,4k_8_256,,,4k_16_64,,,\
	8k_1_32,,,8k_4_64,,,8k_8_1,,,8k_8_32,,,8k_8_64,,,64k_2_32,,,128k_2_64,,,256k_2_32,,,1m_2_32,,," >> filter_multi_nvme_${rw}.csv
        echo -n "," >> filter_multi_nvme_${rw}.csv
        for i in $(seq 1 20)
        do
            echo -n "iops,bandwidth,latency," >> filter_multi_nvme_${rw}.csv
        done
        echo "" >> filter_multi_nvme_${rw}.csv       

        for dev in $(cat nvme_symbol_set)
        do
            echo -n "ssd_${dev}," >> filter_multi_nvme_${rw}.csv
            local log_file="ssd_${dev}_${rw}.log"
            require_log "$log_file"
            for pattern in 4k_1_1 4k_1_32 4k_2_32 4k_2_256 4k_4_32 4k_4_64 4k_8_1 4k_8_32 4k_8_64 4k_8_256 4k_16_64 \
		8k_1_32 8k_4_64 8k_8_1 8k_8_32 8k_8_64 64k_2_32 128k_2_64 256k_2_32 1m_2_32
            do  
                iops=$(extract_metric "$log_file" "${rw}_${pattern}" iops)
                bandWidth=$(extract_metric "$log_file" "${rw}_${pattern}" bandwidth)
                avgLatValue=$(extract_metric "$log_file" "${rw}_${pattern}" latency_value)
                avgLatUnit=$(extract_metric "$log_file" "${rw}_${pattern}" latency_unit)
                avgLat=${avgLatValue}${avgLatUnit}
                echo -n "${iops},${bandWidth},${avgLat}," >> filter_multi_nvme_${rw}.csv
            done
           echo "" >> filter_multi_nvme_${rw}.csv
        done
        echo "" >> filter_multi_nvme_${rw}.csv
    done  
}

# ***********************************
# filter multi ssd disk fio log
# ***********************************
filter_multi_ssd_log()
{
    rm -f filter_multi*.csv
    filter_multi_ssd_sequence_log
    filter_multi_ssd_random_log
    cat filter_multi_ssd_read.csv filter_multi_ssd_write.csv filter_multi_ssd_randread.csv filter_multi_ssd_randwrite.csv 2>/dev/null > filter_multi_ssd_Result.csv
}
# ***********************************

filter_multi_ssd_sequence_log()
{   
    for rw in read write
    do
        echo "${rw}_test_data" >> filter_multi_ssd_${rw}.csv
        printf '%s\n' "Model|FW,128k_1_32,,,128k_1_64,,,128k_1_128,,,128k_1_256,,,128k_1_512,,,4k_2_32,,,64k_2_32,,,256k_2_32,,,1m_2_32,,," >> filter_multi_ssd_${rw}.csv
        echo -n "," >> filter_multi_ssd_${rw}.csv
        for i in $(seq 1 9)
        do
            echo -n "iops,bandwidth,latency," >> filter_multi_ssd_${rw}.csv
        done
        echo "" >> filter_multi_ssd_${rw}.csv
  
        for dev in $(cat ssd_symbol_set)
        do
            echo -n "ssd_${dev}," >> filter_multi_ssd_${rw}.csv
            local log_file="ssd_${dev}_${rw}.log"
            require_log "$log_file"
            for pattern in 128k_1_32 128k_1_64 128k_1_128 128k_1_256 128k_1_512 4k_2_32 64k_2_32 256k_2_32 1m_2_32
            do  
                iops=$(extract_metric "$log_file" "${rw}_${pattern}" iops)
                bandWidth=$(extract_metric "$log_file" "${rw}_${pattern}" bandwidth)
                avgLatValue=$(extract_metric "$log_file" "${rw}_${pattern}" latency_value)
                avgLatUnit=$(extract_metric "$log_file" "${rw}_${pattern}" latency_unit)
                avgLat=${avgLatValue}${avgLatUnit}
                echo -n "${iops},${bandWidth},${avgLat}," >> filter_multi_ssd_${rw}.csv
            done
            echo "" >> filter_multi_ssd_${rw}.csv
        done
        echo "" >> filter_multi_ssd_${rw}.csv 
    done  
}

filter_multi_ssd_random_log()
{   
    for rw in randread randwrite
    do
        echo "${rw}_test_data" >> filter_multi_ssd_${rw}.csv        
        printf '%s\n' "Model|FW,4k_1_1,,,4k_1_32,,,4k_2_32,,,4k_2_256,,,4k_4_32,,,4k_4_64,,,4k_8_1,,,4k_8_32,,,4k_8_64,,,4k_8_256,,,4k_16_64,,,\
        8k_1_32,,,8k_4_64,,,8k_8_1,,,8k_8_32,,,8k_8_64,,,64k_2_32,,,128k_2_64,,,256k_2_32,,,1m_2_32,,," >> filter_multi_ssd_${rw}.csv
        echo -n "," >> filter_multi_ssd_${rw}.csv
        for i in $(seq 1 20)
        do
            echo -n "iops,bandwidth,latency," >> filter_multi_ssd_${rw}.csv
        done
        echo "" >> filter_multi_ssd_${rw}.csv

        for dev in $(cat ssd_symbol_set)
        do
            echo -n "ssd_${dev}," >> filter_multi_ssd_${rw}.csv
            local log_file="ssd_${dev}_${rw}.log"
            require_log "$log_file"
            for pattern in 4k_1_1 4k_1_32 4k_2_32 4k_2_256 4k_4_32 4k_4_64 4k_8_1 4k_8_32 4k_8_64 4k_8_256 4k_16_64 \
                8k_1_32 8k_4_64 8k_8_1 8k_8_32 8k_8_64 64k_2_32 128k_2_64 256k_2_32 1m_2_32
            do  
                iops=$(extract_metric "$log_file" "${rw}_${pattern}" iops)
                bandWidth=$(extract_metric "$log_file" "${rw}_${pattern}" bandwidth)
                avgLatValue=$(extract_metric "$log_file" "${rw}_${pattern}" latency_value)
                avgLatUnit=$(extract_metric "$log_file" "${rw}_${pattern}" latency_unit)
                avgLat=${avgLatValue}${avgLatUnit}
                echo -n "${iops},${bandWidth},${avgLat}," >> filter_multi_ssd_${rw}.csv
            done
            echo "" >> filter_multi_ssd_${rw}.csv
        done
        echo "" >> filter_multi_ssd_${rw}.csv
    done
}

# ***********************************
# filter multi hdd disk fio log
# ***********************************
filter_multi_hdd_log()
{
    rm -f filter_multi*.csv
    filter_multi_hdd_sequence_log
    filter_multi_hdd_random_log
    cat filter_multi_hdd_read.csv filter_multi_hdd_write.csv filter_multi_hdd_randread.csv filter_multi_hdd_randwrite.csv 2>/dev/null > filter_multi_hdd_Result.csv
}
# ***********************************

filter_multi_hdd_sequence_log()
{
    for rw in read write
    do
        echo "${rw}_test_data" >> filter_multi_hdd_${rw}.csv
        printf '%s\n' "Model|FW,4k_2_32,,,64k_2_32,,,256k_2_32,,,1m_1_32,,,1m_2_32,,," >> filter_multi_hdd_${rw}.csv
        echo -n "," >> filter_multi_hdd_${rw}.csv
        for i in $(seq 1 5)
        do
            echo -n "iops,bandwidth,latency," >> filter_multi_hdd_${rw}.csv
        done
        echo "" >> filter_multi_hdd_${rw}.csv

        for dev in $(cat hdd_symbol_set)
        do
            echo -n "hdd_${dev}," >> filter_multi_hdd_${rw}.csv
            local log_file="hdd_${dev}_${rw}.log"
            require_log "$log_file"
            for pattern in 4k_2_32 64k_2_32 256k_2_32 1m_1_32 1m_2_32
            do
                iops=$(extract_metric "$log_file" "${rw}_${pattern}" iops)
                bandWidth=$(extract_metric "$log_file" "${rw}_${pattern}" bandwidth)
                avgLatValue=$(extract_metric "$log_file" "${rw}_${pattern}" latency_value)
                avgLatUnit=$(extract_metric "$log_file" "${rw}_${pattern}" latency_unit)
                avgLat=${avgLatValue}${avgLatUnit}
                echo -n "${iops},${bandWidth},${avgLat}," >> filter_multi_hdd_${rw}.csv
            done
           echo "" >> filter_multi_hdd_${rw}.csv
        done
        echo "" >> filter_multi_hdd_${rw}.csv
    done
}

filter_multi_hdd_random_log()
{
    # filter multi hdd randread result
    echo "randread_test_data" >> filter_multi_hdd_randread.csv
    printf '%s\n' "Model|FW,4k_1_1,,,4k_1_4,,,4k_1_8,,,4k_1_16,,,8k_1_1,,,8k_1_32,,,4k_1_32,,,4k_2_32,,,64k_2_32,,,256k_2_32,,,1m_2_32,,," >> filter_multi_hdd_randread.csv
    echo -n "," >> filter_multi_hdd_randread.csv
    for i in $(seq 1 11)
    do
        echo -n "iops,bandwidth,latency," >> filter_multi_hdd_randread.csv
    done
    echo "" >> filter_multi_hdd_randread.csv

    for dev in $(cat hdd_symbol_set)
    do
        echo -n "hdd_${dev}," >> filter_multi_hdd_randread.csv
        local log_file="hdd_${dev}_randread.log"
        require_log "$log_file"
        for pattern in 4k_1_1 4k_1_4 4k_1_8 4k_1_16 8k_1_1 8k_1_32 4k_1_32 4k_2_32 64k_2_32 256k_2_32 1m_2_32
        do
            iops=$(extract_metric "$log_file" "randread_${pattern}" iops)
            bandWidth=$(extract_metric "$log_file" "randread_${pattern}" bandwidth)
            avgLatValue=$(extract_metric "$log_file" "randread_${pattern}" latency_value)
            avgLatUnit=$(extract_metric "$log_file" "randread_${pattern}" latency_unit)
            avgLat=${avgLatValue}${avgLatUnit}
            echo -n "${iops},${bandWidth},${avgLat}," >> filter_multi_hdd_randread.csv
        done
        echo "" >> filter_multi_hdd_randread.csv
    done
    echo "" >> filter_multi_hdd_randread.csv

    # filter multi hdd randwrite result
    echo "randwrite_test_data" >> filter_multi_hdd_randwrite.csv
    printf '%s\n' "Model|FW,4k_1_1,,,4k_2_32,,,64k_2_32,,,256k_2_32,,,1m_2_32,,," >> filter_multi_hdd_randwrite.csv
    echo -n "," >> filter_multi_hdd_randwrite.csv
    for i in $(seq 1 5)
    do
        echo -n "iops,bandwidth,latency," >> filter_multi_hdd_randwrite.csv
    done
    echo "" >> filter_multi_hdd_randwrite.csv

    for dev in $(cat hdd_symbol_set)
    do
        echo -n "hdd_${dev}," >> filter_multi_hdd_randwrite.csv
        local log_file="hdd_${dev}_randwrite.log"
        require_log "$log_file"
        for pattern in 4k_1_1 4k_2_32 64k_2_32 256k_2_32 1m_2_32
        do
            iops=$(extract_metric "$log_file" "randwrite_${pattern}" iops)
            bandWidth=$(extract_metric "$log_file" "randwrite_${pattern}" bandwidth)
            avgLatValue=$(extract_metric "$log_file" "randwrite_${pattern}" latency_value)
            avgLatUnit=$(extract_metric "$log_file" "randwrite_${pattern}" latency_unit)
            avgLat=${avgLatValue}${avgLatUnit}
            echo -n "${iops},${bandWidth},${avgLat}," >> filter_multi_hdd_randwrite.csv
        done
        echo "" >> filter_multi_hdd_randwrite.csv
    done
    echo "" >> filter_multi_hdd_randwrite.csv
}

if [[ $# -eq 0 ]];then
    usage
fi

#filter_ssd_hdd_nvme_set

if ${IS_NVME_FILTER};then
    filter_multi_nvme_log
fi

if ${IS_SSD_FILTER};then
    filter_multi_ssd_log
fi

if ${IS_HDD_FILTER};then
    filter_multi_hdd_log
fi

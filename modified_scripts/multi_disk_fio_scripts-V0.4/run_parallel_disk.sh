#!/usr/bin/env bash
set -euo pipefail
#****************************************************************#
# Author: zhouq32@chinatelecom.cn
# merge parallel nvme/ssd/hdd fio test with arguments option
# add log filter function after fio test 
# add multi nvme ssds fio with cpusbind functions
#****************************************************************#

CPWD="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$CPWD" || { echo "ERROR: failed to enter $CPWD" >&2; exit 1; }
rm -f -- ssd_symbol_set hdd_symbol_set nvme_symbol_set raid_symbol_set filter_multi*.csv

move_glob()
{
    local pattern="$1"
    local dest="$2"
    local files=()
    mapfile -t files < <(compgen -G "$pattern" || true)
    if [[ ${#files[@]} -gt 0 ]]; then
        mv -- "${files[@]}" "$dest"
    fi
}

IS_NVME_PARALLEL=false
IS_SSD_PARALLEL=false
IS_NVME_PARALLEL_WITH_CPUSBIND=false
IS_HDD_PARALLEL=false
IS_NVME_PARALLEL_STRESS=false
IS_SSD_PARALLEL_STRESS=false
IS_HDD_PARALLEL_STRESS=false

usage()
{
    echo "$0 [-h help] [-N nvme_fio_and_log_filter] [-S ssd_fio_and_log_filter] [-H hdd_fio_and_log_filter]"
    echo "$0 [-C nvme_fio_with_cpusbind and log filter] [-n nvme_fio_stress] [-s ssd_fio_stress] [-d hdd_fio_stress]"
    echo "examples:"
    echo "$0 -h, usage"
    echo "$0 -N, multi nvme ssds fio test and log filter"
    echo "$0 -C, multi nvme ssds fio test with cpusbind and log filter"
    echo "$0 -S, multi ssds fio test and log filter"
    echo "$0 -H, multi hdds fio test and log filter"
    echo "$0 -n, multi nvme ssds fio stress test"
    echo "$0 -s, multi ssds fio stress test"
    echo "$0 -d, multi hdds fio stress test"
    exit 1
}

while getopts "hNSCHnsd" arg
do
    case $arg in
        h)
        usage;;
        N)
        IS_NVME_PARALLEL=true;;
        S)
        IS_SSD_PARALLEL=true;;
        C)
        IS_NVME_PARALLEL_WITH_CPUSBIND=true;;
        H)
        IS_HDD_PARALLEL=true;;
        n)
        IS_NVME_PARALLEL_STRESS=true;;
        s)
        IS_SSD_PARALLEL_STRESS=true;;
        d)
        IS_HDD_PARALLEL_STRESS=true;;  
        *)
        usage;;
    esac
done

check_tool_installed()
{
    cmds="fio smartctl nvme numactl lsscsi lsblk bc date"
    for cmd in $cmds;do
        if ! command -v "$cmd" >/dev/null 2>&1;then
            echo "You must install required packages: fio smartmontools nvme-cli numactl lsscsi util-linux bc coreutils" >&2
            exit 1
        fi
    done
}

filter_ssd_hdd_nvme_set()
{
    rm -f ssd_symbol_set hdd_symbol_set nvme_symbol_set raid_symbol_set
    os_disk_symbol=$(lsblk | grep -B1 -E "part|boot" | grep -E "^sd[a-z]+|^nvme|^vd[a-z]+" | awk '{print $1}' | xargs | sed 's/ /|/g')
    non_os_disk_set=$(lsscsi -g |grep -E "ATA|TOSHIBA" |awk '{print $(NF-1)}' |grep -Ewv -- "$os_disk_symbol")
    if [[ -n $non_os_disk_set ]];then
        for i in $(echo "$non_os_disk_set")
        do
            rotationRate=$(smartctl -i "$i" |awk -F":" '/Rotation Rate/{print $2}')
            if [[ $rotationRate =~ "Solid State Device" ]];then
                echo "$i" |awk -F"/" '{print $3}' >> ssd_symbol_set
            elif [[ $rotationRate =~ "rpm" ]];then
                echo "$i" |awk -F"/" '{print $3}' >> hdd_symbol_set
            else
                echo "$i" |awk -F"/" '{print $3}' >> raid_symbol_set
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

ssd_cap_set()
{
    rm -f sata_ssd_cap nvme_cap
    os_disk_symbol=$(lsblk | grep -B1 -E "part|boot" | grep -E "^sd[a-z]+|^nvme|^vd[a-z]+" | awk '{print $1}' | xargs | sed 's/ /|/g')
    non_os_disk_set=$(lsscsi -g |grep -E "ATA|TOSHIBA" |awk '{print $(NF-1)}' |grep -Evw -- "$os_disk_symbol")
    if [[ -n $non_os_disk_set ]];then
        for i in $(echo "$non_os_disk_set")
        do
            diskCapDigit=""
            diskCapUnit=""
            rotationRate=$(smartctl -i "$i" |awk -F":" '/Rotation Rate/{print $2}')
            if [[ $rotationRate =~ "Solid State Device" ]];then
               	diskCapDigit=$(smartctl -i "$i" |awk '/User Capacity/{print $(NF-1)}' |sed 's/\[//')
                diskCapUnit=$(smartctl -i "$i" |awk '/User Capacity/{print $NF}' |sed 's/\]//')
            fi
            if [[ -n $(echo "$diskCapDigit" |grep "\.") ]];then
                mdiskCapDigit=$(echo "$diskCapDigit" |sed -e 's/\0$//' -e 's/\0$//' -e 's/\.$//')
                diskCap=$mdiskCapDigit$diskCapUnit
            else
                diskCap=$diskCapDigit$diskCapUnit
            fi
		echo -e "$diskCap" >> sata_ssd_cap
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
        for i in $(nvme list -o json |awk -F":" '/PhysicalSize/{print $2}' |sed -e 's/,//' -e 's/"//g' -e 's/^\s*//')
        do
            nvmeCapDigit=$(echo "scale=2;$i/1000/1000/1000/1000" | bc)
            if [[ -n $(echo "$nvmeCapDigit" |grep "\.") ]];then
                mnvmeCapDigit=$(echo "$nvmeCapDigit" |sed -e 's/\0$//' -e 's/\0$//' -e 's/\.$//')
                echo "$mnvmeCapDigit" >> nvme_cap
            else
                echo "$nvmeCapDigit" >> nvme_cap
            fi
        done
       # sed -i -E 's/(.*)/\1TB/g' nvme_cap
    fi
}

#********************************************
# Get CPU->NUMA Node->NVME SSD Topology
# Uses /sys filesystem interfaces (no lstopo/python needed)
#********************************************
get_cpu_numa_nvme_topo()
{
    rm -f cpu_numa_nvme_topo cpu_numanode_map numanode_nvme_map socket_numa_nvme_map
    echo "CPU Socket->NUMA Node->NVME SSD Topology:" >> cpu_numa_nvme_topo

    # Build numa_node -> cpu_socket mapping via /sys/devices/system/node
    rm -f cpu_numanode_map
    for node_path in /sys/devices/system/node/node*/; do
        local numa_node=$(basename $node_path | sed 's/node//')
        local first_cpu=$(awk -F'[-,]' '{print $1}' ${node_path}cpulist 2>/dev/null)
        if [[ -n $first_cpu ]] && [[ -f /sys/devices/system/cpu/cpu${first_cpu}/topology/physical_package_id ]]; then
            local cpu_socket=$(cat /sys/devices/system/cpu/cpu${first_cpu}/topology/physical_package_id)
            echo -e "cpu_socket=$cpu_socket numa_node=$numa_node" >> cpu_numanode_map
        fi
    done

    if [[ ! -s cpu_numanode_map ]]; then
        echo "WARNING: cannot determine CPU socket->NUMA mapping via /sys, defaulting all to socket 0" | tee -a cpu_numa_nvme_topo
        for node_path in /sys/devices/system/node/node*/; do
            local numa_node=$(basename $node_path | sed 's/node//')
            echo -e "cpu_socket=0 numa_node=$numa_node" >> cpu_numanode_map
        done
    fi

    # Build nvme -> numa_node mapping via /sys/bus/pci
    rm -f numanode_nvme_map
    for dev in $(nvme list |awk '/nvme[0-9]*n1/{print $1}' |awk -F"/" '{print $3}' |sed 's/n1$//g')
    do
        local dev_path
        dev_path=$(readlink -f "/sys/class/nvme/${dev}/device" 2>/dev/null || true)
        local busInfo
        busInfo=$(basename "$dev_path")
        local numaNode
        numaNode=$(cat "/sys/bus/pci/devices/${busInfo}/numa_node" 2>/dev/null)
        # numa_node=-1 means NUMA info unavailable, treat as node 0
        if [[ -z $numaNode ]] || [[ $numaNode -lt 0 ]]; then
            numaNode=0
        fi
        echo -e "numa_node=$numaNode nvme_label=${dev}n1" >> numanode_nvme_map
    done

    # Build socket -> numa -> nvme mapping
    rm -f socket_numa_nvme_map
    for node in $(awk '{print $2}' cpu_numanode_map 2>/dev/null)
    do
        if grep -qF -- "$node" numanode_nvme_map 2>/dev/null; then
            local socket=$(grep -F -- "$node" cpu_numanode_map |awk '{print $1}')
            for label in $(grep -F -- "$node" numanode_nvme_map |awk '{print $2}')
            do
                echo -e "$socket $node $label" >> socket_numa_nvme_map
            done
        else
            local socket=$(grep -F -- "$node" cpu_numanode_map |awk '{print $1}')
            echo -e "$socket $node nvme_label=NA" >> socket_numa_nvme_map
        fi
    done

    if [[ -s socket_numa_nvme_map ]]; then
        awk '{printf "%-15s%-15s%-15s\n",$1,$2,$3}' socket_numa_nvme_map >> cpu_numa_nvme_topo
    else
        echo "WARNING: could not build complete socket/NUMA/NVMe topology map" | tee -a cpu_numa_nvme_topo
    fi
}

nvme_format()
{
    if [[ "${ALLOW_NVME_FORMAT:-0}" != "1" ]];then
        echo "Skip nvme format. Set ALLOW_NVME_FORMAT=1 to enable." >&2
        return 0
    fi
    local -a pids=()
        for dev in $(cat nvme_symbol_set)
        do
        echo "[$(date '+%F %T')] nvme format /dev/$dev" >> "$CPWD/nvme_format_audit.log"
        nvme format "/dev/$dev"
    done
    cd "$CPWD" || { echo "ERROR: failed to enter $CPWD" >&2; exit 1; }
}

nvme_parallel_fio_test()
{
    # multi nvme ssd fio test
    if [ -s nvme_symbol_set ];then
        nvme_format
        if [ -d nvme_fio_log ];then
            mv nvme_fio_log "nvme_fio_log_$(date +%Y%m%d%H%M%S)"
            mkdir -p nvme_fio_log
        else
            mkdir -p nvme_fio_log
        fi
        for dev in $(cat nvme_symbol_set)
        do		
            nohup "$CPWD/ssd_raw_fio_test.sh" "$dev" &>/dev/null &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do
            wait "$pid" || echo "WARNING: child failed: $pid" >&2
        done
        sleep 30
        move_glob "ssd_nvme*_*.log" "nvme_fio_log"
        cp multi_disk_log_filter.sh nvme_symbol_set nvme_fio_log
        cd nvme_fio_log
        ./multi_disk_log_filter.sh -N
        cd "$CPWD" || { echo "ERROR: failed to enter $CPWD" >&2; exit 1; }
    fi
}

nvme_parallel_fio_test_with_cpusbind()
{
    # multi nvme ssd fio test with cpusbind
    if [ -s nvme_symbol_set ];then
	get_cpu_numa_nvme_topo
        nvme_format
        if [ -d cpusbind_nvme_fio_log ];then
            mv cpusbind_nvme_fio_log "cpusbind_nvme_fio_log_$(date +%Y%m%d%H%M%S)"
            mkdir -p cpusbind_nvme_fio_log
        else
            mkdir -p cpusbind_nvme_fio_log
        fi
        local -a pids=()
        for dev in $(cat nvme_symbol_set)
        do
            nohup "$CPWD/nvme_raw_fio_test_with_cpubind.sh" "$dev" &>/dev/null &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do
            wait "$pid" || echo "WARNING: child failed: $pid" >&2
        done
        sleep 30
        move_glob "ssd_nvme*_*.log" "cpusbind_nvme_fio_log"
        cp multi_disk_log_filter.sh nvme_symbol_set cpusbind_nvme_fio_log
        cd cpusbind_nvme_fio_log
        ./multi_disk_log_filter.sh -N
        cd "$CPWD" || { echo "ERROR: failed to enter $CPWD" >&2; exit 1; }
    fi
}

nvme_parallel_fio_stress_test()
{
    # multi nvme ssd fio test
    if [ -s nvme_symbol_set ];then
        if [ -d nvme_fio_stress_log ];then
            mv nvme_fio_stress_log "nvme_fio_stress_log_$(date +%Y%m%d%H%M%S)"
            mkdir -p nvme_fio_stress_log
        else
            mkdir -p nvme_fio_stress_log
        fi
        local -a pids=()
        for dev in $(cat nvme_symbol_set)
        do
            nohup "$CPWD/ssd_fio_stress_test.sh" "$dev" &>/dev/null &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do
            wait "$pid" || echo "WARNING: child failed: $pid" >&2
        done
        sleep 30
        move_glob "ssd_nvme*_stress.log" "nvme_fio_stress_log"
    fi
}

raid_parallel_fio_test()
{
    # multi raids combined with sata ssd fio test
    if [ -s raid_symbol_set ];then
        if [ -d ssd_raid_fio_log ];then
            mv ssd_raid_fio_log "ssd_raid_fio_log_$(date +%Y%m%d%H%M%S)"
	        mkdir -p ssd_raid_fio_log
        else
            mkdir -p ssd_raid_fio_log
        fi
        local -a pids=()
        for dev in $(cat raid_symbol_set)
        do
            nohup "$CPWD/ssd_raw_fio_test.sh" "$dev" &>/dev/null &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do
            wait "$pid" || echo "WARNING: child failed: $pid" >&2
        done
        sleep 30
        move_glob "raid_sd*_*.log" "ssd_raid_fio_log"
        cp multi_disk_log_filter.sh raid_symbol_set ssd_raid_fio_log
        cd ssd_raid_fio_log
        ./multi_disk_log_filter.sh -S
        cd "$CPWD" || { echo "ERROR: failed to enter $CPWD" >&2; exit 1; }
    fi    
}

ssd_parallel_fio_test()
{
    # multi sata ssd fio test
    if [ -s ssd_symbol_set ];then
        if [ -d ssd_fio_log ];then
            mv ssd_fio_log "ssd_fio_log_$(date +%Y%m%d%H%M%S)"
            mkdir -p ssd_fio_log
        else
            mkdir -p ssd_fio_log
        fi
        local -a pids=()
        for dev in $(cat ssd_symbol_set)
        do
            nohup "$CPWD/ssd_raw_fio_test.sh" "$dev" &>/dev/null &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do
            wait "$pid" || echo "WARNING: child failed: $pid" >&2
        done
        sleep 30
        move_glob "ssd_sd*_*.log" "ssd_fio_log"
        cp multi_disk_log_filter.sh ssd_symbol_set ssd_fio_log
        cd ssd_fio_log
        ./multi_disk_log_filter.sh -S
        cd "$CPWD" || { echo "ERROR: failed to enter $CPWD" >&2; exit 1; }
    fi
}

ssd_parallel_fio_stress_test()
{
    # multi sata/sas ssd fio test
    if [ -s ssd_symbol_set ];then
        if [ -d ssd_fio_stress_log ];then
            mv ssd_fio_stress_log "ssd_fio_stress_log_$(date +%Y%m%d%H%M%S)"
            mkdir -p ssd_fio_stress_log
        else
            mkdir -p ssd_fio_stress_log
        fi
        local -a pids=()
        for dev in $(cat ssd_symbol_set)
        do
            nohup "$CPWD/ssd_fio_stress_test.sh" "$dev" &>/dev/null &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do
            wait "$pid" || echo "WARNING: child failed: $pid" >&2
        done
        sleep 30
        move_glob "ssd*_stress.log" "ssd_fio_stress_log"
    fi
}   

hdd_parallel_fio_test()
{
    # multi hdd fio test
    if [ -s hdd_symbol_set ];then
        if [ -d hdd_fio_log ];then
            mv hdd_fio_log "hdd_fio_log_$(date +%Y%m%d%H%M%S)"
            mkdir -p hdd_fio_log
        else
            mkdir -p hdd_fio_log
        fi
        local -a pids=()
        for dev in $(cat hdd_symbol_set)
        do
            nohup "$CPWD/hdd_raw_fio_test.sh" "$dev" &>/dev/null &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do
            wait "$pid" || echo "WARNING: child failed: $pid" >&2
        done
        sleep 30
        move_glob "hdd_sd*_*.log" "hdd_fio_log"
        cp multi_disk_log_filter.sh hdd_symbol_set hdd_fio_log
        cd hdd_fio_log
        ./multi_disk_log_filter.sh -H
        cd "$CPWD" || { echo "ERROR: failed to enter $CPWD" >&2; exit 1; }
    fi
} 

hdd_parallel_fio_stress_test()
{
    # multi sata/sas hdd fio stress test
    if [ -s hdd_symbol_set ];then
        if [ -d hdd_fio_stress_log ];then
            mv hdd_fio_stress_log "hdd_fio_stress_log_$(date +%Y%m%d%H%M%S)"
            mkdir -p hdd_fio_stress_log
        else
            mkdir -p hdd_fio_stress_log
        fi
        local -a pids=()
        for dev in $(cat hdd_symbol_set)
        do
            nohup "$CPWD/hdd_fio_stress_test.sh" "$dev" &>/dev/null &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do
            wait "$pid" || echo "WARNING: child failed: $pid" >&2
        done
        sleep 30
        move_glob "hdd*_stress.log" "hdd_fio_stress_log"
    fi
}

if [[ $# -eq 0 ]];then
    usage
fi
check_tool_installed
filter_ssd_hdd_nvme_set
ssd_cap_set

if [[ "${IS_NVME_PARALLEL}" == "true" ]]; then
    nvme_parallel_fio_test  
fi

if [[ "${IS_NVME_PARALLEL_WITH_CPUSBIND}" == "true" ]]; then
    nvme_parallel_fio_test_with_cpusbind
fi

if [[ "${IS_SSD_PARALLEL}" == "true" ]]; then
    ssd_parallel_fio_test
fi
	
if [[ "${IS_HDD_PARALLEL}" == "true" ]]; then
    hdd_parallel_fio_test
fi

if [[ "${IS_NVME_PARALLEL_STRESS}" == "true" ]]; then
    nvme_parallel_fio_stress_test
fi

if [[ "${IS_SSD_PARALLEL_STRESS}" == "true" ]]; then
    ssd_parallel_fio_stress_test
fi

if [[ "${IS_HDD_PARALLEL_STRESS}" == "true" ]]; then
    hdd_parallel_fio_stress_test
fi

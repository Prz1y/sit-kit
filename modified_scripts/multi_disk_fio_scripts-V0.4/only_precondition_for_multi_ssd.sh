#!/usr/bin/env bash
set -euo pipefail

CPWD="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$CPWD" || exit 1

path_to_fio="$(command -v fio 2>/dev/null || true)"
if [[ -z "$path_to_fio" ]];then
    echo "fio not found in PATH" >&2
    exit 1
fi

IO_ENGINE="libaio"

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

PARA_LINE1="-end_fsync=0 -group_reporting -direct=1 -ioengine=${IO_ENGINE} -thread -buffer_compress_percentage=0 -invalidate=1 \
-norandommap -randrepeat=0 -exitall"

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

ssd_fragment_sequence(){
    local dev="$1"
	#Full sequential write to let ssd be stable state before sequential test
	$path_to_fio --readwrite=write --bs=128k --iodepth=128 --numjobs=1 --loop=2 ${PARA_LINE1} --name="${dev}_write_fragment1" --filename="/dev/$dev" \
	| tee -a "ssd_${dev}_fragment1.log"
}

ssd_fragment_random(){
    local dev="$1"
	#Full random write to let ssd be stable state before random test
	$path_to_fio --readwrite=randwrite --bs=4k --iodepth=128 --numjobs=4 --runtime=6h --time_based ${PARA_LINE1} --filename="/dev/$dev" \
	--name="${dev}_randwrite_fragment2" | tee -a "ssd_${dev}_fragment2.log"
}

sata_ssd_precondition()
{
    # multi sata ssd precondition
    if [ -s ssd_symbol_set ];then
        if [ -d sata_precondition_log ];then
            mv sata_precondition_log "sata_precondition_log_$(date +%Y%m%d%H%M%S)"
            mkdir -p sata_precondition_log
        else
            mkdir -p sata_precondition_log
        fi
	# sequential precondition
        for dev in $(cat ssd_symbol_set)
        do
            ssd_fragment_sequence "$dev" &>"sata_precondition_log/${dev}_fragment1.log" &
        done
        wait
        sleep 30
        # random precondition
        for dev in $(cat ssd_symbol_set)
	do
            ssd_fragment_random "$dev" &>"sata_precondition_log/${dev}_fragment2.log" &
        done
        wait
        sleep 30

        move_glob "ssd_*_fragment1.log" "sata_precondition_log"
        move_glob "ssd_*_fragment2.log" "sata_precondition_log"
    fi
    cd "$CPWD" || exit 1
}

nvme_format()
{
    if [[ "${ALLOW_NVME_FORMAT:-0}" != "1" ]];then
        echo "Skip nvme format. Set ALLOW_NVME_FORMAT=1 to enable." >&2
        return 0
    fi
    for dev in $(cat nvme_symbol_set)
    do
        echo "[$(date '+%F %T')] nvme format /dev/$dev" >> "$CPWD/nvme_format_audit.log"
        nvme format "/dev/$dev"
    done
    cd "$CPWD" || exit 1
}

nvme_ssd_precondition()
{
    # multi nvme ssd precondition
    if [ -s nvme_symbol_set ];then
        nvme_format
        if [ -d nvme_precondition_log ];then
            mv nvme_precondition_log "nvme_precondition_log_$(date +%Y%m%d%H%M%S)"
            mkdir -p nvme_precondition_log
        else
            mkdir -p nvme_precondition_log
        fi
        # sequential precondition
        for dev in $(cat nvme_symbol_set)
        do
            ssd_fragment_sequence "$dev" &>"nvme_precondition_log/${dev}_fragment1.log" &
        done
        wait
        sleep 30
        # random precondition
        for dev in $(cat nvme_symbol_set)
        do
            ssd_fragment_random "$dev" &>"nvme_precondition_log/${dev}_fragment2.log" &
        done
        wait
        sleep 30
        move_glob "ssd_*_fragment1.log" "nvme_precondition_log"
        move_glob "ssd_*_fragment2.log" "nvme_precondition_log"
    fi
    cd "$CPWD" || exit 1
}

filter_ssd_hdd_nvme_set
sata_ssd_precondition
nvme_ssd_precondition

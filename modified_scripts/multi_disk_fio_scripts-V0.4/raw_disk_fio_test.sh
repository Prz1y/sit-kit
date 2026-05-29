#!/usr/bin/env bash
set -o pipefail
#*************************************************************************************#
# Author: zhouq32@chinatelecom.cn
# Modified in 11/16/2025 - fix a little bugs for precondition test
# nvme performance test with binding adjunctive numa node instead of all numa nodes
# binding numa node when precondition test
#*************************************************************************************#

IS_SSD_STRESS=false
IS_HDD_STRESS=false
IS_HDD_BASE_SEQ=false
IS_HDD_BASE_RAND=false
IS_SSD_BASE_SEQ=false
IS_SSD_BASE_RAND=false
IO_ENGINE=libaio
IS_NVME_BIND_CPUS_BASE_SEQ=false
IS_NVME_BIND_CPUS_BASE_RAND=false
FILE_SIZE=100%
CPWD="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$CPWD"
path_to_fio="$(command -v fio 2>/dev/null || true)"
if [[ -z "$path_to_fio" ]];then
    echo "fio not found in PATH" >&2
    exit 1
fi


usage(){
	echo "$0 [-s] [-e io_engine] [-v|V] [-h] [-b|B]  [-d dev_name] [-n|N]"
	echo "-h usage"
	echo "-s ssd stress test"
	echo "-S hdd stress test"
	echo "-e ioengine type , default type is libaio"
	echo "-b ssd raw device sequence write/read test"
	echo "-B ssd raw device random write/read test"
	echo "-d the device full path(raw device) ,such as /dev/sdx"
	echo "-v hdd raw device sequence write/read test"
	echo "-V hdd raw device random write/read test"
	echo "-n NVME SSD base sequence test with numa nodes of bind cpu socket"
	echo "-N NVME SSD base random test with numa nodes of bind cpu socket"
	echo "example:"
	echo "	ssd raw device base_test_sequence: $0 -d sdx -b &"
	echo "	ssd raw device base_test_random: $0 -d sdx -B &"
	echo "	nvme raw device base_test_sequence with cpus bind: $0 -d nvmexn1 -n &"
	echo "	nvme raw device base_test_random with cpus bind: $0 -d nvmexn1 -N &"
	echo "	hdd raw device base_test_sequence: $0 -d sdx -v &"
	echo "	hdd raw device base_test_random: $0 -d sdx -V &"
	echo "	ssd raw device stress test: $0 -d sdx -s &"
	exit
}

while getopts "hsSvVbBe:d:nN" arg
do
	case $arg in
		h)
		usage;;
		s)
		IS_SSD_STRESS=true;;
		S)
		IS_HDD_STRESS=true;;
		v)
		IS_HDD_BASE_SEQ=true;;
		V)
		IS_HDD_BASE_RAND=true;;
		b)
		IS_SSD_BASE_SEQ=true;;
		B)
		IS_SSD_BASE_RAND=true;;
		e)
		IO_ENGINE=${OPTARG};;
		d)
		DEV_LIST=${OPTARG};;
		n)
		IS_NVME_BIND_CPUS_BASE_SEQ=true;;
		N)
		IS_NVME_BIND_CPUS_BASE_RAND=true;;
	esac
done

PARA_LINE="-end_fsync=0 -group_reporting -direct=1 -ioengine=${IO_ENGINE} -thread -time_based -buffer_compress_percentage=0 -invalidate=1 \
-norandommap -randrepeat=0 -exitall -size=${FILE_SIZE}"

PARA_LINE1="-end_fsync=0 -group_reporting -direct=1 -ioengine=${IO_ENGINE} -thread -buffer_compress_percentage=0 -invalidate=1 \
-norandommap -randrepeat=0 -exitall"

get_nvmebind_all_numa_node()
{
    local nvme_block_symbol=$1
    local cpu_socket
    cpu_socket="$(grep -F -- "$nvme_block_symbol" cpu_numa_nvme_topo | awk '{print $1}' | sort -u)"
    local nvmebind_all_numa_node
    nvmebind_all_numa_node="$(grep -F -- "$cpu_socket" cpu_numa_nvme_topo | awk '{print $2}' | awk -F"=" '{print $2}' | sort -u | xargs | sed 's/[ ]/,/g')"
    echo "$nvmebind_all_numa_node"
}

get_nvmebind_node_id()
{
    local nvme_block_symbol=$1
    local nvmebind_numa_node
    nvmebind_numa_node="$(grep -F -- "$nvme_block_symbol" cpu_numa_nvme_topo | awk '{print $2}' | awk -F"=" '{print $2}')"
    echo "$nvmebind_numa_node"
}

ssd_precondition_sequence()
{
    if [ -s sata_ssd_cap ] && [ ! -f nvme_cap ];then
        if [[ $(cat sata_ssd_cap |sort -u |wc -l) -ne 1 ]];then
            echo "sata ssd capacity is nonuniqueness, multi ssds performane test requires that all ssds have same capacity"
            exit 1
        else
        #Full sequential write to let sata ssd be stable state before sequential test without binding cpu cores
        "$path_to_fio" --readwrite=write --bs=128k --iodepth=128 --numjobs=1 --loop=2 ${PARA_LINE1} --filename="/dev/${DEV_LIST}" \
		--name="${DEV_LIST}_write_precondition" | tee -a "ssd_${DEV_LIST}_write_precondition.log"
        fi
    fi

    if [ -s nvme_cap ];then
        if [[ $(cat nvme_cap |sort -u |wc -l) -ne 1 ]];then
            echo "nvme capacity is nonuniqueness, multi ssds performane test requires that all ssds have same capacity"
            exit 1
        else
            local bind_numa_node
            bind_numa_node="$(get_nvmebind_node_id "$DEV_LIST")"
            local numa_mem_opt=""
            if [[ "${ENABLE_NUMA_MEMBIND:-0}" == "1" ]];then
                numa_mem_opt="-m $bind_numa_node"
            fi
            numactl -N "$bind_numa_node" $numa_mem_opt "$path_to_fio" --readwrite=write --bs=128k --iodepth=128 --numjobs=1 --loop=2 ${PARA_LINE1} --filename="/dev/${DEV_LIST}" \
			--name="${DEV_LIST}_write_precondition" | tee -a "ssd_${DEV_LIST}_write_precondition.log"
        fi
    fi
}

ssd_precondition_random()
{
    local bs="$1"
    local runtime=""

    if [ -s sata_ssd_cap ] && [ ! -f nvme_cap ];then
        if [[ $(cat sata_ssd_cap |sort -u |wc -l) -ne 1 ]];then
            echo "sata ssd capacity is nonuniqueness, multi ssds performane test requires that all ssds have same capacity"
            exit 1
        else
            satassdCap=$(cat sata_ssd_cap |sort -u)
            if [[ $satassdCap == 240GB ]] || [[ $satassdCap == 480GB ]] || [[ $satassdCap == 960GB ]] || [[ $satassdCap == 1.92TB ]] ;then
                runtime=6h
            else
                runtime=12h
            fi
        fi
        "$path_to_fio" --readwrite=randwrite --bs="$bs" --iodepth=128 --numjobs=4 --runtime="$runtime" --time_based ${PARA_LINE1} --filename="/dev/${DEV_LIST}" \
	    --name="${DEV_LIST}_${bs}_randwrite_precondition" | tee -a "ssd_${DEV_LIST}_randwrite_precondition.log"
    fi

    if [ -s nvme_cap ];then
        if [[ $(cat nvme_cap |sort -u |wc -l) -ne 1 ]];then
            echo "nvme capacity is nonuniqueness, multi ssds performane test requires that all ssds have same capacity"
            exit 1
        else
            nvmeCap=$(cat nvme_cap |sort -u)
            if [[ $(echo "$nvmeCap <= 7.68" |bc) -eq 1 ]];then
                runtime=6h
            elif [[ $(echo "$nvmeCap > 7.68 &&  $nvmeCap <= 15.36" |bc) -eq 1 ]];then
                runtime=8h
            elif [[ $(echo "$nvmeCap > 15.36 && $nvmeCap <= 30.72" |bc) -eq 1 ]];then
                runtime=16h
            elif [[ $(echo "$nvmeCap > 30.72" |bc) -eq 1 ]];then
                runtime=24h
            fi
        fi
        local bind_numa_node
        bind_numa_node="$(get_nvmebind_node_id "$DEV_LIST")"
        local numa_mem_opt=""
        if [[ "${ENABLE_NUMA_MEMBIND:-0}" == "1" ]];then
            numa_mem_opt="-m $bind_numa_node"
        fi
        numactl -N "$bind_numa_node" $numa_mem_opt "$path_to_fio" --readwrite=randwrite --bs="$bs" --iodepth=128 --numjobs=4 --runtime="$runtime" --time_based ${PARA_LINE1} --filename="/dev/${DEV_LIST}" \
            --name="${DEV_LIST}_${bs}_randwrite_precondition" | tee -a "ssd_${DEV_LIST}_randwrite_precondition.log"
    fi
}

cpubind_nvme_base_test_sequence_with_numa_constraint()
{
	rm -f ssd_${DEV_LIST}_write_precondition.log ssd_${DEV_LIST}_read.log ssd_${DEV_LIST}_write.log
	#sequence precondition
	ssd_precondition_sequence
	wait

	local bind_node_id=$(get_nvmebind_node_id $DEV_LIST)
	local numa_mem_opt=""
	if [[ "${ENABLE_NUMA_MEMBIND:-0}" == "1" ]];then
		numa_mem_opt="-m $bind_node_id"
	fi
	for RW in read write
	do
		for BS in 128k
		do
			for THREADS in 1 
			do
				for depth in 32 64 128 256 512
				do
					numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=${BS} --numjobs=${THREADS} --iodepth=${depth} --ramp_time=60s \
					--runtime=300s ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${RW}_${BS}_${THREADS}_${depth} | tee -a ssd_${DEV_LIST}_${RW}.log
					sleep 30s
				done
			done
		done

		for BS in 4k 64k 256k 1m
		do
			for THREADS in 2
			do
				for depth in 32
				do
					numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=${BS} --numjobs=${THREADS} --iodepth=${depth} --ramp_time=60s \
					--runtime=300s ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${RW}_${BS}_${THREADS}_${depth} | tee -a ssd_${DEV_LIST}_${RW}.log
					sleep 30s
				done
			done
		done
	done
}

cpubind_nvme_base_test_random_with_numa_constraint()
{
	rm -f ssd_${DEV_LIST}_randwrite_precondition.log ssd_${DEV_LIST}_randread.log ssd_${DEV_LIST}_randwrite.log
	#4k randwrite precondition
	ssd_precondition_random 4k
	wait

	local bind_node_id=$(get_nvmebind_node_id $DEV_LIST)
	local numa_mem_opt=""
	if [[ "${ENABLE_NUMA_MEMBIND:-0}" == "1" ]];then
		numa_mem_opt="-m $bind_node_id"
	fi
	for RW in randread randwrite
	do
		local nj=1
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=1 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_1 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=32 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_32 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s	
		
		local nj=2
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=32 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_32 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=256 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_256 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		
		local nj=4
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=32 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_32 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=64 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_64  | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		
		local nj=8		
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=1 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_1 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=32 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_32 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=64 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_64 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=256 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_256 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		
		local nj=16
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=4k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=64 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_${nj}_64 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done

	#8k randwrite precondition
	ssd_precondition_random 8k
	wait		
	for RW in randread randwrite
	do
		local nj=1
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=8k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=32 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_${nj}_32 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		
		local nj=4
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=8k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=64 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_${nj}_64 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		
		local nj=8
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=8k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=1 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_${nj}_1 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=8k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=32 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_${nj}_32 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
   		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=8k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=64 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_${nj}_64 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done
		
	#64k randwrite precondition
	ssd_precondition_random 64k
	wait
	for RW in randread randwrite
	do
		local nj=2
   		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=64k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=32 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_64k_${nj}_32 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done

	#128k randwrite precondition
	ssd_precondition_random 128k  
	wait
	for RW in randread randwrite
	do
		local nj=2
   		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=128k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=64 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_128k_${nj}_64 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done
	
	#256k randwrite precondition
	ssd_precondition_random 256k 
	wait
	for RW in randread randwrite
	do
		local nj=2
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=256k --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=32 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_256k_${nj}_32 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done

	#1m randwrite precondition
	ssd_precondition_random 1m 
	wait
	for RW in randread randwrite
	do
		local nj=2
		numactl -N $bind_node_id $numa_mem_opt $path_to_fio --readwrite=${RW} --bs=1m --ramp_time=60s --runtime=300s --numjobs=$nj --iodepth=32 ${PARA_LINE} \
		--filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_1m_${nj}_32 | tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done
}

ssd_base_test_sequence()
{
	rm -f ssd_${DEV_LIST}_write_precondition.log ssd_${DEV_LIST}_read.log ssd_${DEV_LIST}_write.log
	#sequence precondition
	ssd_precondition_sequence
	wait
	
	for RW in read write
	do
		for BS in 128k
		do
			for THREADS in 1 
			do
				for depth in 32 64 128 256 512
				do
					$path_to_fio --readwrite=${RW} --bs=${BS} --numjobs=${THREADS} --iodepth=${depth} --runtime=300s ${PARA_LINE} --filename=/dev/${DEV_LIST} \
					--name=${RW}_${BS}_${THREADS}_${depth} | tee -a ssd_${DEV_LIST}_${RW}.log
					sleep 30s
				done
			done
		done
		
		for BS in 1m 256k 64k 4k
		do
			for THREADS in 2
			do
				for depth in 32
				do
					$path_to_fio --readwrite=${RW} --bs=${BS} --numjobs=${THREADS} --iodepth=${depth} --runtime=300s ${PARA_LINE} --filename=/dev/${DEV_LIST} \
					--name=${RW}_${BS}_${THREADS}_${depth} | tee -a ssd_${DEV_LIST}_${RW}.log
					sleep 30s
				done
			done
		done				
	done
}

ssd_base_test_random()
{
    rm -f ssd_${DEV_LIST}_randwrite_precondition.log ssd_${DEV_LIST}_randread.log ssd_${DEV_LIST}_randwrite.log
	#4k randwrite precondition
	ssd_precondition_random 4k
	wait	
	for RW in randread randwrite
	do		
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=1 --iodepth=1 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_1_1  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s 
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=1 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_1_32  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s	
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=2 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_2_32  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=2 --iodepth=256 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_2_256  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=4 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_4_32  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=4 --iodepth=64 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_4_64  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=8 --iodepth=1 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_8_1  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s	
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=8 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_8_32 \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=8 --iodepth=64 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_8_64  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=8 --iodepth=256 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_8_256  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=16 --iodepth=64 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_16_64  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done

	#8k randwrite precondition
	ssd_precondition_random 8k
	wait		
	for RW in randread randwrite
	do
   		$path_to_fio --readwrite=${RW} --bs=8k --runtime=300s --numjobs=1 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_1_32  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=8k --runtime=300s --numjobs=4 --iodepth=64 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_4_64  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=8k --runtime=300s --numjobs=8 --iodepth=1 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_8_1  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
		$path_to_fio --readwrite=${RW} --bs=8k --runtime=300s --numjobs=8 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_8_32  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
   		$path_to_fio --readwrite=${RW} --bs=8k --runtime=300s --numjobs=8 --iodepth=64 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_8k_8_64  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done
		
	#64k randwrite precondition
	ssd_precondition_random 64k
	wait
	for RW in randread randwrite
	do
   		$path_to_fio --readwrite=${RW} --bs=64k --runtime=300s --numjobs=2 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_64k_2_32  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done


	#128k randwrite precondition
	ssd_precondition_random 128k  
	wait
	for RW in randread randwrite
	do
   		$path_to_fio --readwrite=${RW} --bs=128k --runtime=300s --numjobs=2 --iodepth=64 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_128k_2_64  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done
	
	#256k randwrite precondition
	ssd_precondition_random 256k 
	wait
	for RW in randread randwrite
	do
		$path_to_fio --readwrite=${RW} --bs=256k --runtime=300s --numjobs=2 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_256k_2_32  \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done

	#1m randwrite precondition
	ssd_precondition_random 1m 
	wait
	for RW in randread randwrite
	do
		$path_to_fio --readwrite=${RW} --bs=1m --runtime=300s --numjobs=2 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_1m_2_32 \
		| tee -a ssd_${DEV_LIST}_${RW}.log
		sleep 30s
	done
}


hdd_base_test_sequence()
{
    rm -f hdd_${DEV_LIST}_read.log hdd_${DEV_LIST}_write.log
	# Sequential write/read test
	for RW in write read
	do
		$path_to_fio --readwrite=${RW} --bs=4k --runtime=300s --numjobs=2 --iodepth=32 ${PARA_LINE} --offset_increment=80G --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_4k_2_32  \
		| tee -a hdd_${DEV_LIST}_${RW}.log
		sleep 30s
		
		$path_to_fio --readwrite=${RW} --bs=64k --runtime=300s --numjobs=2 --iodepth=32 ${PARA_LINE} --offset_increment=80G --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_64k_2_32  \
		| tee -a hdd_${DEV_LIST}_${RW}.log
		sleep 30s

		$path_to_fio --readwrite=${RW} --bs=256k --runtime=300s --numjobs=2 --iodepth=32 ${PARA_LINE} --offset_increment=80G --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_256k_2_32  \
		| tee -a hdd_${DEV_LIST}_${RW}.log
		sleep 30s

		$path_to_fio --readwrite=${RW} --bs=1m --runtime=300s --numjobs=1 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_1m_1_32  \
		| tee -a hdd_${DEV_LIST}_${RW}.log
		sleep 30s

		$path_to_fio --readwrite=${RW} --bs=1m --runtime=300s --numjobs=2 --iodepth=32 ${PARA_LINE} --offset_increment=80G --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_${RW}_1m_2_32  \
		| tee -a hdd_${DEV_LIST}_${RW}.log
		sleep 30s
	done
}

hdd_base_test_random()
{
    rm -f hdd_${DEV_LIST}_randread.log ssd_${DEV_LIST}_randwrite.log
	# Randrom write test with different io pattern       
	$path_to_fio --readwrite=randwrite --bs=4k --ramp_time=10s --runtime=300s --numjobs=1 --iodepth=1 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_randwrite_4k_1_1  \
	| tee -a hdd_${DEV_LIST}_randwrite.log
	sleep 30s

	for BS in 4k 64k 256k 1m
	do
		for THREADS in 2
		do
			for depth in 32
			do
				$path_to_fio --readwrite=randwrite --bs=${BS} --ramp_time=10s --runtime=300s --numjobs=${THREADS} --iodepth=${depth} ${PARA_LINE} --filename=/dev/${DEV_LIST} \
				--name=${DEV_LIST}_randwrite_${BS}_${THREADS}_${depth} | tee -a hdd_${DEV_LIST}_randwrite.log
			    sleep 30s
			done
		done
	done


	# Random read test with different io pattern
	for BS in 4k
	do
		for THREADS in 1
		do
			for depth in 1 4 8 16 32
			do	
				$path_to_fio --readwrite=randread --bs=${BS} --ramp_time=10s --runtime=300s --numjobs=${THREADS} --iodepth=${depth} ${PARA_LINE} --filename=/dev/${DEV_LIST} \
				--name=${DEV_LIST}_randread_${BS}_${THREADS}_${depth} | tee -a hdd_${DEV_LIST}_randread.log
				sleep 30s
			done
		done
	done

	$path_to_fio --readwrite=randread --bs=8k --ramp_time=10s --runtime=300s --numjobs=1 --iodepth=1 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_randread_8k_1_1  \
	| tee -a hdd_${DEV_LIST}_randread.log
	sleep 30s
	
	$path_to_fio --readwrite=randread --bs=8k --ramp_time=10s --runtime=300s --numjobs=1 --iodepth=32 ${PARA_LINE} --filename=/dev/${DEV_LIST} --name=${DEV_LIST}_randread_8k_1_32  \
	| tee -a hdd_${DEV_LIST}_randread.log


	for BS in 4k 64k 256k 1m
	do
		for THREADS in 2
		do
			for depth in 32
			do
				$path_to_fio --readwrite=randread --bs=${BS} --ramp_time=10s --runtime=300s --numjobs=${THREADS} --iodepth=${depth} ${PARA_LINE} --filename=/dev/${DEV_LIST} \
				--name=${DEV_LIST}_randread_${BS}_${THREADS}_${depth} | tee -a hdd_${DEV_LIST}_randread.log
				sleep 30s
			done
		done
	done
}

ssd_stress()
{
    rm -f ssd_${DEV_LIST}_randwrite_precondition.log ssd_${DEV_LIST}*stress.log
	#sequence precondition
	ssd_precondition_sequence
	wait
	#128k read stress for 2h
	$path_to_fio --readwrite=read --bs=128k --numjobs=1 --iodepth=128 --runtime=2h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_128k_read_stress | tee -a ssd_${DEV_LIST}_128k_read_stress.log
	sleep 30s
	#128k write stress for 10h
	$path_to_fio --readwrite=write --bs=128k --numjobs=1 --iodepth=128 --runtime=10h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_128k_write_stress | tee -a ssd_${DEV_LIST}_128k_write_stress.log
	sleep 30s
	#4k randwrite precondition
	ssd_precondition_random 4k
	wait
	#4k randread stress for 2h
	$path_to_fio --readwrite=randread --bs=4k --numjobs=8 --iodepth=128 --runtime=2h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_4k_randwrite_stress | tee -a ssd_${DEV_LIST}_4k_randread_stress.log
	sleep 30s
	#4k randwrite stress for 10h
	$path_to_fio --readwrite=randwrite --bs=4k --numjobs=8 --iodepth=128 --runtime=10h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_4k_randwrite_stress | tee -a ssd_${DEV_LIST}_4k_randwrite_stress.log
	sleep 30s
	#4k 70% mixrw stress for 2h
	$path_to_fio --readwrite=randrw --rwmixread=70 --bs=4k --numjobs=8 --iodepth=128 --runtime=2h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_4k_randwrite_stress | tee -a ssd_${DEV_LIST}_4k_mixrw_stress.log
	sleep 30s   	
}

hdd_stress()
{
    rm -f hdd_${DEV_LIST}*stress.log
	#128k read stress for 8h
	$path_to_fio --readwrite=read --bs=128k --numjobs=1 --iodepth=128 --runtime=8h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_128k_read_stress | tee -a hdd_${DEV_LIST}_128k_read_stress.log
	sleep 30s
	#128k write stress for 8h
	$path_to_fio --readwrite=write --bs=128k --numjobs=1 --iodepth=128 --runtime=8h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_128k_write_stress | tee -a hdd_${DEV_LIST}_128k_write_stress.log
	sleep 30s
	#4k randread stress for 8h
	$path_to_fio --readwrite=randread --bs=4k --numjobs=4 --iodepth=64 --runtime=8h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_4k_randwrite_stress | tee -a hdd_${DEV_LIST}_4k_randread_stress.log
	sleep 30s
	#4k randwrite stress for 8h
	$path_to_fio --readwrite=randwrite --bs=4k --numjobs=4 --iodepth=64 --runtime=8h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_4k_randwrite_stress | tee -a hdd_${DEV_LIST}_4k_randwrite_stress.log
	sleep 30s
	#4k 70% mixrw stress for 8h
	$path_to_fio --readwrite=randrw --rwmixread=70 --bs=4k --numjobs=4 --iodepth=64 --runtime=8h ${PARA_LINE} --filename=/dev/${DEV_LIST} \
	--name=${DEV_LIST}_4k_randwrite_stress | tee -a hdd_${DEV_LIST}_4k_mixrw_stress.log
	sleep 30s   	
}


if [[ $# -eq 0 ]];then
    usage
fi

if ${IS_SSD_BASE_SEQ};then
    ssd_base_test_sequence
fi

if ${IS_SSD_BASE_RAND};then
    ssd_base_test_random
fi

if ${IS_NVME_BIND_CPUS_BASE_SEQ};then
    cpubind_nvme_base_test_sequence_with_numa_constraint
fi

if ${IS_NVME_BIND_CPUS_BASE_RAND};then
    cpubind_nvme_base_test_random_with_numa_constraint
fi

if ${IS_HDD_BASE_SEQ};then
    hdd_base_test_sequence
fi

if ${IS_HDD_BASE_RAND};then
    hdd_base_test_random
fi

if ${IS_SSD_STRESS};then
    ssd_stress
fi

if ${IS_HDD_STRESS};then
    hdd_stress
fi

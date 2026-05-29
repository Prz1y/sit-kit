1.<precondition>
  make sure libaio,fio,nvme-cli,smartmontools installed before test

2.base on fio test script - raw_disk_fio_test.sh

3.SATA SSD-single block fio test
  <running in foreground>
  #./ssd_raw_fio_test.sh <sata_ssd_symbol>
  example:#./ssd_raw_fio_test.sh sdb
  <running in background>
  example:#nohup &>/dev/null ./ssd_raw_fio_test.sh sdb &

4.NVME SSD-single block fio test
  <running in foreground>
  #./ssd_raw_fio_test.sh <nvme_ssd_symbol>
  example:#./ssd_raw_fio_test.sh nvme1n1
  <running in background>
  example:#nohup &>/dev/null ./ssd_raw_fio_test.sh nvme1n1 &

5.HDD-single block fio test
  <running in foreground>
  #./hdd_raw_fio_test.sh <hdd_symbol>
  example:#./hdd_raw_fio_test.sh sdb
  <running in background>
  example:#nohup &>/dev/null ./hdd_raw_fio_test.sh sdb &

6. SSD-single block stress test
  <running in foreground>
  #./hdd_raw_fio_test.sh <ssd_symbol>
  example:#./ssd_fio_stress_test.sh sdb
  example:#./ssd_fio_stress_test.sh nvme0n1
  <running in background>
  example:#nohup &>/dev/null ./ssd_fio_stress_test.sh sdb &
  example:#nohup &>/dev/null ./ssd_fio_stress_test.sh nvme0n1 &

7.SATA SSD-multi block fio test
  <running in foreground>
  #./run_parallel_disk.sh -S
  <running in background>
  #nohup &>/dev/null ./run_parallel_disk.sh -S &

8.NVME SSD-multi block fio test
  <running in foreground>
  #./run_parallel_disk.sh -N
  <running in background>
  #nohup &>/dev/null ./run_parallel_disk.sh -N &

9.HDD-multi block fio test
  <running in foreground>
  #./run_parallel_disk.sh -H
  <running in background>
  #nohup &>/dev/null ./run_parallel_disk.sh -H &

10.SATA SSD-multi block fio stress test
  <running in foreground>
  #./run_parallel_disk.sh -s
  <running in background>
  #nohup &>/dev/null ./run_parallel_disk.sh -s &

11.NVME SSD-multi block fio stress test
  <running in foreground>
  #./run_parallel_disk.sh -n
  <running in background>
  #nohup &>/dev/null ./run_parallel_disk.sh -n &

12.HDD-multi block fio stress test
  <running in foreground>
  #./run_parallel_disk.sh -d
  <running in background>
  #nohup &>/dev/null ./run_parallel_disk.sh -d &

13.NVME SSD-multi block fio test with binding cpus automatically adjusted to given numjobs
  #nohup &>/dev/null ./cpubind_for_running_parallel_nvme.sh &

14.disk fio filtered log saved as filter_multi_[nvme|ssd|hdd]*.csv file in [nvme|ssd|hdd|]_fio_log directory

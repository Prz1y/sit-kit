# SIT 测试脚本

这个README很大概率不会经常更新，因为我真懒得写，主要用途就是我自己直接git clone到被测机上执行测试。
下面的内容是把我自己造出来的轮子喂给ai帮我总结的。

This README likely won't be updated often because I'm too lazy to write it. Its main purpose is to allow me to git clone these tools directly onto a test machine for execution.
The content below was summarized by an AI based on the scripts I created.

**Author:** Prz1y  
**License:** MIT

---

## 中文说明

### 性能准入套件 (nvme_cloud_qual_suite_*.sh)
这是最核心的工具，专为云厂商准入级别设计，分中英文版。

* 全自动测试：跑完顺序、随机、混合读写及 QoS 一致性的性能矩阵（涵盖各种 BS 和 QD），并内置全盘安全擦除与稳态预处理。
* 双轨测试模式：支持 single（单盘全矩阵深度遍历，用于极限摸底）与 multi（多盘并发定向抽样，用于批量一致性验证）模式。
* 智能 NUMA 绑定：底层自动侦测硬盘物理归属节点，智能绑定测试进程，彻底规避多盘高压并发时的 PCIe 跨路带宽衰减。
* 报表直出：跑完后会调用 Python 引擎自动生成制式 Excel 交付报表，单位自动换算（MB/s, us），直接看 IOPS、带宽和长尾时延。
* 健康自检：测试全程防串扰对齐，结束后自动解析 dmesg，排查底层是否有 PCIe Bus Error 或 I/O Timeout 异常。
* 注意与依赖：
  * 环境里需要安装 fio、nvme-cli、ipmitool、numactl 和 tmux。
  * 需要 Python3 环境，且必须安装 pandas 和 openpyxl 库（pip3 install pandas openpyxl）。
  * 执行提示：稳态测试耗时极长，绝对禁止在常规 SSH 终端直连运行，务必在 tmux 或后台会话中挂起执行。

### 暴力热插拔验证 (`nvme_hotplug_unified.sh`)
- **功能**：模拟 Surprise Removal（直接拔盘）。
- **流程**：脚本会带你一步步操作，先写数据记下 MD5，然后提醒你拔盘、插盘，最后自动检查盘能不能认回来，数据有没有损坏。

### 安全擦除审计 (`nvme_secure_erase_test.sh`)
- **功能**：验证 `nvme format` 到底有没有把数据清干净。
- **原理**：执行完格式化后，脚本会对全盘进行 Hex Dump 扫描，如果发现任何非 0 数据就会报错。

### 槽位上/下电 (`nvme_slot_power_test.sh`)
- **功能**：不需要手动拔盘，直接通过 PCI 槽位的 power 接口切断和恢复供电。
- **用途**：用于测试 SSD 在反复掉电重启过程中的初始化稳定性。

### 驱动加载压力 (`nvme_driver_visible_check.sh`)
- **功能**：循环执行 `modprobe` 卸载和加载 nvme 驱动。
- **用途**：检查内核日志里是否有识别错误。

### PPU / AI 监控与压测脚本
#### 硬件状态实时采集 (`collect_ppu_monitor.sh`)
- **依赖**：`ppudbg` 命令。
- **功能**：同时对多个设备（默认 ID 0 和 1）进行后台监控。
- **日志**：会自动把 Stress (压力)、Power (功耗)、ICN (内部互联) 和 Video (视频处理) 的实时信息分别记录到不同的日志文件中。

#### 自动化压测循环 (`trace_player_autorun.sh`)
- **依赖**：`trace_player` 执行程序。
- **功能**：按照设定的总时间（比如 30000 秒）循环跑指定的测试流（`multi_stream.txt`）。
- **用途**：模拟长时间的高负载业务流，检查设备在持续运行下的表现。

---

## English Description

### Performance Qualification Suite (`nvme_cloud_qual_suite_*.sh`)
- **Description**: The core tool of this repo, available in both Chinese and English versions.
- **Function**: Fully automates a performance matrix covering sequential, random, and mixed R/W across various Block Sizes (BS) and Queue Depths (QD).
- **Reporting**: Automatically invokes a Python engine to generate Excel reports, providing clear metrics for IOPS, Bandwidth, and Latency.
- **Note**: Requires Python 3 with `pandas` and `openpyxl` libraries installed.

### Surprise Hotplug Validation (`nvme_hotplug_unified.sh`)
- **Function**: Simulates Surprise Removal (physically pulling the drive without notification).
- **Workflow**: The script guides you through a step-by-step process: it writes data and records MD5 checksums, prompts you to remove and re-insert the drive, and then automatically verifies if the drive is recognized and if data integrity has been maintained.

### Secure Erase Audit (`nvme_secure_erase_test.sh`)
- **Function**: Verifies whether `nvme format` actually wipes all data completely.
- **Principle**: After performing a format, the script executes a full-disk Hex Dump scan. It will report an error if any non-zero data is detected.

### Slot Power Cycle Test (`nvme_slot_power_test.sh`)
- **Function**: Cycles power directly via the PCI slot's power interface (no manual pulling required).
- **Purpose**: Used to test the initialization stability of the SSD during repeated power-loss and reboot cycles.

### Driver Load Stress Test (`nvme_driver_visible_check.sh`)
- **Function**: Repeatedly unloads and reloads the nvme driver using `modprobe`.
- **Purpose**: Checks kernel logs (dmesg) for identification errors or initialization failures during driver stress.

### PPU / AI Monitoring & Stress Scripts
#### Real-time Hardware Status Collection (`collect_ppu_monitor.sh`)
- **Dependency**: Requires the `ppudbg` command.
- **Function**: Performs background monitoring of multiple devices simultaneously (default IDs 0 and 1).
- **Logging**: Automatically records real-time information for Stress, Power, ICN (Interconnect), and Video processing into separate log files.

#### Automated Stress Test Loop (`trace_player_autorun.sh`)
- **Dependency**: Requires the `trace_player` executable.
- **Function**: Runs specified test streams (`multi_stream.txt`) in a loop for a predefined duration (e.g., 30,000 seconds).
- **Purpose**: Simulates long-term, high-load business traffic to check device performance and stability under continuous operation.

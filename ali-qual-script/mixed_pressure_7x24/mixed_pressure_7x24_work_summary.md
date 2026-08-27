# mixed_pressure_7x24 Work Summary

> Purpose: handoff context for another model. This document records the actual work, verification evidence, scope decisions, and remaining execution limitations.
>
> Date: 2026-08-27

## 1. Project Context

- Repository: `sit-kit`
- Branch: `test/mixed_pressure-review-fixes`
- Previous HEAD before this work: `657ebb7`
- Target script: `ali-qual-script/mixed_pressure_7x24/mixed_pressure_7x24.sh`
- Related files changed:
  - `ali-qual-script/mixed_pressure_7x24/mixed_pressure.conf.example`
  - `ali-qual-script/mixed_pressure_7x24/mixed_pressure_7x24_usage.md`
- The three target files are uncommitted. Do not stage or revert unrelated modified files in the repository.
- No commit or push was performed in this round.

## 2. Accepted Test Scope

The official requirement is a 7x24-hour mixed-pressure test:

- CPU pressure on all logical cores.
- Memory pressure at approximately 90% of available memory.
- fio ext4 filesystem pressure with 50% read and 50% write.
- Monitor CPU frequency, memory bandwidth, temperature, power, and system logs where the platform supports them.
- PASS evidence: no crash/hang, required duration reached, no throttle/anomaly evidence, and clean logs.

Explicitly out of scope:

- No iperf/network test in this script.
- No GPU test in this script.
- fio version validation was already accepted as working.
- No cgroup/process-supervisor redesign.
- No requirement to make every optional monitor available on platforms that do not expose the hardware interface.

## 3. Implemented Changes

### Disk and filesystem safety

- `SYSTEM_DISKS` is mandatory and configured explicitly; automatic system-disk detection and the `/dev/sda` fallback were removed.
- System-disk aliases and partitions are resolved to all underlying physical disks before comparison.
- `FIO_DISKS` must identify whole physical disks, not partitions or LVM devices.
- Existing filesystem signatures on the disk and its partitions are detected.
- Existing ext4 reuse requires explicit `ALLOW_EXISTING_FS=true`.
- Unsupported or existing filesystems are not silently reformatted.
- Disk preparation checks signatures fail-closed when `lsblk`/`blkid` cannot provide reliable data.
- Existing partition tables are backed up before repartitioning where possible.
- Partition-table rollback failure is logged and leaves a persistent cleanup-failure marker.
- New filesystem mounts use a generated mountpoint, record filesystem UUID, and verify source/UUID before unmounting.
- A pending mount record is written before mount, reducing the chance of an untracked mount after an interruption.

### Process lifecycle and concurrency

- Start/stop operations use an atomic directory lock with owner PID and `/proc` starttime.
- Stale lock takeover is fail-closed and guarded against concurrent recovery.
- PID records use `pid starttime`, not PID alone.
- Zombie processes are not treated as running.
- PID records are written through temporary files and atomic `mv`.
- CPU, VM, fio, guardian, and monitor launch failures are treated as failures instead of merely logged.
- VM worker PID records use `.pid_vm_<pid>` and are now consumed consistently by status and stop.
- Stop uses identity-checked process-tree termination, including a starttime snapshot for descendants.
- The guardian is stopped before pressure processes to avoid classifying intentional stop as a crash.
- A residual `START_FLAG` or `.cleanup_failed` blocks a new run instead of allowing state/log overwrite.
- An old `start` process checks run ownership before automatic stop and its `EXIT` cleanup path.
- Signals received after swap handling begins can enter cleanup because `START_FLAG` is created before setup.

### Swap handling

- Original swap state is captured atomically.
- `swapoff -a` failure, or a successful command that leaves swap enabled, aborts startup and attempts restoration.
- Restoration disables unexpected extra swap devices, re-enables the original set, and verifies the final set.
- Swap state transitions are recorded as `RECORDING`, `PENDING`, `DISABLED`, `PASS`, `FAIL`, or `SKIP`.
- Swap restoration failure prevents the run from being marked cleanly stopped.

### fio and pressure timing

- fio result files are tracked through a per-run result list instead of a global glob.
- Empty state-file lines are ignored.
- Missing fio results are explicitly reported.
- Planned stop is distinguished from a fio exit-code failure; a planned stop without an exit record is reported as uncollected, not silently omitted.
- fio result writes use a temporary file and atomic rename.
- Block fio refuses to force a 1 GB/job workload onto insufficient free space.
- fio runtime includes the configured steady-state wait and startup margin, so fio does not finish before the canonical CPU/memory pressure window.
- fio CPU and RSS accounting includes the tracked process tree rather than only the shell wrapper.
- CPU and VM liveness are checked after launch.
- A memtester configuration requires both worker records to be alive after launch.
- Normal pressure stop writes a planned-stop reason into stress logs when possible.

### Monitoring and reports

- dmesg monitoring no longer clears the kernel ring buffer during snapshots.
- dmesg start/end snapshots are collected around the pressure window; the end snapshot is captured before pressure teardown.
- Intermediate dmesg snapshots are tracked per run and checked for newly appearing error lines relative to the start snapshot.
- dmesg and journal collection failures are visible as report warnings; an unavailable optional journal backend does not block cleanup.
- `BUG:` and `Call Trace:` matching tolerates timestamped log prefixes.
- IPMI and OS memory monitor PID files are separate.
- IPMI report parsing is scoped by a per-run marker, so `LOG_CLEANUP_MODE=keep` does not mix old IPMI samples into the current run.
- Crash reports are scoped by current-run artifact time.
- Report generation failure is propagated as cleanup failure.
- Report target duration is read from the saved run resource state, so an external `stop` does not incorrectly report the default 168 hours.

## 4. Review History

- Initial full review found system-disk fallback, incomplete filesystem safety, PID/state races, dmesg clearing, swap/error-path problems, and incomplete fio evidence.
- User decisions applied:
  - Keep the explicit `SYSTEM_DISKS` configuration model.
  - Test disks may be cleared in the actual lab environment; this is documented rather than blocked by a full data-preservation policy.
  - Do not add iperf or GPU execution.
  - Do not expand into unnecessary infrastructure; stable completion and useful evidence are the priority.
- A second full review found additional lifecycle and evidence gaps. The concrete items were fixed where they affected the stated test behavior: PID wiring, startup rollback, lock/state handling, fio timing/results, dmesg scoping, monitor separation, mount validation, and report contamination.
- Final review also identified theoretical hardening opportunities such as complete cgroup ownership and exact swap priority restoration. These are not part of the accepted minimal test scope and were not expanded further.

## 5. Local Verification

Commands run:

```text
wsl bash -n /mnt/c/Users/Prz1y/Documents/GitHub/ali-qual-script/mixed_pressure_7x24/mixed_pressure_7x24.sh
git diff --check
```

Results:

- `bash -n`: passed with no syntax diagnostics.
- `git diff --check`: no content errors; Git emitted existing LF-to-CRLF conversion warnings.
- ShellCheck was not available and was not used.
- No local 7x24-hour runtime was performed.

## 6. Remote Smoke Evidence

The remote test was performed in a new isolated directory, not over the existing installation/configuration.

- Host identity: `localhost.localdomain`
- Kernel: `5.10.134-010.ali5000.al8.x86_64`
- fio: `fio-3.42`
- stress tool: `/usr/bin/stress-ng`
- IPMI tool: available
- System disk: `/dev/sda`
- Test disk used for smoke: `/dev/nvme0n1`, existing unmounted ext4 partition
- Smoke configuration: 120 seconds, 5-second fio steady wait, 2-second OS monitor interval, 10-second IPMI interval.
- Remote test directory: `/root/mixed_pressure_test_20260827_b`
- Remote report: `/root/mixed_pressure_test_20260827_b/mixed_pressure_7x24_logs/pressure_performance_report.txt`

Observed execution:

- fio started successfully on `/dev/nvme0n1p1`.
- CPU pressure started with 121 configured cores on a 128-CPU host.
- VM pressure started with `228090M`, using two stress-ng VM workers.
- OS memory monitor, IPMI monitor, and dmesg monitor started.
- CPUFreq and uncore memory-bandwidth monitors were skipped because the host did not expose the required interfaces.
- CPU and VM exited with code 0 during the smoke run.
- BMC temperature/power samples were collected.
- fio was stopped successfully by the stop path.
- Original swap restoration passed.
- fio mount was unmounted.
- `.test_running` was clear after stop.
- `.cleanup_failed` was clear after stop.
- No 7x24-hour result is claimed; this was only a startup/short-runtime/cleanup smoke test.

The first smoke attempt did not enter pressure because the copied remote config referenced nonexistent `/dev/nvme11n1`. The script correctly rejected the explicit disk list and restored swap. The second attempt used the actual available disk and completed.

## 7. Current Limitations

- The latest local report-only fixes were made after the remote smoke execution, so the exact final file was not rerun remotely.
- The smoke report generated before those report-only fixes showed a blank state-list entry and default target-duration formatting. The local fixes ignore empty entries and read the saved duration.
- The smoke does not prove 7x24-hour stability, hardware throttle behavior, or long-term log cleanliness.
- CPUFreq and memory-bandwidth evidence remains unavailable on this host unless the relevant kernel interfaces are exposed.
- The final target files remain uncommitted and unpushed.

## 8. Handoff Guidance

For a subsequent model:

1. Read this document before changing the script.
2. Treat the official scope above as authoritative.
3. Do not re-open waived iperf/GPU/version items.
4. Prefer the smallest fix that affects stable execution or required evidence.
5. Do not stage unrelated worktree modifications.
6. Before a full run, configure `SYSTEM_DISKS` explicitly and verify every `FIO_DISKS` entry against `lsblk`.
7. A full 7x24-hour result still requires an actual run on the target machine; it must not be inferred from this smoke test.

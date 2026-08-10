#!/usr/bin/env bash
set -o pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# run nvme parallel fio test with binding cpus
"$SCRIPT_DIR/run_parallel_disk.sh" -C

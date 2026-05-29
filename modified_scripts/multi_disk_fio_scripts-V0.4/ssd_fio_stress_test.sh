#!/usr/bin/env bash
set -o pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 1 ]];then
	echo "usage:$0 devname"
	echo "example:$0 sdb"
	echo "example:$0 nvme0n1"
	exit 1
fi

devname="$1"
#ssd stress test
"$SCRIPT_DIR/raw_disk_fio_test.sh" -s -d "$devname"

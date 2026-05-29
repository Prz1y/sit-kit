#!/usr/bin/env bash
set -o pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"


if [[ $# -ne 1 ]];then
        echo "usage:$0 devname"
        echo "example:$0 sdb"
        exit 1
fi

devname="$1"
#Sequence write/read test of HDD
"$SCRIPT_DIR/raw_disk_fio_test.sh" -v -d "$devname"
sleep 30s

#Random write/read test of HDD
"$SCRIPT_DIR/raw_disk_fio_test.sh" -V -d "$devname"
sleep 30s

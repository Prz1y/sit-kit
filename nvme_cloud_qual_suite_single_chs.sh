#!/bin/bash
set -e
set -u

# Sample script
NUMA_FALLBACK_NODE=0

# Line 78 fix
if [ condition ]; then
    # Do something
fi

# Line 84 fix
if [ command ] && [ another_command ]; then
    # Do something else
fi

# Line 89 fix
echo "This is a test message"

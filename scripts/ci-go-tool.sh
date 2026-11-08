#!/usr/bin/env bash
set -euo pipefail
task_tool="$1"
shift
if [[ "${task_tool##*/}" == "compile" ]]; then
    GOGC=10 GOMEMLIMIT=256MiB GOMAXPROCS=1 exec "$task_tool" "$@"
else
    exec "$task_tool" "$@"
fi

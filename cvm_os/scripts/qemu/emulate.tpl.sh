#!/bin/bash
# Copyright (c) 2023 Institute of Parallel And Distributed Systems (IPADS), Shanghai Jiao Tong University (SJTU)
# Licensed under the Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#     http://license.coscl.org.cn/MulanPSL2
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR
# PURPOSE.
# See the Mulan PSL v2 for more details.

set -e
set -o pipefail

basedir=$(dirname "$0")
# basedir should be /build directory

port=$(shuf -i 30000-40000 -n 1)
#while true; do
#	port=\$(shuf -i 30000-40000 -n 1)
#	netstat -tan | grep \$port > /dev/null 2>&1
#	if [[ \$? -ne 0 ]]; then
#		break
#	fi
#done
gdb_port_file=${COFUNC_GDB_PORT_FILE:-$basedir/gdb-port}
if ! { echo $port >"$gdb_port_file"; } 2>/dev/null; then
	echo $port >"/tmp/chcore-gdb-port-${SLOT_ID:-0}"
fi

exec_log=exec_log_${SLOT_ID:-0}
tee_args=("$exec_log")
if [ -n "${COFUNC_TRACE_DIR:-}" ] && mkdir -p "${COFUNC_TRACE_DIR}" 2>/dev/null; then
    tee_args+=("${COFUNC_TRACE_DIR}/${exec_log}")
fi

{
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'slot=%s\n' "${SLOT_ID:-0}"
    printf 'qemu=%s\n' "@qemu@"
    printf 'gdb_port=%s\n' "$port"
    "$basedir/../scripts/qemu/qemu_wrapper.sh" \
        @qemu@ -gdb tcp::$port @qemu_options@
} 2>&1 | tee "${tee_args[@]}"

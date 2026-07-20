#!/bin/bash

set -e

tools=$(dirname $0)
slot_id=${SLOT_ID:-0}
session=split-container-snapshot-${slot_id}
snapshot_timeout=${COFUNC_SC_SNAPSHOT_TIMEOUT:-300}

clean() {
        until [[ -z $(docker ps -a | grep snapshot) ]]; do
                sudo pkill -9 sc-runtime || true
        done
        screen -X -S $session quit &>/dev/null || true
}

if [[ $1 == "clean" ]]; then
        clean
        exit 0
fi

if [[ -z $SLOT_ID ]]; then
        clean
fi

if ! [[ $snapshot_timeout =~ ^[0-9]+$ ]] || ((snapshot_timeout <= 0)); then
        echo "invalid COFUNC_SC_SNAPSHOT_TIMEOUT=$snapshot_timeout" >&2
        exit 2
fi

sudo rm exec_log &>/dev/null || true
touch exec_log

sudo SLOT_ID=$slot_id screen -dmS $session $tools/start.sh sc-snapshot

start_ts=$(date +%s)
until grep -q "snapshot done" exec_log; do
        if ! screen -list | grep -Fq ".$session"; then
                echo "snapshot screen exited before completion" >&2
                tail -n 80 exec_log >&2 || true
                exit 1
        fi
        now_ts=$(date +%s)
        if ((now_ts - start_ts >= snapshot_timeout)); then
                echo "timed out waiting for snapshot after ${snapshot_timeout}s" >&2
                tail -n 80 exec_log >&2 || true
                exit 124
        fi
        sleep 1
done

#!/bin/bash

set -e

tools=$(dirname $0)
slot_id=${SLOT_ID:-0}
session=split-container-snapshot-${slot_id}

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

sudo rm exec_log &>/dev/null || true
touch exec_log

sudo SLOT_ID=$slot_id screen -dmS $session $tools/start.sh sc-snapshot

until [[ ! -z $(cat exec_log | grep "snapshot done") ]]; do
        sleep 1
done

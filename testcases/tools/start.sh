#!/bin/bash

set -e

fn_name=$(basename $(pwd))
command=$(cat command)
runtime=$1
exec_log="exec_log"
result_log=$2
name=$fn_name
times=${3:-1}
tools=$(dirname $0)
slot_id=${SLOT_ID:-0}
# if [[ $PREALLOC ]]; then
#         prealloc="--enable-prealloc"
# fi

cpu_param="--cpuset-cpus 0"

if [[ $runtime == "runc" ]]; then
        command=$command
elif [[ $runtime == "sc" ]]; then
        command="/bin/sc-runtime --slot $slot_id $command"
elif [[ $runtime == "shell" ]]; then
        command="sh"
elif [[ $runtime == "sc-snapshot" ]]; then
        name="$fn_name"_snapshot_"$slot_id"
        command="/bin/sc-runtime --slot $slot_id $command --sc-snapshot"
elif [[ $runtime == "sc-restore" ]]; then
        command="/bin/sc-runtime --slot $slot_id"
elif [[ $runtime == "criu-restore" ]]; then
        command="criu restore -D /criu/checkpoint -j"
elif [[ $runtime == "linux-fork" ]]; then
        command="$command --linux-fork"
elif [[ $runtime == "sc-polling" ]]; then
        cpu_param="--cpuset-cpus 0,2"
        command="/bin/sc-runtime --slot $slot_id $command --sc-polling"
else
        exit 1
fi

docker rm -f $name &>/dev/null || true

# if [[ $result_log != "" ]]; then
#         echo "new test @ $(date)" >> $result_log
# fi

for i in $(seq $times); do
        t_begin=$(date +%s.%7N)

        echo "mode runc-${runtime}" > $exec_log

        printf "t_begin %s\n" $t_begin | tee -a $exec_log

        docker run -it --rm --privileged --net=host $cpu_param --name $name \
                -v /dev:/dev --tmpfs /tmp --tmpfs /run \
                $fn_name /tools/start.sh $command | tee -a $exec_log

        if [[ $NO_ANALYSIS ]]; then
                continue
        fi

        if [[ $result_log != "" ]]; then
                $tools/analyze.py --log $result_log
        else
                $tools/analyze.py
        fi
done

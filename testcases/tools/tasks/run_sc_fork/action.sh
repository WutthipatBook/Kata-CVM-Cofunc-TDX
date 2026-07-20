#!/bin/bash

set -e

fn_name=$1
times=$2
log_dir=${LOG_DIR:-/tmp/log}/$fn_name
log_file=$log_dir/sc_fork.log

tools=$(dirname $(realpath $0))/../..

pushd $tools/../testcases/$fn_name

mkdir -p $log_dir
rm -f $log_file

if [[ -f prepare.py ]]; then
        ./prepare.py
fi

$tools/lean_container/rootfs.sh
$tools/lean_container/cgroup.sh
# $tools/hugepage.sh

$tools/cvm.sh
$tools/sc-snapshot.sh

sudo $tools/lean_container/start.sh sc-fork $log_file $times

$tools/sc-snapshot.sh clean
$tools/cvm.sh clean

$tools/lean_container/rootfs.sh clean
$tools/lean_container/cgroup.sh clean
# $tools/hugepage.sh clean

popd

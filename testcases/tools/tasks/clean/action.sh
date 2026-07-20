#!/bin/bash

set -e

fn_name=$1

tools=$(dirname $(realpath $0))/../..

pushd $tools/../$fn_name
$tools/lean_container/rootfs.sh clean
$tools/lean_container/cgroup.sh clean
$tools/hugepage.sh clean
popd

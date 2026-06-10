#!/bin/bash

docker build --build-arg COFUNC_PLAT="${COFUNC_PLAT:-amd_sev}" -t split_container_builder .

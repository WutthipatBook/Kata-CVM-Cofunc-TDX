#!/bin/bash -e

path=user/system-services/chcore-libc/musl-libc
url=https://git.musl-libc.org/git/musl
branch=v1.2.3

if [[ -e "$path" ]]; then
        echo "$path already exists"
        exit 0
fi

git clone --depth=1 -b "$branch" "$url" "$path"

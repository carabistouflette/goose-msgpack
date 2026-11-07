#!/usr/bin/env bash
# Build the Goose compiler pinned in GOOSE_REVISION into .toolchain/goose.
set -euo pipefail
cd "$(dirname "$0")/.."
revision=$(cat GOOSE_REVISION)
toolchain_dir="$PWD/.toolchain/goose"
if [[ ! -d "$toolchain_dir/.git" ]]; then
    git init "$toolchain_dir"
    git -C "$toolchain_dir" remote add origin https://github.com/aardappel/goose.git
fi
git -C "$toolchain_dir" fetch --depth 1 origin "$revision"
git -C "$toolchain_dir" checkout --detach "$revision"
cmake -S "$toolchain_dir" -B "$toolchain_dir/build" \
    -DCMAKE_BUILD_TYPE=Release -DGOOSE_BUILTIN_LIBS=none
cmake --build "$toolchain_dir/build" --parallel "${JOBS:-2}"

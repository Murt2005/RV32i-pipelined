#!/bin/bash
#
# Generate the riscv-arch-test ELFs for this core with the suite's own framework
#
#   build-arch-tests.sh
#
# Needs mise and the Sail model (MISE and SAIL in site-config.sh). mise installs
# Ruby, uv and the framework's packages; every tool and cache it downloads stays
# in build/riscv-arch-test/tools. The framework skips tests that are up to date.
# ELFs land in build/riscv-arch-test/rv32im-pipelined/elfs

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/site-config.sh"

act="$root/tests/riscv-arch-test"
out="$root/build/riscv-arch-test"
tools="$out/tools"

# A bare name is looked up on PATH; a path puts its folder on PATH for the framework
on_path() {
    if [[ $1 = */* ]]; then
        [ -x "$1" ] || { echo "$2 not found at $1; set $3 in site-config.sh"; exit 1; }
        PATH="$(cd "$(dirname "$1")" && pwd):$PATH"
    else
        command -v "$1" >/dev/null || { echo "$2 ($1) not on PATH; set $3 in site-config.sh"; exit 1; }
    fi
}
on_path "$MISE" mise MISE
on_path "$SAIL" "the Sail model" SAIL
PATH="$(dirname "$RISCV_PREFIX"):$PATH"
export PATH

[ -f "$act/Makefile" ] || { echo "tests/riscv-arch-test is empty; run git submodule update --init tests/riscv-arch-test"; exit 1; }

export MISE_DATA_DIR="$tools/mise/data" MISE_CACHE_DIR="$tools/mise/cache"
export MISE_STATE_DIR="$tools/mise/state" MISE_CONFIG_DIR="$tools/mise/config"
export MISE_YES=1 MISE_TRUSTED_CONFIG_PATHS="$act"
export XDG_CACHE_HOME="$tools/cache" XDG_DATA_HOME="$tools/data"
export GEM_HOME="$tools/gems" UV_CACHE_DIR="$tools/uv" UV_PROJECT_ENVIRONMENT="$tools/venv"

mkdir -p "$out" "$root/build/logs"
log="$root/build/logs/riscv-arch-test-build.log"

cd "$act"
if ! { mise install &&
       mise exec -- bundle install --gemfile framework/src/act/data/Gemfile; } > "$log" 2>&1; then
    tail -20 "$log"; echo "installing the framework's tools failed, full log in ${log#$root/}"; exit 1
fi

# UDB's gem install fetches a Linux z3, so on macOS point it at Homebrew's
if [ "$(uname)" = Darwin ]; then
    z3="$(brew --prefix z3 2>/dev/null)/lib/libz3.dylib"
    [ -f "$z3" ] || { echo "UDB needs z3 on macOS: brew install z3"; exit 1; }
    for dir in "$XDG_CACHE_HOME"/udb/z3/*/*/; do
        ln -sf "$z3" "$dir/libz3.so"
    done
fi

echo "building riscv-arch-test ELFs, which takes a few minutes the first time"
if ! CONFIG_FILES="$root/tests/riscv-arch-test-env/test_config.yaml" WORKDIR="$out" \
        mise exec -- make >> "$log" 2>&1; then
    grep -v '^\s*$' "$log" | tail -30; echo "full log in ${log#$root/}"; exit 1
fi

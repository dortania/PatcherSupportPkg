#!/usr/bin/env bash
# make_tbd.sh: writes NVIDIAAdapter/libLLVM3802.tbd, the link stub for the shared 3802 libLLVM, from the functions
# nvair.cpp and Common/LLVM38.h use (LLVM-C calls outside comments and asm("...") C++ symbols), so the stub never lags the
# source; a name libLLVM doesn't export would keep the adapter, and with it the plugin, from loading. build.sh runs it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRCS=("$HERE/nvair.cpp" "$HERE/../Common/LLVM38.h")
{
    echo "--- !tapi-tbd"
    echo "tbd-version:     4"
    echo "targets:         [ x86_64-macos ]"
    echo "install-name:    '/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/3802/Libraries/libLLVM.dylib'"
    echo "exports:"
    echo "  - targets:     [ x86_64-macos ]"
    printf "    symbols:     [ "
    grep -h -o -E 'asm\("_[^"]+"\)' "${SRCS[@]}" | sed -E 's/asm\("(.*)"\)/\1/' | sort -u | sed "s/.*/'&'/" | paste -sd, - | tr -d '\n'
    sed 's://.*$::' "${SRCS[@]}" | grep -o -E '\bLLVM[A-Z][A-Za-z0-9]+\(' | tr -d '(' | sort -u | while read -r s; do printf ",\n                   _%s" "$s"; done
    echo " ]"
    echo "..."
} > "$HERE/libLLVM3802.tbd"

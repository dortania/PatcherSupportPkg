#!/usr/bin/env bash
# ivb-compile.sh: compile-only check of Ivy Bridge's Metal compiler on a Haswell Mac. Runs the 11.7.10 payload's
# libMTLIntelCompilerPlugin, libIGIL-Metal and iCBE (Ivy Bridge's GPU compiler) inside a test process through
# tools/localcc.dylib, and builds every pipeline whose source is embedded in a test here: once with the stock plugin
# and once with the payload's plugin + IntelTextureAtomics.dylib. The Haswell driver can't decode Ivy Bridge binaries, so
# tools/ivbcompile stubs its pipeline creation: reaching it means the compiler finished, and nothing runs on the GPU.
# Prints one line per pipeline (stock | fixed | pipeline) and a summary. Needs ../build.sh run first.
set -u
cd "$(dirname "$0")"
B=$(cd .. && pwd)/build UB=$(cd ../../.. && pwd)/Universal-Binaries/11.7.10/System/Library/Extensions
[ -f "$B/MetalOldCompat.dylib" ] || { echo "run ../build.sh first" >&2; exit 2; }
[ -f tools/localcc.dylib ] || clang++ -std=c++17 -fblocks -dynamiclib tools/localcc.cpp -o tools/localcc.dylib
clang -fobjc-arc -framework Metal -framework Foundation tools/ivbcompile.m -o build/ivbcompile
W=$(mktemp -d); mkdir "$W/stock" "$W/fixed" "$W/src"
for d in stock fixed; do
    cp "$UB/AppleIntelGraphicsShared.bundle/Contents/MacOS/libIGIL-Metal.dylib" "$UB/AppleIntelHD4000GraphicsGLDriver.bundle/Contents/MacOS/iCBE.dylib" "$W/$d/"
done
git show "$(git merge-base HEAD origin/HEAD):Universal-Binaries/11.7.10/System/Library/Extensions/AppleIntelHD4000GraphicsMTLDriver.bundle/Contents/MacOS/libMTLIntelCompilerPlugin.dylib" > "$W/stock/libMTLIntelCompilerPlugin.dylib"
cp "$UB/AppleIntelHD4000GraphicsMTLDriver.bundle/Contents/MacOS/libMTLIntelCompilerPlugin.dylib" "$UB/AppleIntelHD4000GraphicsMTLDriver.bundle/Contents/MacOS/IntelTextureAtomics.dylib" "$W/fixed/"
python3 -I - "$W/src" > "$W/jobs" <<'PY'
import glob, os, re, sys
out = sys.argv[1]
for path in sorted(glob.glob('*.m')):
    s = open(path).read()
    for m in re.finditer(r'static NSString \*const (\w+) = (@".*?");\n', s, re.S):
        text = ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(2)))
        if '%' in text or 'metal_stdlib' not in text: continue
        f = os.path.join(out, '%s-%s.metal' % (path[:-2], m.group(1)))
        open(f, 'w').write(text.encode().decode('unicode_escape'))
        text = open(f).read()
        verts = re.findall(r'vertex\s+[\w<>:, ]+?\s+(\w+)\s*\(', text)
        for k in re.findall(r'kernel\s+void\s+(\w+)\s*\(', text): print(f, 'kernel', k)
        for fr in re.findall(r'fragment\s+[\w<>:, ]+?\s+(\w+)\s*\(', text):
            if verts: print(f, 'render', verts[0], fr)
print('build/i05-air-macos15.4.metallib kernel k')  # s13's kernels need function constants, which ivbcompile doesn't set
PY
run() {  # <dir> <job...>
    local d=$1; shift
    rm -rf "$(getconf DARWIN_USER_CACHE_DIR)com.apple.metal"
    r=$(DYLD_INSERT_LIBRARIES=$B/MetalOldCompat.dylib:$PWD/tools/localcc.dylib DYLD_LIBRARY_PATH=$W/$d ./build/ivbcompile "$@" 2>/dev/null |
        grep -E "^(COMPILED|COMPILE FAILED|FRONT-END ERROR)" | head -1 | cut -d' ' -f1-2)
    echo "${r:-CRASHED}"
}
while read -r file mode a b; do
    printf "%-16s | %-16s | %s %s %s %s\n" "$(run stock "$file" $mode $a ${b:-})" "$(run fixed "$file" $mode $a ${b:-})" "$(basename "$file")" $mode $a ${b:-}
done < "$W/jobs" | tee "$W/results"
echo; awk -F' [|] ' '{print $1 " -> " $2}' "$W/results" | sed 's/ *->/ ->/; s/  *$//' | sort | uniq -c
rm -rf "$W"

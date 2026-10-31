#!/usr/bin/env bash
# a03-si-stale-l1-blender.sh <Blender binary> <Blender source checkout, with tests/files from Git LFS>
# (AMD adapter, GCN1/SI only.) On SI, a load right after a store to the same address can return the old value when the
# line is in the vector L1. The 12.5 compiler keeps private structs in scratch memory and reads a field back right
# after writing it without bypassing the L1. Blender EEVEE's GBufferWriter does that with its byte counter `normal_len`
# (buffer_store_byte ... offset:638, then buffer_load_ubyte from the same address). Wavefronts that read the stale 0
# write the thickness over N[0], giving random black 8x8 blocks behind glass and water. Affected render tests:
# shader/object_info, sss/subsurface_behind_glass. The adapter sets GLC (L1 bypass) on loads from memory the same
# shader writes.
# Small shaders didn't reproduce it (the race needs the G-buffer shader's scheduling), so this renders Blender's own
# test scene 3 times with EEVEE on the GPU, as its render tests do. Each render is compared with Blender's reference
# inside Blender (FAIL: > 1% of pixels off by > 0.05 in a channel).
# Stock OCLP (SI GPU): FAIL (every render had blocks here). Fixed: PASS (identical to the reference).
set -u
BLENDER=${1:?usage: $0 <Blender binary> <Blender checkout>} SRC=${2:?usage: $0 <Blender binary> <Blender checkout>}
SCENE=$SRC/tests/files/render/shader/object_info.blend REF=$SRC/tests/files/render/shader/eevee_next_renders/object_info.png
[ -f "$SCENE" ] && [ -f "$REF" ] || { echo "SKIP a03-si-stale-l1: $SCENE or $REF missing (git lfs pull)"; exit 77; }
OUT=$(mktemp -d)
cat > "$OUT/compare.py" <<'PY'
import bpy, sys
a, b = (bpy.data.images.load(p) for p in sys.argv[sys.argv.index("--") + 1:])
pa, pb = a.pixels[:], b.pixels[:]
if len(pa) != len(pb): print("RESULT size differs"); sys.exit()
bad = sum(1 for i in range(0, len(pa), 4) if max(abs(pa[i + c] - pb[i + c]) for c in range(3)) > 0.05)
print("RESULT %.2f" % (100.0 * bad / (len(pa) // 4)))
PY
worst=0 results=""
for run in 1 2 3; do
    "$BLENDER" -b --factory-startup --enable-autoexec --gpu-backend metal "$SCENE" -E BLENDER_EEVEE_NEXT \
        -P "$SRC/tests/python/eevee_render_tests.py" -o "$OUT/render${run}_####" -F PNG -f 1 >"$OUT/log$run.txt" 2>&1
    pct=$("$BLENDER" -b --factory-startup --python "$OUT/compare.py" -- "$OUT/render${run}_0001.png" "$REF" 2>/dev/null | sed -n 's/^RESULT //p')
    results="$results ${pct:-no render}%"
    case "$pct" in ''|size*) worst=100 ;; *) awk "BEGIN{exit !($pct > $worst)}" && worst=$pct ;; esac
done
rm -rf "$OUT"
if awk "BEGIN{exit !($worst > 1)}"; then echo "FAIL a03-si-stale-l1: object_info renders differ from the reference:$results of pixels (black blocks)"; exit 1; fi
echo "PASS a03-si-stale-l1: 3 object_info renders match the reference ($results of pixels off)"

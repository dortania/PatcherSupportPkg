#!/usr/bin/env bash
# s28-webgpu-divide-by-zero.sh [port] (MetalOldCompat item 26; needs Safari, installed system only: safaridriver can't pass an
# override, so it isn't in run.sh.) A render pass on a canvas texture destroyed by a resize must be a validation error. WebKit's
# WebGPU rounds up to a multiple of a format alignment that is 0 there: harmless on Apple silicon, where `udiv` by zero gives 0;
# on Intel Macs `div` traps and the SIGFPE kills the GPU process, and every page then gets a null adapter.
# (WebGPU CTS web_platform,canvas,getCurrentTexture:resize, which took the rest of that suite down with it.)
# Once: sudo safaridriver --enable. Stock OCLP: FAIL. Fixed: PASS.
set -u
PORT=${1:-4577}
DIR=$(mktemp -d)
cat > "$DIR/index.html" <<'EOF'
<!doctype html><title>s28</title>
EOF
python3 -I -m http.server --bind 127.0.0.1 --directory "$DIR" $((PORT + 1)) > /dev/null 2>&1 &
SERVER=$!
osascript -e 'tell application "Safari" to quit' 2> /dev/null
sleep 3
/usr/bin/safaridriver -p "$PORT" &
DRIVER=$!
sleep 2
cleanup() { [ -n "${ID:-}" ] && curl -s -m 20 -X DELETE "http://127.0.0.1:$PORT/session/$ID" > /dev/null; kill "$DRIVER" "$SERVER" 2> /dev/null; rm -rf "$DIR"; }
trap cleanup EXIT
call() { curl -s -m "${3:-60}" -X POST -H 'Content-Type: application/json' -d "$2" "http://127.0.0.1:$PORT$1"; }
ID=$(call /session '{"capabilities":{"alwaysMatch":{"browserName":"safari"}}}' 70 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["value"].get("sessionId",""))')
[ -n "$ID" ] || { echo "SKIP s28-webgpu-divide-by-zero: no WebDriver session (sudo safaridriver --enable?)"; exit 77; }
call "/session/$ID/url" "{\"url\":\"http://127.0.0.1:$((PORT + 1))/\"}" > /dev/null
SCRIPT='const done = arguments[arguments.length - 1];
(async () => {
  if (!navigator.gpu) return "no WebGPU";
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) return "no adapter to start with";
  const device = await adapter.requestDevice();
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 2;
  const context = canvas.getContext("webgpu");
  context.configure({device, format: navigator.gpu.getPreferredCanvasFormat()});
  const texture = context.getCurrentTexture();
  canvas.width = 4;
  device.pushErrorScope("validation");
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginRenderPass({colorAttachments: [{view: texture.createView(), loadOp: "clear", storeOp: "store"}]});
  pass.end();
  device.queue.submit([encoder.finish()]);
  const error = await device.popErrorScope();
  const after = await navigator.gpu.requestAdapter();
  return (after ? "alive" : "dead") + "; validation error: " + (error ? "yes" : "no");
})().then(done, e => done("exception: " + e.message));'
BODY=$(python3 -I -c 'import json,sys; print(json.dumps({"script": sys.argv[1], "args": []}))' "$SCRIPT")
RESULT=$(call "/session/$ID/execute/async" "$BODY" 60 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["value"])')
case "$RESULT" in
    "no WebGPU") echo "SKIP s28-webgpu-divide-by-zero: WebGPU is off in this Safari (the default on macOS 15)"; exit 77 ;;
    "alive; validation error: yes") echo "PASS s28-webgpu-divide-by-zero: render pass on a destroyed canvas texture is a validation error, WebGPU stays up"; exit 0 ;;
    *) echo "FAIL s28-webgpu-divide-by-zero: $RESULT"; exit 1 ;;
esac

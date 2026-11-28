#!/usr/bin/env python3
# ra-sweep.py [--driver vulkan|metal|glcore] [--only SUBSTR | --presets a.slangp,b.slangp] [--start N] [--count N] [--out DIR]
# [--keep-shots]: applies RetroArch's slang shader presets (tools/fetch-apps.sh retroarch retroarch-extras puts RetroArch, the
# slang pack and the 2048 core in Tests/apps) one after another in one RetroArch (2048 core, UDP command SET_SHADER; its
# GET_STATUS crashes RetroArch with a content-less core, so VERSION is the readiness probe) on the installed stack and
# records per preset: ok (applied, still alive, output not blank), error (RetroArch or MoltenVK logged an error and kept
# its old shader), timeout (no "Applying shader" within --timeout s), blank (the window's picture is ~all black), died
# (RetroArch quit; a crash report is named), devlost (MoltenVK / Metal lost the device). RetroArch restarts after a death
# or device loss. Results: DIR/results.tsv (index, status, seconds, preset, detail), the log per RetroArch run, small
# screenshots of non-ok presets. Throwaway HOME; the app's Metal shader cache is cleared at the start.
import argparse, glob, os, re, shutil, socket, subprocess, sys, time
T = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # Tests
APP = T + '/apps/RetroArch.app/Contents/MacOS/RetroArch'
X = T + '/apps/retroarch-extras'
CW = T + '/tools/crashwatch.sh'
WINID = T + '/build/winid'  # the window to photograph (screencapture -l)
if not os.path.exists(WINID):
    os.makedirs(T + '/build', exist_ok=True)
    subprocess.run(['clang', '-O1', '-framework', 'CoreGraphics', '-framework', 'CoreFoundation', '-o', WINID, T + '/tools/winid.c'], check=True)
ap = argparse.ArgumentParser()
ap.add_argument('--driver', default='vulkan'); ap.add_argument('--only', default='')
ap.add_argument('--start', type=int, default=0); ap.add_argument('--count', type=int, default=100000)
ap.add_argument('--timeout', type=float, default=90); ap.add_argument('--settle', type=float, default=2.0)
ap.add_argument('--out', default=''); ap.add_argument('--port', type=int, default=55355)
ap.add_argument('--keep-shots', action='store_true'); ap.add_argument('--presets', default='', help='comma list relative to shaders_slang')
a = ap.parse_args()
out = a.out or f'{T}/build/ra-sweep-{a.driver}'
os.makedirs(out + '/shots', exist_ok=True)
presets = [X + '/shaders_slang/' + q for q in a.presets.split(',')] if a.presets else sorted(p for p in glob.glob(X + '/shaders_slang/**/*.slangp', recursive=True) if a.only in p)
presets = presets[a.start:a.start + a.count]
cache = subprocess.run(['getconf', 'DARWIN_USER_CACHE_DIR'], capture_output=True, text=True).stdout.strip() + 'com.libretro.dist.RetroArch/com.apple.metal'
shutil.rmtree(cache, ignore_errors=True)
home = out + '/home'; os.makedirs(home, exist_ok=True)
cfg = out + '/ra.cfg'
run = 0; proc = None; logf = None; logpath = ''

def start():
    global proc, run, logf, logpath
    run += 1
    with open(cfg, 'w') as f:
        f.write(f'video_driver = "{a.driver}"\nlibretro_directory = "{X}"\nvideo_shader_dir = "{X}/shaders_slang"\n'
                f'video_shader_enable = "true"\nnetwork_cmd_enable = "true"\nnetwork_cmd_port = "{a.port}"\npause_nonactive = "false"\n'
                'audio_driver = "null"\nvideo_fullscreen = "false"\nlog_verbosity = "true"\nconfig_save_on_exit = "false"\n'
                'video_shader_preset_save_reference_enable = "false"\nauto_shaders_enable = "false"\n')
    logpath = f'{out}/log-{run}.txt'; logf = open(logpath, 'w')
    subprocess.run([CW, 'start', f'{out}/mark-{run}'])
    env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home)
    proc = subprocess.Popen([APP, '--config', cfg, '-L', X + '/2048_libretro.dylib', '-v'], stdout=logf, stderr=subprocess.STDOUT, env=env)
    t0 = time.time()
    while time.time() - t0 < 60 and proc.poll() is None:
        if 'swapchain' in open(logpath, errors='replace').read() or a.driver != 'vulkan' and time.time() - t0 > 8: break
        time.sleep(0.5)
    time.sleep(3)
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); probe.settimeout(1.0)
    for _ in range(40):  # ready once its command interface answers (a command sent during a video reinit is lost)
        if proc.poll() is not None: break
        probe.sendto(b'VERSION', ('127.0.0.1', a.port))
        try: probe.recv(512); break
        except socket.timeout: pass
    time.sleep(2)

def stop():
    if proc and proc.poll() is None:
        proc.terminate()
        try: proc.wait(5)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()

def crashes():
    r = subprocess.run([CW, 'new', f'{out}/mark-{run}', 'MTLCompilerService', 'RetroArch'], capture_output=True, text=True).stdout.split()
    return ' '.join(os.path.basename(x) for x in r[:3])

def shot(name):
    wid = subprocess.run([WINID, str(proc.pid)], capture_output=True, text=True).stdout.strip()
    if not wid: return None
    path = f'{out}/shots/{name}.png'
    subprocess.run(['screencapture', '-x', '-o', '-l', wid, path])
    try:
        from PIL import Image, ImageStat
        im = Image.open(path).convert('L'); w, h = im.size
        im = im.crop((0, int(h * 0.04), w, h)).resize((160, 160))  # without the title bar
        st = ImageStat.Stat(im); return st.mean[0], st.stddev[0], path
    except Exception: return None

res = open(out + '/results.tsv', 'a')
start()
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i, p in enumerate(presets, a.start):
    rel = os.path.relpath(p, X + '/shaders_slang')
    if proc.poll() is not None: start()
    pos = os.path.getsize(logpath)
    sock.sendto(f'SET_SHADER {p}'.encode(), ('127.0.0.1', a.port))
    t0 = time.time(); status, detail = 'timeout', ''; resent = False
    while time.time() - t0 < a.timeout:
        time.sleep(0.3)
        with open(logpath, errors='replace') as f: f.seek(pos); new = f.read()
        if not resent and time.time() - t0 > 15 and not re.search(r'\[Slang\]|\[Shaders\]|\[Metal\]', new):
            sock.sendto(f'SET_SHADER {p}'.encode(), ('127.0.0.1', a.port)); resent = True  # lost during a reinit
        if proc.poll() is not None: status = 'died'; break
        errs = [l for l in new.splitlines() if re.search(r'\[ERROR\]|mvk-error|Invalid Resource|DEVICE_LOST|device was lost', l) and not re.search(r'(?i)audio', l)]
        if any(re.search(r'Invalid Resource|DEVICE_LOST|device was lost', l) for l in errs): status, detail = 'devlost', errs[0][:200]; break
        if errs: status, detail = 'error', errs[0][:200]; break
        if 'Applying shader' in new: status = 'ok'; break
    secs = time.time() - t0
    if status == 'ok':
        time.sleep(a.settle)
        with open(logpath, errors='replace') as f: f.seek(pos); new = f.read()
        if proc.poll() is not None: status = 'died'
        elif re.search(r'Invalid Resource|DEVICE_LOST|device was lost', new): status, detail = 'devlost', 'after applying'
        elif [l for l in new.splitlines() if re.search(r'mvk-error|\[ERROR\]', l) and not re.search(r'(?i)audio', l)]: status, detail = 'error', [l for l in new.splitlines() if re.search(r'mvk-error|\[ERROR\]', l) and not re.search(r'(?i)audio', l)][0][:200]
        else:
            trig = os.environ.get('CBTRACE_TRIGGER')
            if trig:  # cbtrace.dylib injected: record this preset's frame
                open(trig, 'w').close(); time.sleep(1.5)
                d = os.environ.get('CBTRACE_DIR', '')
                if os.path.exists(f'{d}/cb-trigger.txt'): os.replace(f'{d}/cb-trigger.txt', f'{d}/cb-{i:04d}.txt')
            s = shot(f'{i:04d}')
            if s and s[0] < 2.0 and s[1] < 2.0:  # maybe the video reinit after a shader change: look again
                time.sleep(3); s = shot(f'{i:04d}') if proc.poll() is None else s
            if s and s[0] < 2.0 and s[1] < 2.0: status, detail = 'blank', f'mean {s[0]:.1f} sd {s[1]:.1f} {s[2]}'
            elif s and not a.keep_shots: os.remove(s[2])
    if status in ('died', 'devlost', 'timeout'):
        if status != 'died' and proc.poll() is None: shot(f'{i:04d}')
        stop(); time.sleep(1); c = crashes(); detail = (detail + ' ' + c).strip(); start()
    res.write(f'{i}\t{status}\t{secs:.1f}\t{rel}\t{detail}\n'); res.flush()
    print(f'{i} {status} {secs:.1f}s {rel} {detail}', flush=True)
stop()

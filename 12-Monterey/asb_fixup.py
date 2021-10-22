#!/usr/bin/env python3
# Moves ASB's accel data to the correct folder
# Default folder will be 'wrapped'
# Sub directiories:
#  - Cass2 (TeraScale 2)
#  - Common (Universal)
#  - Zoe (Universal)
from __future__ import print_function

import subprocess
from pathlib import Path

skylight_path = "PrivateFrameworks/Graphics-Acceleration/Skylight.framework/Versions/A"
ioaccelerator_path = "PrivateFrameworks/Graphics-Acceleration-TeraScale-2/IOAccelerator.framework/Versions/A"
iosurface_ts2_path = "Frameworks/Graphics-Acceleration-TeraScale-2/IOSurface.framework/Versions/A"
iosurface_path = "Frameworks/Graphics-Acceleration/IOSurface.framework/Versions/A"
coredisplay_path = "Frameworks/Graphics-Acceleration/CoreDisplay.framework/Versions/A"

# TeraScale 2
print("Removing old IOAccelerator")
subprocess.run(f"rm ./{ioaccelerator_path}/IOAccelerator".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"rm ./{ioaccelerator_path}/IOAcceleratorOld.dylib ".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
print("Adding IOAccelerator")
subprocess.run(f"cp ./Wrapped/Cass2/IOAccelerator ./{ioaccelerator_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"cp ./Wrapped/Cass2/IOAcceleratorOld.dylib ./{ioaccelerator_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()

print("Removing old IOSurface (TeraScale 2)")
subprocess.run(f"rm ./{iosurface_ts2_path}/IOSurface".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"rm ./{iosurface_ts2_path}/IOSurfaceOld.dylib ".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
print("Adding IOSurface (TeraScale 2)")
subprocess.run(f"cp ./Wrapped/Cass2/IOSurface ./{iosurface_ts2_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"cp ./Wrapped/Cass2/IOSurfaceOld.dylib ./{iosurface_ts2_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()

# Universal
print("Removing old IOSurface")
subprocess.run(f"rm ./{iosurface_path}/IOSurface".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"rm ./{iosurface_path}/IOSurfaceOld.dylib ".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
print("Adding IOSurface")
subprocess.run(f"cp ./Wrapped/Zoe/IOSurface ./{iosurface_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"cp ./Wrapped/Zoe/IOSurfaceOld.dylib ./{iosurface_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()

print("Removing old CoreDisplay")
subprocess.run(f"rm ./{coredisplay_path}/CoreDisplay".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"rm ./{coredisplay_path}/CoreDisplayOld.dylib ".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
print("Adding CoreDisplay")
subprocess.run(f"cp ./Wrapped/Common/CoreDisplay ./{coredisplay_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"cp ./Wrapped/Common/CoreDisplayOld.dylib ./{coredisplay_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()

print("Removing old SkyLight")
subprocess.run(f"rm ./{skylight_path}/SkyLight".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"rm ./{skylight_path}/SkyLightOld.dylib ".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
print("Adding SkyLight")
subprocess.run(f"cp ./Wrapped/Common/SkyLight ./{skylight_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
subprocess.run(f"cp ./Wrapped/Common/SkyLightOld.dylib ./{skylight_path}".split(), stdout=subprocess.PIPE).stdout.decode().strip().encode()
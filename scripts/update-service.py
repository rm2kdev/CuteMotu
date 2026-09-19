#!/usr/bin/env python3
"""Preview or replace only the installed prototype service; keep the HAL loaded."""
import argparse
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--apply', action='store_true')
parser.add_argument('--restart-audio', action='store_true', help='Reload Core Audio before USB restarts to replace its shared-memory connection')
args = parser.parse_args()
name = 'org.cutemix.usbaudio.service'
source = root / 'build/prototype/cute-usb-service'
base = pathlib.Path('/Library/Application Support/Cute Mix USB Audio')
destination = base / source.name
plist = pathlib.Path('/Library/LaunchDaemons') / (name + '.plist')
if any(p.is_symlink() for p in (base, destination, plist)):
    parser.error('Refusing a symlink installation path')
if not source.is_file() or not destination.is_file() or not plist.is_file():
    parser.error('Build the service and install the prototype before updating')
config = plistlib.loads(plist.read_bytes())
if config.get('Label') != name or config.get('ProgramArguments', [None])[0] != str(destination):
    parser.error('The installed launch daemon has an unexpected identity')
installed_hal = pathlib.Path('/Library/Audio/Plug-Ins/HAL/CuteMixUSB.driver/Contents/Info.plist')
built_hal = root / 'build/prototype/CuteMixUSB.driver/Contents/Info.plist'
if not installed_hal.is_file() or not built_hal.is_file():
    parser.error('HAL metadata is missing; use install-local.py for a complete installation')
if plistlib.loads(installed_hal.read_bytes()).get('CFBundleVersion') != plistlib.loads(built_hal.read_bytes()).get('CFBundleVersion'):
    parser.error('This build also changes the HAL; run install-local.py --backend usb --hardware-handover --apply under sudo, then reboot')
subprocess.run(['codesign', '--verify', '--strict', str(source)], check=True, cwd=root)
print(f'Replace {destination} and restart {name}. HAL, app and launch configuration stay in place.', flush=True)
if args.restart_audio:
    print('Reload Core Audio while USB is paused. Mac audio briefly stops.', flush=True)
if not args.apply:
    print('Preview only. Use --apply with administrator authentication.')
    raise SystemExit(0)
if os.geteuid() != 0:
    parser.error('--apply requires administrator authentication')

# Stage and verify on the destination volume before interrupting the service.
fd, staging = tempfile.mkstemp(prefix='.cute-usb-service-', dir=base)
os.close(fd)
try:
    shutil.copy2(source, staging)
    os.chmod(staging, 0o755)
    os.chown(staging, 0, 0)
    subprocess.run(['codesign', '--verify', '--strict', staging], check=True, cwd=root)
    subprocess.run(['launchctl', 'bootout', 'system/' + name], check=True, cwd=root)
    try:
        os.replace(staging, destination)
        if args.restart_audio:
            subprocess.run(['/usr/bin/killall', '-TERM', 'coreaudiod'], check=True, cwd=root)
            time.sleep(5)
    finally:
        # Restart even if replacement failed, leaving the previous binary usable.
        subprocess.run(['launchctl', 'bootstrap', 'system', str(plist)], check=True, cwd=root)
finally:
    if os.path.exists(staging):
        os.unlink(staging)
print('Prototype service updated. HAL bundle was not replaced.', flush=True)

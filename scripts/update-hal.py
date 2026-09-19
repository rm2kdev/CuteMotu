#!/usr/bin/env python3
"""Update the prototype HAL, optionally its app, and reload Core Audio."""
import argparse
import contextlib
import json
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
parser.add_argument('--update-app', action='store_true', help='Also update Cute Mix USB for the separate volume-mode control')
parser.add_argument('--restart-audio', action='store_true',
                    help='Pause the USB service, reload Core Audio, then restart the service; briefly interrupts Mac audio')
args = parser.parse_args()
source = root / 'build/prototype/CuteMixUSB.driver'
destination = pathlib.Path('/Library/Audio/Plug-Ins/HAL/CuteMixUSB.driver')
identity = 'org.cutemix.usbaudio.hal'
service = 'org.cutemix.usbaudio.service'
launch_plist = pathlib.Path('/Library/LaunchDaemons') / (service + '.plist')

app_source = root / 'build/prototype/Cute Mix USB.app'
app_destination = pathlib.Path('/Applications/Cute Mix USB.app')
updates = [(source, destination, identity)]
if args.update_app:
    updates.append((app_source, app_destination, 'org.cutemix.usbaudio.app'))

for update_source, update_destination, update_identity in updates:
    for bundle in (update_source, update_destination):
        if not bundle.is_dir():
            parser.error(f'Missing bundle: {bundle}; build and fully install the prototype first')
        if any(p.is_symlink() for p in [bundle, *bundle.parents, *bundle.rglob('*')]):
            parser.error(f'Refusing a symlink bundle or parent: {bundle}')
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != update_identity:
            parser.error(f'Unexpected bundle identity: {bundle}')
        if bundle == update_destination and info.get('CFBundleVersion') not in ('2', '3', '4', '5', '6', '7', '8', '9', '10'):
            parser.error('This HAL-only update requires the build 2 or later service installation')
        if bundle == update_source and info.get('CFBundleVersion') != ('10' if update_identity.endswith('.app') else '7'):
            parser.error('Build the current prototype before running this updater')
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(bundle)], check=True, cwd=root)

if args.restart_audio:
    if launch_plist.is_symlink() or not launch_plist.is_file():
        parser.error('The prototype launch configuration is missing or is a symlink')
    config = plistlib.loads(launch_plist.read_bytes())
    if config.get('Label') != service or config.get('ProgramArguments', [None])[0] != '/Library/Application Support/Cute Mix USB Audio/cute-usb-service':
        parser.error('Unexpected prototype launch configuration')

print(f'Replace {destination} with 0.1.6 / build 7. Keep the service binary and launch configuration.', flush=True)
if args.update_app:
    print(f'Also replace {app_destination}. Quit and reopen Cute Mix USB after installation.', flush=True)
else:
    print('This HAL needs the matching Cute Mix USB app for its volume toggle; use --update-app to install both.', flush=True)
if args.restart_audio:
    print('Pause the USB service, restart Core Audio, then restart USB and check device discovery. Mac audio briefly stops.', flush=True)
else:
    print('Reboot later to load the updated HAL, or use --restart-audio.', flush=True)
if not args.apply:
    print('Preview only. Add --apply with administrator authentication.')
    raise SystemExit(0)
if os.geteuid() != 0:
    parser.error('--apply requires administrator authentication')

# Replace the directory without modifying the executable currently mapped by
# the helper. Stage on the destination volume, with rollback for a failed rename.
with contextlib.ExitStack() as stack:
    staged = []
    for update_source, update_destination, _ in updates:
        temporary = pathlib.Path(stack.enter_context(tempfile.TemporaryDirectory(
            prefix='.cutemix-update-', dir=update_destination.parent)))
        staging = temporary / update_destination.name
        backup = temporary / ('previous-' + update_destination.name)
        shutil.copytree(update_source, staging)
        for path in [staging, *staging.rglob('*')]:
            executable = path.is_file() and path.parent.name == 'MacOS'
            os.chown(path, 0, 0)
            os.chmod(path, 0o755 if path.is_dir() or executable else 0o644)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(staging)], check=True, cwd=root)
        staged.append((staging, update_destination, backup))
    paused = False
    replaced = []
    try:
        if args.restart_audio:
            subprocess.run(['/bin/launchctl', 'bootout', 'system/' + service], check=True, cwd=root)
            paused = True
        try:
            for staging, target, backup in staged:
                os.rename(target, backup)
                replaced.append((target, backup))
                os.rename(staging, target)
        except BaseException:
            for target, backup in reversed(replaced):
                if target.exists():
                    shutil.rmtree(target)
                os.rename(backup, target)
            raise
        if args.restart_audio:
            # Reload before opening USB again. This avoids scheduling USB across
            # a system-wide audio restart and gives the HAL a fresh connection.
            subprocess.run(['/usr/bin/killall', '-TERM', 'coreaudiod'], check=True, cwd=root)
            time.sleep(5)
    finally:
        if paused:
            subprocess.run(['/bin/launchctl', 'bootstrap', 'system', str(launch_plist)], check=True, cwd=root)

if not args.restart_audio:
    print('HAL installed. USB service was not restarted.', flush=True)
    raise SystemExit(0)
print('HAL installed. Core Audio reloaded and USB service restarted.', flush=True)

def visible(value):
    if isinstance(value, dict):
        return value.get('_name') == 'Cute Motu 828x' or any(visible(v) for v in value.values())
    return isinstance(value, list) and any(visible(v) for v in value)

deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    try:
        result = subprocess.run(['/usr/sbin/system_profiler', 'SPAudioDataType', '-json'],
                                capture_output=True, text=True, timeout=8, cwd=root)
        if result.returncode == 0 and visible(json.loads(result.stdout)):
            print('Verified: Core Audio lists Cute Motu 828x. Select it in System Settings > Sound > Output.', flush=True)
            raise SystemExit(0)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    time.sleep(1)
print('HAL installed, but Core Audio has not listed the device within 30 seconds. Discovery still needs diagnosis.', flush=True)
raise SystemExit(1)

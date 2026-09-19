#!/usr/bin/env python3
"""Preview by default; removes only this prototype. Never deactivates DriverKit."""
import argparse, os, pathlib, plistlib, shutil, subprocess
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--apply',action='store_true');a=p.parse_args()
paths=[pathlib.Path('/Library/LaunchDaemons/org.cutemix.usbaudio.service.plist'),pathlib.Path('/Library/Application Support/Cute Mix USB Audio'),pathlib.Path('/Library/Audio/Plug-Ins/HAL/CuteMixUSB.driver'),pathlib.Path('/Applications/Cute Mix USB.app')]
for path in paths:print('Remove',path)
print('Core Audio is not restarted. Reboot to complete HAL removal.')
if not a.apply:print('Preview only. Add --apply under sudo to uninstall.');raise SystemExit(0)
if os.geteuid()!=0:p.error('--apply requires sudo')
for path in paths:
    if path.is_symlink():p.error(f'Refusing symlink: {path}')
for path,identity in [(paths[2],'org.cutemix.usbaudio.hal'),(paths[3],'org.cutemix.usbaudio.app')]:
    if path.exists() and plistlib.loads((path/'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')!=identity:p.error(f'Unexpected bundle identity: {path}')
subprocess.run(['launchctl','bootout','system/org.cutemix.usbaudio.service'],check=False,cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
for path in paths:
    if path.is_dir():shutil.rmtree(path)
    else:path.unlink(missing_ok=True)

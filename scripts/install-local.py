#!/usr/bin/env python3
"""Preview by default. Installs ONLY Cute Mix USB prototype identities."""
import argparse, pathlib, plistlib, shutil, subprocess, os
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--backend',choices=['synthetic','usb'],default='synthetic')
p.add_argument('--hardware-handover',action='store_true')
p.add_argument('--apply',action='store_true')
a=p.parse_args()
if a.backend=='usb' and not a.hardware_handover:p.error('USB installation requires --hardware-handover after completing docs/HARDWARE-HANDOVER.md')
base=pathlib.Path('/Library/Application Support/Cute Mix USB Audio')
hal=pathlib.Path('/Library/Audio/Plug-Ins/HAL/CuteMixUSB.driver')
app=pathlib.Path('/Applications/Cute Mix USB.app')
plist=pathlib.Path('/Library/LaunchDaemons/org.cutemix.usbaudio.service.plist')
artifacts=[(root/'build/prototype/cute-usb-service',base/'cute-usb-service'),(root/'build/prototype/cute-usb-control',base/'cute-usb-control'),(root/'build/prototype/CuteMixUSB.driver',hal),(root/'build/prototype/Cute Mix USB.app',app)]
for source,dest in artifacts:
    if not source.exists():p.error(f'Build first: missing {source}')
    subprocess.run(['codesign','--verify','--strict',str(source)],check=True,cwd=root)
    if dest.is_symlink():p.error(f'Refusing symlink destination: {dest}')
    print(f'Install {source} → {dest}')
args=[str(base/'cute-usb-service'),'--backend',a.backend]
if a.backend=='usb':args+=['--hardware-handover']
config=dict(Label='org.cutemix.usbaudio.service',ProgramArguments=args,MachServices={'org.cutemix.usbaudio.service':True},RunAtLoad=True,KeepAlive={'SuccessfulExit':False},ThrottleInterval=30,ProcessType='Interactive',StandardOutPath='/var/log/cutemix-usbaudio.log',StandardErrorPath='/var/log/cutemix-usbaudio.log')
print(f'Write {plist}; bootstrap system/org.cutemix.usbaudio.service')
print('Core Audio is not restarted by this script. Reboot when ready to discover the HAL plug-in.')
if not a.apply:print('Preview only. Add --apply under sudo to install.');raise SystemExit(0)
if os.geteuid()!=0:p.error('--apply requires sudo')
if a.backend=='usb':
    registry=subprocess.run(['ioreg','-r','-c','MOTU828xDriver'],capture_output=True,text=True,check=True,cwd=root).stdout
    if 'MOTU828xDriver' in registry:p.error('Original driver remains present; refusing USB handover')
for directory in [base,hal.parent,plist.parent]:
    if directory.is_symlink():p.error(f'Refusing symlink directory: {directory}')
    directory.mkdir(parents=True,exist_ok=True)
# Refuse to overwrite bundles with unexpected identities.
for path,identity in [(hal,'org.cutemix.usbaudio.hal'),(app,'org.cutemix.usbaudio.app')]:
    if path.exists():
        current=plistlib.loads((path/'Contents/Info.plist').read_bytes())
        if current.get('CFBundleIdentifier')!=identity:p.error(f'Unexpected identity: {path}')
subprocess.run(['launchctl','bootout','system/org.cutemix.usbaudio.service'],check=False,cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
for source,dest in artifacts:
    if source.is_dir():
        if dest.exists():shutil.rmtree(dest)
        shutil.copytree(source,dest)
    else:shutil.copy2(source,dest)
    subprocess.run(['chown','-R','root:wheel',str(dest)],check=True,cwd=root)
plist.write_bytes(plistlib.dumps(config));os.chmod(plist,0o644);os.chown(plist,0,0)
subprocess.run(['launchctl','bootstrap','system',str(plist)],check=True,cwd=root)
print('Prototype installed. Original DriverKit and Cute Mix bundles were not changed.')

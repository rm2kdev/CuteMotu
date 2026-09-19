#!/usr/bin/env python3
"""Install only Cute Mix USB and keep a rollback copy. Audio stays running."""
import argparse
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--apply', action='store_true')
args = parser.parse_args()
source = root / 'build/prototype/Cute Mix USB.app'
target = pathlib.Path('/Applications/Cute Mix USB.app')
for bundle in (source, target):
    if not bundle.is_dir() or any(p.is_symlink() for p in [bundle, *bundle.parents, *bundle.rglob('*')]):
        parser.error(f'Missing bundle or symlink in bundle path: {bundle}')
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'org.cutemix.usbaudio.app':
        parser.error(f'Unexpected app identity: {bundle}')
    if bundle == source and info.get('CFBundleVersion') != '10':
        parser.error('Build the analysis app (build 10) first with bash scripts/build-app.sh')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(bundle)], check=True)
print(f'Install {source} → {target}', flush=True)
print('App 0.3.0 / build 10. Quit Cute Mix USB before applying. No audio restart or reboot.', flush=True)
if not args.apply:
    print('Preview only. Add --apply to install.')
    raise SystemExit(0)
if not os.access(target.parent, os.W_OK):
    parser.error('Your account cannot write Applications; rerun with administrator authentication')
processes = subprocess.run(['/bin/ps', '-axo', 'command='], capture_output=True, text=True, check=True).stdout.splitlines()
if any(line.strip().startswith(str(target / 'Contents/MacOS/Cute Mix USB')) for line in processes):
    parser.error('Quit the installed Cute Mix USB app, then run this command again')
backup_root = target.parent / '.CuteMixUSB-backups'
if backup_root.is_symlink():
    parser.error(f'Refusing a symlink backup directory: {backup_root}')
backup_root.mkdir(mode=0o755, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.cutemix-app-', dir=target.parent) as tmp:
    staging = pathlib.Path(tmp) / target.name
    shutil.copytree(source, staging)
    for path in [staging, *staging.rglob('*')]:
        if os.geteuid() == 0:
            os.chown(path, 0, 0)
        os.chmod(path, 0o755 if path.is_dir() or path.parent.name == 'MacOS' else 0o644)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(staging)], check=True)
    # Where macOS permits replacement through the writable parent directory,
    # no privileged process is needed. Protected existing bundles require sudo.
    # Keep the old (possibly root-owned) bundle intact outside temporary cleanup.
    backup_dir = pathlib.Path(tempfile.mkdtemp(prefix='previous-', dir=backup_root))
    backup = backup_dir / target.name
    try:
        os.rename(target, backup)
    except PermissionError:
        backup_dir.rmdir()
        parser.error('macOS refused replacement of the installed app. Run sudo python3 scripts/update-app.py --apply in Terminal.')
    try:
        os.rename(staging, target)
    except BaseException:
        os.rename(backup, target)
        backup_dir.rmdir()
        raise
print('Cute Mix USB updated. Reopen it and choose Analysis.', flush=True)
print(f'Previous app retained for rollback: {backup}', flush=True)

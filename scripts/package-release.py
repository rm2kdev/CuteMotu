#!/usr/bin/env python3
"""Package a committed source tree with locally built, ad-hoc-signed binaries.

Does not install, sign, upload or alter the running audio system.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--version', default='0.3.0')
args = parser.parse_args()
if args.version != '0.3.0':
    parser.error('Review component versions before packaging a different release')

def run(*command):
    return subprocess.check_output(command, cwd=root, text=True).strip()

if run('git', 'status', '--porcelain'):
    parser.error('Commit the source tree before packaging')
if not (root / 'LICENSE').is_file():
    parser.error('LICENSE is required')
commit = run('git', 'rev-parse', 'HEAD')
base = root / 'build/prototype'
artifacts = ['cute-usb-service', 'cute-usb-control', 'CuteMixUSB.driver', 'Cute Mix USB.app']
for name in artifacts:
    path = base / name
    if not path.exists() or path.is_symlink():
        parser.error(f'Missing artifact or symlink: {path}')
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
app = plistlib.loads((base / 'Cute Mix USB.app/Contents/Info.plist').read_bytes())
hal = plistlib.loads((base / 'CuteMixUSB.driver/Contents/Info.plist').read_bytes())
if (app['CFBundleShortVersionString'], app['CFBundleVersion']) != ('0.3.0', '10'):
    parser.error('Expected app 0.3.0 / build 10')
if (hal['CFBundleShortVersionString'], hal['CFBundleVersion']) != ('0.1.6', '7'):
    parser.error('Expected HAL 0.1.6 / build 7')
for executable in ['cute-usb-service', 'cute-usb-control',
                   'CuteMixUSB.driver/Contents/MacOS/CuteMixUSB',
                   'Cute Mix USB.app/Contents/MacOS/Cute Mix USB']:
    if run('lipo', '-archs', str(base / executable)) != 'arm64':
        parser.error(f'Expected native arm64: {executable}')

output = root / 'build/release'
output.mkdir(parents=True, exist_ok=True)
prefix = f'CuteMotu-v{args.version}'
archive = output / f'{prefix}-macos-arm64.zip'
if archive.exists():
    parser.error(f'Release already exists: {archive}')
subprocess.run(['git', 'archive', '--format=zip', f'--prefix={prefix}/',
                '-o', str(archive), commit], cwd=root, check=True)
manifest = dict(project='CuteMotu', version=args.version, source_commit=commit,
                architecture='arm64', signing='ad-hoc; not notarized',
                app_version='0.3.0', app_build='10', hal_version='0.1.6', hal_build='7',
                files={})
with zipfile.ZipFile(archive, 'a', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name in artifacts:
        artifact = base / name
        paths = sorted(artifact.rglob('*')) if artifact.is_dir() else [artifact]
        for path in paths:
            if path.is_symlink():
                raise SystemExit(f'Refusing artifact symlink: {path}')
            if not path.is_file():
                continue
            relative = path.relative_to(root).as_posix()
            manifest['files'][relative] = hashlib.sha256(path.read_bytes()).hexdigest()
            z.write(path, f'{prefix}/{relative}')
    data = json.dumps(manifest, indent=2) + '\n'
    z.writestr(f'{prefix}/RELEASE-MANIFEST.json', data)
(output / 'RELEASE-MANIFEST.json').write_text(data)
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
(output / 'SHA256SUMS.txt').write_text(f'{checksum}  {archive.name}\n')
print(f'Packaged {archive.name}: {archive.stat().st_size:,} bytes')
print(f'Source commit: {commit}')
print(f'SHA-256: {checksum}')

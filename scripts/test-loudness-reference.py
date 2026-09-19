#!/usr/bin/env python3
"""Compare offline float fixtures against FFmpeg's independent ebur128 filter.

Requires scripts/test-analysis.sh and ffmpeg. No hardware is opened or played.
"""
import array
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
ffmpeg = shutil.which('ffmpeg')
if not ffmpeg:
    raise SystemExit('Install FFmpeg to run the optional independent loudness reference check.')
probe = root / 'build/tests/analysis-meter-tests'
results = []
with tempfile.TemporaryDirectory(prefix='cutemix-loudness-') as folder:
    for rate in [44100, 48000, 88200, 96000, 176400, 192000]:
        for case in ['mixed_spectrum', 'gated_levels']:
            # Six seconds: full 400-ms/3-s windows, at least 57 gating blocks.
            samples = array.array('f')
            for i in range(rate * 6):
                t = i / rate
                if case == 'gated_levels':
                    amplitude = 0 if t < 1 else 0.001 if t < 3 else 0.1
                    l = r = amplitude * math.sin(2 * math.pi * 997 * t)
                else:
                    l = 0.07 * math.sin(2*math.pi*60*t) + 0.05 * math.sin(2*math.pi*1000*t)
                    r = 0.09 * math.sin(2*math.pi*8000*t)
                samples.extend((l, r))
            path = Path(folder) / 'fixture.f32'
            with path.open('wb') as file:
                samples.tofile(file)
            actual = json.loads(subprocess.check_output([str(probe), str(rate), str(path)], text=True))
            reference = subprocess.run([ffmpeg, '-hide_banner', '-nostats', '-f', 'f32le', '-ar', str(rate),
                '-ac', '2', '-i', str(path), '-af', 'ebur128', '-f', 'null', '-'], capture_output=True, text=True, check=True)
            readings = re.findall(r'M:\s*([-\d.]+)\s+S:\s*([-\d.]+)\s+I:\s*([-\d.]+)', reference.stderr)
            if not readings:
                raise RuntimeError(reference.stderr)
            expected = dict(zip(['momentary', 'short_term', 'integrated'], map(float, readings[-1])))
            errors = {key: abs(actual[key]-expected[key]) for key in expected}
            # FFmpeg's display is rounded to 0.1 LU. Non-48-kHz filter mapping
            # adds small response differences; total allowed error is 0.15 LU.
            assert max(errors.values()) <= 0.15, (rate, case, actual, expected, errors)
            results.append({'rate':rate, 'case':case, 'actual':actual, 'ffmpeg':expected, 'absolute_error_lu':errors})
            print(f'PASS {rate} Hz {case}: max difference {max(errors.values()):.4f} LU')
output = root / 'build/tests/loudness-reference.json'
output.write_text(json.dumps({'reference':'FFmpeg ebur128', 'tolerance_lu':0.15, 'cases':results},indent=2)+'\n')
print(f'{len(results)} independent loudness comparisons passed; {output}')

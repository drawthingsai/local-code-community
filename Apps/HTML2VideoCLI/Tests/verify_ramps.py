#!/usr/bin/env python3
"""Verify ramped source-frame identity, audio timing, and preserved pitch against upstream values."""
import argparse
import array
import bisect
import json
import math
import pathlib
import struct
import subprocess
import tempfile
import wave

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=pathlib.Path)
parser.add_argument('--output', type=pathlib.Path)
parser.add_argument('--catalyst', action='store_true', help='Run the minimal UIKit host built by build_catalyst.py.')
args = parser.parse_args()
binary = args.binary.resolve()
root = args.output or pathlib.Path(tempfile.mkdtemp(prefix='html2video-ramps-'))
root.mkdir(parents=True, exist_ok=True)
tests = pathlib.Path(__file__).resolve().parent
repo = tests.parents[2]
subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(root / 'module-cache'),
                str(repo / 'Libraries/HTMLVideoExporter/Sources/HTMLVideoPlaybackRate.swift'),
                str(repo / 'Libraries/HTMLVideoExporter/Sources/HTMLVideoExportOptions.swift'),
                str(tests / 'PlaybackRateMain.swift'), '-o', str(root / 'rate-test')], check=True)
subprocess.run([str(root / 'rate-test'), str(tests / 'speed-ramp-reference.json')], check=True)
reference = json.loads((tests / 'speed-ramp-reference.json').read_text())

def export(page, output):
    command = [str(binary), str(page), str(output)] if args.catalyst else [str(binary), str(page), '-o', str(output), '--json']
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

export(tests / 'fixture.html', root / 'counter.mp4')
# Each source second has a distinct pitch; rate changes must move these boundaries
# without multiplying the pitch. This tests sound timing independently of picture.
with wave.open(str(root / 'tones.wav'), 'wb') as output:
    output.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
    for second in range(10):
        frequency = 400 + second * 200
        output.writeframes(b''.join(struct.pack('<h', round(12000 * math.sin(2 * math.pi * frequency * i / 48000))) for i in range(48000)))

def mapping(case, t):
    samples = case['samples']
    times = [p[0] for p in samples]
    hi = bisect.bisect_right(times, t)
    assert 0 < hi < len(times), t
    a, b = samples[hi - 1], samples[hi]
    return a[1] + (b[1] - a[1]) * (t - a[0]) / (b[0] - a[0])

frame_count = 0
audio_checks = []
scenarios = [(c, 0.5, False, False, 0.25) for c in reference['cases'][:6]]
scenarios += [(reference['cases'][0], 8, True, False, 0.25),
              (reference['cases'][0], 8, False, True, 0.25),
              (reference['cases'][1], 0.5, False, False, -0.25)]
for case, trim, loop, natural, start in scenarios:
    name = case['name'] + ('-loop' if loop else '-natural' if natural else '-negative' if start < 0 else '')
    lane = json.dumps({'version': 1, 'lanes': [{'target': 'rate', 'points': case['points']}, {'target': 'volume', 'points': [{'t': 0, 'v': 0.2}, {'t': 3.5, 'v': 0.8}]}]})
    duration = '' if natural else 'data-duration="3.5"'
    # Nested composition start + local clip start. A lane must override constant 3x.
    attrs = f'data-start="{start - 0.5}" {duration} data-media-start="{trim}" data-playback-rate="3" data-automation=\'{lane}\'' + (' loop' if loop else '')
    page = root / 'index.html'
    page.write_text(f'''<html><style>body{{margin:0;background:#000}}video{{width:640px;height:360px}}</style>
<div data-composition-id="main" data-width="640" data-height="360" data-duration="4">
<div data-composition-id="scene" data-start="0.5" data-duration="3.5">
<video src="counter.mp4" muted playsinline {attrs}></video>
<audio id="sound" src="tones.wav" {attrs}></audio></div></div></html>''')
    movie = root / (name + '.mp4')
    result = export(page, movie)
    assert result['frames'] == 120
    process = subprocess.Popen(['ffmpeg', '-v', 'error', '-i', str(movie), '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
    for index in range(120):
        frame = process.stdout.read(640 * 360 * 3)
        assert len(frame) == 640 * 360 * 3
        t = index / 30
        local = t - start
        source = mapping(case, local) if local >= 0 and local <= 4 else 0
        active = t >= max(start, 0.5) and local < 3.5 and (not natural or source < 10 - trim)
        if active:
            expected_time = trim + (source % (10 - trim) if loop else source)
            expected = min(299, math.floor((expected_time + 1e-6) * 30))
            actual = sum((frame[(10 * 640 + bit * 20 + 10) * 3] > 128) << bit for bit in range(9))
            assert actual == expected, (name, index, actual, expected, expected_time)
        else:
            assert max(frame[(90 * 640 + 50) * 3:(90 * 640 + 50) * 3 + 3]) < 25, (name, index, 'clip should be hidden')
        frame_count += 1
    assert not process.stdout.read(1)
    assert process.wait() == 0
    pcm = array.array('f', subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(movie), '-vn', '-af', 'apad=whole_dur=4', '-ar', '48000', '-ac', '1', '-f', 'f32le', '-']))
    # Check inside slices, away from source-tone changes and loop boundaries.
    lower = max(start, 0.5)
    upper = min(4, start + 3.5)
    slices = math.ceil((upper - lower) / 0.25)
    for i in range(slices):
        a = lower + i * (upper - lower) / slices
        b = lower + (i + 1) * (upper - lower) / slices
        middle = (a + b) / 2
        source = (mapping(case, a - start) + mapping(case, b - start)) / 2
        if natural and source >= 10 - trim: continue
        source = trim + (source % (10 - trim) if loop else source)
        if source >= 10 or source % 1 < 0.25 or source % 1 > 0.75: continue
        expected_frequency = 400 + math.floor(source) * 200
        window = pcm[round((middle - 0.025) * 48000):round((middle + 0.025) * 48000)]
        rms = math.sqrt(sum(x*x for x in window) / len(window))
        expected_rms = 12000 / 32768 / math.sqrt(2) * (0.2 + (middle - start) / 3.5 * 0.6)
        assert abs(rms - expected_rms) / expected_rms < 0.3, (name, middle, 'volume envelope/gap', rms, expected_rms)
        # Goertzel peak search: both source-second identification and pitch preservation.
        def power(frequency):
            coefficient = 2 * math.cos(2 * math.pi * frequency / 48000)
            one = two = 0
            for x in window:
                current = x + coefficient * one - two
                two, one = one, current
            return one * one + two * two - coefficient * one * two
        frequency = max(range(350, 2351, 10), key=power)
        assert abs(frequency - expected_frequency) <= 20, (name, middle, source, frequency, expected_frequency)
        audio_checks.append({'case': name, 'time': middle, 'frequency': frequency})
    if natural:
        tail = pcm[int(3 * 48000):int(3.9 * 48000)]
        assert math.sqrt(sum(x*x for x in tail) / len(tail)) < 0.001, 'Audio exceeded natural ramp duration'
assert len(audio_checks) >= 15, len(audio_checks)
print(json.dumps({'rampedFramesChecked': frame_count, 'audioPitchAndTimingChecks': len(audio_checks),
                  'upstream': reference['upstream'], 'artifacts': str(root)}, indent=2))

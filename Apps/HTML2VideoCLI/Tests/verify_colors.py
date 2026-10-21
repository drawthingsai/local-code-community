#!/usr/bin/env python3
"""Compare display colors in sRGB, including input profiles, alpha, and audio muxing.

FFmpeg is used only to generate test media. AVFoundation + CoreGraphics perform
reference and output decoding into the same named color space; raw RGB values
from differently tagged videos are not a valid color-fidelity comparison.
"""
import argparse
import json
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=pathlib.Path)
parser.add_argument('--catalyst', action='store_true')
parser.add_argument('--audio-fx', action='store_true')
parser.add_argument('--output', type=pathlib.Path)
args = parser.parse_args()
binary = args.binary.resolve()
root = args.output or pathlib.Path(tempfile.mkdtemp(prefix='html2video-colors-'))
root.mkdir(parents=True, exist_ok=True)
helper = root / 'color-samples'
subprocess.run(['xcrun', 'swiftc', str(pathlib.Path(__file__).with_name('ColorSamplesMain.swift')),
                '-o', str(helper)], check=True, capture_output=True)
colors = [(x, x, x) for x in (32, 64, 128, 192)] + [
    (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
    (255, 0, 255), (0, 255, 255), (64, 128, 192), (192, 128, 64),
    (64, 32, 96), (32, 96, 64), (200, 100, 150), (100, 200, 150),
]


def render(name, content, alpha=False, audio=False):
    page = root / (name + '.html')
    soundtrack = '<audio src="tone.wav" data-start="0" data-duration="0.2"></audio>' if audio else ''
    if args.audio_fx:
        soundtrack = soundtrack.replace('<audio ', '<audio data-fx-chain=\'{"version":1,"nodes":[{"type":"compressor"}]}\' ')
    page.write_text('''<!doctype html><html><style>
html,body{margin:0;width:100%;height:100%;background:transparent}
#root{width:512px;height:512px;position:relative;display:grid;grid-template-columns:repeat(4,128px);grid-template-rows:repeat(4,128px)}
video{position:absolute;width:100%;height:100%;inset:0}
</style><body><div id="root" data-composition-id="main" data-width="512" data-height="512" data-duration="0.2">'''
                    + content + soundtrack + '</div></body></html>')
    movie = root / (name + ('.mov' if alpha else '.mp4'))
    command = [str(binary), str(page)]
    command += [str(movie)] if args.catalyst else ['--output', str(movie), '--json']
    if alpha:
        command += ['--alpha']
    subprocess.run(command, check=True, capture_output=True, timeout=60)
    return movie


def samples(movie):
    return json.loads(subprocess.check_output([str(helper), str(movie)], text=True))


results = []


def check(name, movie, expected, tolerance=6):
    actual = samples(movie)
    errors = [max(abs(a - b) for a, b in zip(pixel[:3], reference[:3]))
              for pixel, reference in zip(actual, expected)]
    assert len(actual) == len(expected) == 16
    assert max(errors) <= tolerance, (name, max(errors), actual, expected)
    assert min(pixel[3] for pixel in actual) >= 250, (name, 'opaque patches lost alpha')
    results.append({'case': name, 'maxSRGBChannelError': max(errors)})


patches = ''.join('<div style="background:rgb(%d,%d,%d)"></div>' % color for color in colors)
subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                'sine=frequency=440:sample_rate=48000:duration=0.2', str(root / 'tone.wav')], check=True)
for alpha in (False, True):
    for audio in (False, True):
        name = 'css' + ('-alpha' if alpha else '') + ('-audio' if audio else '')
        check(name, render(name, patches, alpha=alpha, audio=audio), colors)

# Generate the same patch layout with different video color descriptions. Source
# appearance is measured through its actual profile rather than assumed to equal
# the untagged RGB input to FFmpeg.
ppm = root / 'patches.ppm'
with ppm.open('wb') as f:
    f.write(b'P6\n512 512\n255\n')
    for y in range(512):
        f.write(b''.join(bytes(colors[(y // 128) * 4 + x // 128]) for x in range(512)))
profiles = {
    'untagged': [],
    'srgb': ['-color_primaries', 'bt709', '-color_trc', 'iec61966-2-1', '-colorspace', 'bt709'],
    'bt709': ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709'],
    'bt601': ['-color_primaries', 'smpte170m', '-color_trc', 'smpte170m', '-colorspace', 'smpte170m'],
}
for profile, tags in profiles.items():
    source = root / (profile + '.mp4')
    subprocess.run(['ffmpeg', '-v', 'error', '-loop', '1', '-i', str(ppm), '-t', '0.2',
                    '-r', '30', '-c:v', 'libx264', '-crf', '10', '-pix_fmt', 'yuv420p',
                    *tags, str(source)], check=True)
    content = f'<video src="{source.name}" data-start="0" data-duration="0.2" muted playsinline></video>'
    expected = samples(source)
    name = 'video-' + profile
    check(name, render(name, content, audio=True), expected)

(root / 'results.json').write_text(json.dumps(results, indent=2))
print(json.dumps({'output': str(root), 'results': results}, indent=2))

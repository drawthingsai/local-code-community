#!/usr/bin/env python3
"""Check author-script viewport initialization in snapshot and export."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('exporter', type=Path)
parser.add_argument('--hyperframes', type=Path)
parser.add_argument('--uikit-inspector', type=Path)
parser.add_argument('--catalyst', action='store_true')
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix='html2video-viewport-'))


def run(command):
    result = subprocess.run(list(map(str, command)), capture_output=True, timeout=60)
    assert result.returncode == 0, (command, result.stdout[-1000:], result.stderr[-1000:])
    return result.stdout


def check(path, width, height):
    metadata = json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', path]))
    stream = metadata['streams'][0]
    assert (stream['width'], stream['height']) == (width, height), stream
    pixels = run(['ffmpeg', '-v', 'error', '-i', path, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'])
    # JS positions the box using innerWidth/innerHeight at initialization, including
    # a viewport media query. Resizing only after initialization cannot repair it.
    offset = (height // 2 * width + width // 2) * 3
    expected = (255, 0, 0) if width > height else (0, 0, 255)
    assert max(abs(a - b) for a, b in zip(pixels[offset:offset + 3], expected)) < 20, (path, pixels[offset:offset + 3], expected)


for width, height in [(320, 180), (180, 320)]:
    project = root / f'{width}x{height}'
    project.mkdir()
    page = project / 'index.html'
    page.write_text(f'''<!doctype html><html><head><style>
    html,body{{margin:0;background:white}}#root{{position:relative;width:100vw;height:100vh;overflow:hidden}}
    #box{{position:absolute;width:40px;height:40px}}</style></head><body>
    <!-- <div data-composition-id="fake" data-width="1920" data-height="1080"> -->
    <template><div data-composition-id="unused" data-width="1920" data-height="1080"></div></template>
    <div id="root" data-composition-id="root" data-width="{width}" data-height="{height}" data-duration="0.2" data-no-timeline><div id="box"></div></div>
    <script>const box=document.getElementById('box');
    box.style.left=(innerWidth/2-20)+'px';box.style.top=(innerHeight/2-20)+'px';
    box.style.background=matchMedia('(orientation: landscape)').matches?'red':'blue';</script>
    </body></html>''')
    movie = project / 'out.mp4'
    command = [args.exporter.resolve(), page]
    command += [movie] if args.catalyst else ['--output', movie, '--fps', '5']
    run(command)
    check(movie, width, height)
    if not args.catalyst:
        overridden = project / 'override.mp4'
        run([args.exporter.resolve(), page, '--output', overridden, '--width', '480', '--height', '240', '--fps', '5'])
        check(overridden, 480, 240)
    if args.hyperframes:
        run([args.hyperframes.resolve(), 'snapshot', project, '--at', '0'])
        check(project / 'snapshots/frame-00-at-0.000s.png', width, height)
    if args.uikit_inspector:
        shot = project / 'uikit.png'
        run([args.uikit_inspector.resolve(), page, shot])
        check(shot, width, height)
print(f'PASS: initial viewport, media queries, declaration parsing, and export overrides ({root})')

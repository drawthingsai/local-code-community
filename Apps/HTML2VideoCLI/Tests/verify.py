#!/usr/bin/env python3
"""Black-box exporter tests. ffmpeg/ffprobe are test-only dependencies."""
import argparse
import array
import json
import math
import pathlib
import signal
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=pathlib.Path)
parser.add_argument('--output', type=pathlib.Path)
parser.add_argument('--hyperframes-runtime', type=pathlib.Path)
parser.add_argument('--gsap', type=pathlib.Path)
args = parser.parse_args()
binary = args.binary.resolve()
root = args.output or pathlib.Path(tempfile.mkdtemp(prefix='html2video-test-'))
root.mkdir(parents=True, exist_ok=True)
fixture = pathlib.Path(__file__).with_name('fixture.html')

def run(*arguments, success=True):
    result = subprocess.run([str(binary), *map(str, arguments)], capture_output=True, text=True, timeout=60)
    assert (result.returncode == 0) == success, (arguments, result.stdout, result.stderr)
    return result

def probe(path):
    return json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-count_frames', '-show_streams', '-of', 'json', str(path)]))['streams']

def frames(path):
    process = subprocess.Popen(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
    while True:
        frame = process.stdout.read(640 * 360 * 3)
        if not frame:
            break
        assert len(frame) == 640 * 360 * 3
        yield frame
    assert process.wait() == 0

def pixel(frame, x, y):
    offset = (y * 640 + x) * 3
    return frame[offset:offset + 3]

def identity(frame):
    return sum((pixel(frame, bit * 20 + 10, 10)[0] > 128) << bit for bit in range(9))

def check(frame, x, y, expected):
    actual = pixel(frame, x, y)
    assert max(abs(a - b) for a, b in zip(actual, expected)) < 40, (x, y, tuple(actual), expected)

movie = root / 'animation.mp4'
assert run('--version').stdout.strip() == '1.0.0'
assert '--version' in run('--help').stdout
started = time.monotonic()
result = json.loads(run(fixture, '-o', movie, '--json').stdout)
assert result['frames'] == 300 and result['duration'] == 10
metadata = probe(movie)[0]
assert metadata['codec_name'] == 'h264' and metadata['nb_read_frames'] == '300'
assert (metadata['width'], metadata['height'], metadata['r_frame_rate']) == (640, 360, '30/1')
count = 0
for index, frame in enumerate(frames(movie)):
    assert identity(frame) == index, ('animation identity', index, identity(frame))
    check(frame, 50, 90, (0, 255, 0) if index % 2 else (255, 0, 0))
    check(frame, 170, 90, (255, 0, 255) if index % 2 else (0, 0, 255))
    check(frame, 290, 90, (0, 255, 255) if index % 2 else (255, 255, 0))
    check(frame, 430, 100, (255, 128, 0))
    check(frame, 30 + index, 220, (255, 255, 255))
    check(frame, round(30 + 299 * index / 300), 260, (255, 128, 0))
    count += 1
assert count == 300
original = movie.read_bytes()
run(fixture, '-o', movie, success=False)
assert movie.read_bytes() == original
run(fixture, '-o', root / 'invalid.mp4', '--fps', '0', success=False)
run(fixture, '-o', root / 'odd.mp4', '--width', '641', success=False)

fractional = root / 'fractional.mp4'
run(fixture, '-o', fractional, '--duration', '1', '--fps', '30000/1001')
metadata = probe(fractional)[0]
assert metadata['nb_read_frames'] == '30' and metadata['r_frame_rate'] == '30000/1001'
assert abs(float(metadata['duration']) - 1.001) < 0.001

# An independent source tone, combined with the previously verified frame counter.
subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=4', '-af', 'adelay=1000:all=1', str(root / 'tone.wav')], check=True)
page = root / 'index.html'
page.write_text('''<html><style>body{margin:0;background:#000}video{width:640px;height:360px}</style>
<div data-composition-id="main" data-width="640" data-height="360" data-duration="4">
<div data-composition-id="scene" data-start="1" data-duration="3">
<video src="animation.mp4" data-start="0.5" data-duration="2" data-media-start="2" data-playback-rate="2" muted playsinline></video>
<audio id="tone" src="tone.wav" data-start="0" data-duration="2" data-media-start="1"
data-automation='{"version":1,"lanes":[{"target":"volume","points":[{"t":0,"v":0},{"t":1,"v":1},{"t":2,"v":0}]}]}'></audio>
</div></div></html>''')
media = root / 'media.mp4'
run(root, '-o', media)
streams = probe(media)
assert {s['codec_name'] for s in streams} == {'h264', 'aac'}
assert next(s for s in streams if s['codec_name'] == 'h264')['nb_read_frames'] == '120'
for index, frame in enumerate(frames(media)):
    if 45 <= index < 105:
        expected = 60 + (index - 45) * 2
        assert identity(frame) == expected, ('media trim/rate/offset', index, identity(frame), expected)
    else:
        check(frame, 50, 90, (0, 0, 0))
samples = array.array('f', subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(media), '-vn', '-af', 'apad=whole_dur=4', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-']))
def rms(a, b):
    chunk = samples[round(a * 48000):round(b * 48000)]
    return math.sqrt(sum(x * x for x in chunk) / len(chunk))
assert rms(0.1, 0.8) < 0.001 and rms(3.2, 3.8) < 0.001
assert rms(1.8, 2.2) > 3 * rms(1.1, 1.2)
assert rms(1.8, 2.2) > 3 * rms(2.8, 2.9)
assert rms(1.8, 2.2) > 0.04

# Loop after a source trim, and sample an authored audio volume tween.
page.write_text('''<html><style>body{margin:0}video{width:640px;height:360px}</style>
<video src="animation.mp4" data-start="0" data-duration="2.5" data-media-start="9" muted playsinline loop></video>
<audio id="tone" src="tone.wav" data-start="0" data-duration="2.5" data-media-start="4" data-playback-rate="1.5" loop></audio>
<script>window.html2video={width:640,height:360,duration:2.5,seek: seconds => {
 document.querySelector('audio').volume = Math.min(1, seconds / 2);
}};</script></html>''')
looped = root / 'loop.mp4'
run(root, '-o', looped)
for index, frame in enumerate(frames(looped)):
    assert identity(frame) == 270 + index % 30, ('loop identity', index, identity(frame))
samples = array.array('f', subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(looped), '-vn', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-']))
assert rms(2.1, 2.4) > 5 * rms(0.1, 0.3), 'Sampled volume tween or loop failed'

# Root variables must be available before author scripts and applied to CSS bindings.
page.write_text('''<html data-composition-variables='[{"id":"accent","default":"#ff0000"}]'>
<style>body{margin:0;background:var(--accent)}</style><script>
if(window.__hyperframes.getVariables().accent !== '#00ff00') throw Error('Variable override missing at initialization');
window.html2video={width:640,height:360,duration:0.1};</script></html>''')
values = root / 'values.json'
values.write_text('{"accent":"#00ff00"}')
run(root, '-o', root / 'variables.mp4', '--variables-file', values)
for frame in frames(root / 'variables.mp4'): check(frame, 100, 100, (0, 255, 0))

if args.hyperframes_runtime or args.gsap:
    assert args.hyperframes_runtime and args.gsap, 'Supply both runtime and GSAP paths'
    shutil.copyfile(args.hyperframes_runtime, root / 'runtime.js')
    shutil.copyfile(args.gsap, root / 'gsap.js')
    page.write_text('''<html data-composition-variables='[{"id":"accent","default":"#ff0000"}]'>
    <script src="gsap.js"></script><script src="runtime.js"></script>
    <style>body{margin:0;background:#000}#box{position:absolute;top:30px;width:20px;height:20px}</style>
    <div data-composition-id="main" data-width="640" data-height="360" data-duration="2"><div id="box"></div></div>
    <script>document.querySelector('#box').style.background=window.__hyperframes.getVariables().accent;
    window.__timelines.main=gsap.timeline({paused:true}).to('#box',{x:120,duration:2,ease:'none'});</script></html>''')
    run(root, '-o', root / 'hyperframes.mp4', '--fps', '60', '--variables-file', values)
    for index, frame in enumerate(frames(root / 'hyperframes.mp4')):
        check(frame, index + 10, 40, (0, 255, 0))

# A stalled author promise and SIGINT must both remove partial output.
# Keep the resolver reachable so WebKit waits instead of rejecting a discarded promise.
page.write_text('<script>window.pendingSeek=new Promise(resolve=>{window.finishSeek=resolve});window.html2video={width:640,height:360,duration:1,seek:()=>window.pendingSeek}</script>')
run(root, '-o', root / 'timeout.mp4', '--timeout', '0.5', success=False)
process = subprocess.Popen([str(binary), str(root), '-o', str(root / 'cancel.mp4')], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
time.sleep(1)
process.send_signal(signal.SIGINT)
process.communicate(timeout=10)
assert process.returncode == 130, process.returncode
assert not (root / 'timeout.mp4').exists() and not (root / 'cancel.mp4').exists()
assert not list(root.glob('.html2video-*')), 'Leaked partial exports'
page.write_text('<img src="missing.png"><script>window.html2video={width:640,height:360,duration:1}</script>')
run(root, '-o', root / 'missing.mp4', success=False)
assert not (root / 'missing.mp4').exists()
print(json.dumps({'animationFramesChecked': 300, 'mediaFramesChecked': 195, 'fractionalFPS': '30000/1001',
                  'audio': 'AAC, offset, source trim, loop, fade envelope, sampled volume and silence verified',
                  'hyperframesRuntime': bool(args.hyperframes_runtime),
                  'failuresAndCancellation': 'passed', 'elapsedSeconds': time.monotonic() - started, 'artifacts': str(root)}, indent=2))

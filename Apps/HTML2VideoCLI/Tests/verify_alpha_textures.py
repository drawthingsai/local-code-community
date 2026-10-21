#!/usr/bin/env python3
"""Native alpha-plane + decoded-video texture regression; FFmpeg is test-only."""
import argparse
import array
import json
import math
import pathlib
import struct
import shutil
import subprocess
import tempfile
import wave

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=pathlib.Path)
parser.add_argument('--catalyst', action='store_true')
parser.add_argument('--output', type=pathlib.Path)
parser.add_argument('--hyperframes-runtime', type=pathlib.Path)
args = parser.parse_args()
binary = args.binary.resolve()
root = args.output or pathlib.Path(tempfile.mkdtemp(prefix='html2video-alpha-textures-'))
root.mkdir(parents=True, exist_ok=True)
tests = pathlib.Path(__file__).resolve().parent
reader = root / 'native-frames'
subprocess.run(['xcrun', 'swiftc', str(tests / 'NativeFramesMain.swift'), '-o', str(reader),
                '-module-cache-path', '/tmp/html2video-rate-module-cache'], check=True, capture_output=True)

def export(page, name, alpha=True, extra=(), success=True):
    output = root / name
    command = [str(binary), str(page), str(output)] if args.catalyst else [str(binary), str(page), '-o', str(output), '--json']
    if alpha: command += ['--alpha']
    result = subprocess.run(command + list(extra), capture_output=True, text=True, timeout=90)
    assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
    if success:
        data = json.loads(result.stdout)
        assert data['frames'] == 30, data
    return output

def read(movie):
    raw = movie.with_suffix('.bgra')
    meta = json.loads(subprocess.check_output([str(reader), str(movie), str(raw)]))
    assert len(meta['times']) == 30
    assert all(abs(t-i/30) < 1e-6 for i,t in enumerate(meta['times']))
    return raw.read_bytes(), meta['width'], meta['height']

def pixel(movie, frame, x, y):
    data,w,h = movie
    offset = ((frame*h+y)*w+x)*4
    b,g,r,a = data[offset:offset+4]
    return r,g,b,a

def check(actual, expected, label, tolerance=35):
    assert max(abs(a-b) for a,b in zip(actual,expected)) <= tolerance, (label, actual, expected)

source_page = root / 'source.html'
source_page.write_text('''<style>html,body{margin:0;background:transparent}
.box{position:absolute;top:0;width:64px;height:64px}
#red{left:0;background:red}#green{left:64px;background:#0f0}
#blue{left:128px;background:rgba(0,0,255,.25)}</style>
<div id=red class=box></div><div id=green class=box></div><div id=blue class=box></div>
<script>window.html2video={width:256,height:64,duration:1,seek(t){
 document.querySelector('#red').style.opacity=Math.round(t*30)%2?.75:.25;
}}</script>''')
source = export(source_page, 'source.mov')
source_frames = read(source)
for i in range(30):
    alpha = 191 if i%2 else 64
    check(pixel(source_frames,i,32,32),(alpha,0,0,alpha),('source red',i))
    check(pixel(source_frames,i,96,32),(0,255,0,255),('source green',i))
    check(pixel(source_frames,i,160,32),(0,0,64,64),('source blue',i))
    check(pixel(source_frames,i,224,32),(0,0,0,0),('source clear',i),3)

with wave.open(str(root/'tone.wav'),'wb') as out:
    out.setparams((1,2,48000,0,'NONE','not compressed'))
    out.writeframes(b''.join(struct.pack('<h',round(10000*math.sin(2*math.pi*440*i/48000))) for i in range(48000)))
page = root / 'textures.html'
html = (tests/'textures.html').read_text()
for audio in [False, True]:
    page.write_text(html + ('<audio src="tone.wav" data-duration="1"></audio>' if audio else ''))
    movie = export(page, 'textures-audio.mov' if audio else 'textures.mov')
    decoded = read(movie)
    for i in range(30):
        for row in range(4):
            for x in [32,96,160,224]:
                actual = pixel(decoded,i,x,row*64+32)
                expected = pixel(source_frames,i,x,32)
                # Each encode is lossy; require alpha fidelity and bounded color error.
                check(actual, expected, ('texture',audio,i,row,x),45)
                assert abs(actual[3]-expected[3]) <= 4, ('alpha',audio,i,row,x,actual,expected)
                # Verify compositing over both black and white, including premultiplication.
                for background in [0,255]:
                    composite = tuple(c + background*(1-actual[3]/255) for c in actual[:3])
                    reference = tuple(c + background*(1-expected[3]/255) for c in expected[:3])
                    check(composite,reference,('composite',audio,i,row,x,background),45)
    metadata = json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(movie)]))['streams']
    assert next(s for s in metadata if s['codec_type']=='video')['codec_name'] == 'hevc'
    if audio:
        assert any(s['codec_type']=='audio' for s in metadata)
        pcm = array.array('f',subprocess.check_output(['ffmpeg','-v','error','-i',str(movie),'-vn','-ac','1','-f','f32le','-']))
        rms = math.sqrt(sum(v*v for v in pcm)/len(pcm))
        assert .15 < rms < .3, rms

# A second instance may reuse the author id and source while seeking another time.
page.write_text(html + '''<video id="source" src="source.mov" data-media-start="0.1" data-duration="1"
 style="display:none" muted playsinline></video><script>
const second=document.querySelectorAll('video')[1];
const originalSeek=window.html2video.seek;
window.html2video.seek=t=>{
 originalSeek(t);
 if (second.dataset.hfRenderId===video.dataset.hfRenderId) throw new Error('Duplicate render identity');
 ctx.drawImage(second,0,0,64,64,192,0,64,64);
};</script>''')
duplicate = read(export(page,'duplicate.mov'))
for i in range(30):
    expected=pixel(source_frames,min(i+3,29),32,32)
    check(pixel(duplicate,i,224,96),expected,('duplicate source instance',i),45)

if args.hyperframes_runtime:
    shutil.copyfile(args.hyperframes_runtime,root/'runtime.js')
    runtime_html = html.replace('<!doctype html>', '')
    page.write_text('''<script src="runtime.js"></script>
<div data-composition-id="main" data-width="256" data-height="256" data-duration="1">''' + runtime_html + '''
<script>
const exportSeek=window.html2video.seek;
delete window.html2video;
addEventListener('hf-seek',event=>{
 if (window.__html2videoFrames.get(video)?.image.naturalWidth)
   event.detail.waitUntil(new Promise(resolve=>setTimeout(()=>{exportSeek(event.detail.time);resolve();},5)));
});</script></div>''')
    runtime_frames=read(export(page,'runtime.mov'))
    for i in range(30):
        for row in range(4):
            for x in [32,96,160,224]:
                check(pixel(runtime_frames,i,x,row*64+32),pixel(source_frames,i,x,32),('runtime',i,row,x),45)

# Exercise the alpha capture API itself with screen styles, transformed DOM,
# CSS filters, SVG, and independently drawn Canvas/WebGL pixels.
composition = root / 'composition.html'
composition.write_text('''<style>html,body{margin:0;background:transparent}
#moving{position:absolute;width:8px;height:16px;top:0;background:rgba(255,0,0,.5)}
#filter{position:absolute;left:64px;top:0;width:32px;height:32px;background:red;filter:opacity(.5)}
canvas{position:absolute;width:64px;height:64px;top:64px}#gl{left:64px}
@media print{#moving{background:black!important}}</style>
<div id=moving></div><div id=filter></div>
<svg style="position:absolute;top:32px;left:64px" width=32 height=32><rect width=32 height=32 fill="blue" opacity=".25"/></svg>
<canvas id=canvas width=64 height=64></canvas><canvas id=gl width=64 height=64></canvas>
<script>
const ctx=document.querySelector('#canvas').getContext('2d');
const gl=document.querySelector('#gl').getContext('webgl',{preserveDrawingBuffer:true});
window.html2video={width:128,height:128,duration:1,seek(t){
 const index=Math.round(t*30);
 document.querySelector('#moving').style.transform='translateX('+index+'px)';
 ctx.clearRect(0,0,64,64);ctx.fillStyle='rgba(0,255,0,.5)';ctx.fillRect(0,0,64,64);
 gl.clearColor(0,0,.5,.5);gl.clear(gl.COLOR_BUFFER_BIT);
}};</script>''')
composed = read(export(composition,'composition.mov'))
for i in range(30):
    check(pixel(composed,i,i+4,8),(128,0,0,128),('moving screen DOM',i))
    check(pixel(composed,i,80,16),(128,0,0,128),('CSS filter',i))
    check(pixel(composed,i,80,48),(0,0,64,64),('SVG',i))
    check(pixel(composed,i,32,96),(0,128,0,128),('Canvas alpha',i))
    check(pixel(composed,i,96,96),(0,0,128,128),('WebGL alpha',i))
    check(pixel(composed,i,48,48),(0,0,0,0),('clear canvas',i),3)

# H.264 MOV output and invalid container/alpha combinations exercise CLI validation.
if not args.catalyst:
    export(source_page,'opaque.mov',alpha=False,extra=['--format','mov'])
    export(source_page,'invalid.mp4',extra=['--format','mp4'],success=False)
    export(source_page,'mismatch.mov',alpha=False,extra=['--format','mp4'],success=False)
    assert not (root/'invalid.mp4').exists() and not (root/'mismatch.mov').exists()
assert not list(root.glob('.html2video-*'))
print(f'Passed: 30 alpha source frames, 240 DOM/Canvas/WebGL1/WebGL2 frame checks, 30 composition frames, duplicate render IDs, audio mix, native alpha decoding: {root}')

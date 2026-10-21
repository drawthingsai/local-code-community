#!/usr/bin/env python3
"""Snapshot colors and alpha in a common sRGB space; FFmpeg only creates test inputs."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary=Path(sys.argv[1]).resolve()
uikit=Path(sys.argv[2]).resolve() if len(sys.argv)>2 else None
root=Path(tempfile.mkdtemp(prefix='hyperframes-snapshot-colors-'))
helper=root/'samples'
subprocess.run(['xcrun','swiftc',str(Path(__file__).with_name('ColorSamplesMain.swift')),'-o',str(helper)],check=True,capture_output=True)
colors=[(v,v,v) for v in [32,64,128,192]]+[(255,0,0),(0,255,0),(0,0,255),(255,255,0),(255,0,255),(0,255,255),(64,128,192),(192,128,64),(64,32,96),(32,96,64),(200,100,150),(100,200,150)]
def samples(path): return json.loads(subprocess.check_output([str(helper),str(path)],text=True))
def capture(name,content,zoom=False):
    project=root/name
    project.mkdir(exist_ok=True)
    (project/'index.html').write_text('''<!doctype html><html><style>html,body{margin:0;background:transparent}#root{width:512px;height:512px;position:relative;display:grid;grid-template-columns:repeat(4,128px);grid-template-rows:repeat(4,128px)}video{position:absolute;width:100%;height:100%;inset:0}</style><body><div id="root" data-composition-id="main" data-width="512" data-height="512" data-duration=".2" data-no-timeline>'''+content+'</div></body></html>')
    command=[str(binary),'snapshot',str(project),'--at','0']
    if zoom: command+=['--zoom','0,0,512,512','--zoom-scale','3']
    if uikit:
        html=subprocess.check_output([str(binary),'__compile',str(project),'--entry','index.html'],text=True)
        (project/'compiled.html').write_text(html)
        target=project/'snapshot.png'
        command=[str(uikit),str(project/'compiled.html'),str(target)]+(['0,0,512,512'] if zoom else [])
    else: target=project/'snapshots/frame-00-at-0.000s.png'
    subprocess.run(command,check=True,capture_output=True,timeout=45)
    return target
results=[]
def check(name,image,expected,tolerance=2):
    actual=samples(image)
    error=max(abs(a-b) for pixel,reference in zip(actual,expected) for a,b in zip(pixel,reference))
    assert error<=tolerance,(name,error,actual,expected,str(root))
    results.append({'case':name,'maxSRGBChannelError':error})
for alpha in [1,.5]:
    patches=''.join('<div style="background:rgba(%d,%d,%d,%s)"></div>'%(*color,alpha) for color in colors)
    expected=[[round(c*alpha) for c in color]+[round(255*alpha)] for color in colors]
    for zoom in [False,True]:
        name=f'css-alpha-{alpha}-zoom-{zoom}'
        check(name,capture(name,patches,zoom),expected)
ppm=root/'patches.ppm'
with ppm.open('wb') as file:
    file.write(b'P6\n512 512\n255\n')
    for y in range(512): file.write(b''.join(bytes(colors[y//128*4+x//128]) for x in range(512)))
profiles={'untagged':[],'srgb':['-color_primaries','bt709','-color_trc','iec61966-2-1','-colorspace','bt709'],'bt709':['-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709'],'bt601':['-color_primaries','smpte170m','-color_trc','smpte170m','-colorspace','smpte170m']}
for profile,tags in profiles.items():
    source=root/(profile+'.mp4')
    subprocess.run(['ffmpeg','-v','error','-loop','1','-i',str(ppm),'-t','0.2','-r','30','-c:v','libx264','-crf','10','-pix_fmt','yuv420p',*tags,str(source)],check=True)
    # Copy into each composition: media is project-local, matching the CLI contract.
    for zoom in [False,True]:
        name=f'video-{profile}-zoom-{zoom}'
        # capture creates its project; reference a project-local symlink to the test source.
        import shutil
        project=root/name
        project.mkdir(exist_ok=True)
        shutil.copyfile(source,project/source.name)
        image=capture(name,f'<video src="{source.name}" data-start="0" data-duration=".2" muted playsinline></video>',zoom)
        check(name,image,samples(source),tolerance=3)
stripes='<svg width="512" height="512" viewBox="0 0 1536 1536">'+''.join(f'<rect x="{x}" width="1" height="1536" fill="{"red" if x%2 else "blue"}"/>' for x in range(1536))+'</svg>'
striped=capture('vector-density',stripes,True)
subprocess.run([str(helper),str(striped),'stripes'],check=True,capture_output=True)
(root/'results.json').write_text(json.dumps(results,indent=2))
print(json.dumps({'output':str(root),'results':results},indent=2))

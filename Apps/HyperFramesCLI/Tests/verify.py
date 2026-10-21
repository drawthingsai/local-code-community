#!/usr/bin/env python3
"""End-to-end CLI contracts. Runs actual NodeMobile, WebKit, and AVFoundation."""
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import wave
import urllib.error
import urllib.request

binary = str(Path(sys.argv[1]).resolve())
root = Path(tempfile.mkdtemp(prefix="hyperframes-verify-"))

def run(*args, status=0):
    result = subprocess.run([binary, *map(str, args)], capture_output=True, text=True, timeout=60)
    assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout

def report(*args, status=0):
    return json.loads(run(*args, "--json", status=status))

def size(path):
    return struct.unpack(">II", path.read_bytes()[16:24])

project = root / "project"
assert run("--version").strip() == "0.8.78"
assert "--version" in run("--help")
assert report("init", project, "--non-interactive", "--resolution", "portrait")["height"] == 1920
assert report("lint", project)["ok"]
assert report("compositions", project)["compositions"][0]["id"] == "root"
assert report("timeline", project)["duration"] == 5
# The scaffold title is invisible at time zero. Skips belong on stderr, including
# when every requested crop is invisible and the command returns a JSON error.
for at, status in [("0,1", 0), ("0", 1)]:
    result = subprocess.run([binary, "snapshot", str(project), "--at", at,
                             "--zoom", "#title", "--zoom-scale", "1", "--json"],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == status, result.stderr
    assert "Skipped collapsed zoom region at 0s" in result.stderr
    data = json.loads(result.stdout)
    if status == 0:
        assert data["files"] == ["snapshots/frame-01-at-1.000s.png", "snapshots/contact-sheet.png"], data
    else:
        assert data["ok"] is False and data["error"] == "No visible snapshot regions", data
run("init", project, status=1)
run("snapshot", project, "--at", "1", "--zoom", "#absent", status=1)
run("snapshot", project, "--at", "1", "--zoom", "10,20,100,50", "--zoom-scale", "3")
assert size(project / "snapshots/frame-00-at-1.000s.png") == (300, 150)

base = '''<!doctype html><html><head><script src="assets/gsap.min.js"></script>
<style>html,body{margin:0;background:#fff}#root{position:relative;width:320px;height:180px;overflow:hidden}#box{position:absolute;left:10px;top:20px;width:60px;height:40px;background:red}#label{position:absolute;left:100px;top:80px;font:24px Arial;color:#111}</style></head>
<body><div id="root" data-composition-id="root" data-width="320" data-height="180" data-duration="2"><div id="box"></div><div id="label">Readable</div>EXTRA</div><script>window.__timelines={root:gsap.timeline({paused:true}).to('#box',{x:160,duration:2,ease:'none'})};</script></body></html>'''
(project / "index.html").write_text(base.replace("EXTRA", ""))
clean = report("check", project, "--samples", 3, "--at-transitions", "--snapshots")
assert clean["ok"] and clean["contrast"]["checked"] > 0, clean
assert clean["snapshots"]["files"]
run("snapshot", project, "--at", "0,1,1.9")
assert (project / "snapshots/frame-00-at-0.000s.png").read_bytes() != (project / "snapshots/frame-01-at-1.000s.png").read_bytes()
assert (project / "snapshots/contact-sheet.png").exists()

(project / "index.motion.json").write_text(json.dumps({"assertions":[{"kind":"appearsBy","selector":"#missing","bySec":1}]}))
bad_motion = report("check", project, "--samples", 3, "--no-contrast", status=1)
assert any(f["code"] == "motion_selector_missing" for f in bad_motion["motion"]["findings"]), bad_motion
(project / "index.motion.json").unlink()
(project / "index.html").write_text(base.replace("EXTRA", "").replace("color:#111", "color:#eee"))
bad_contrast = report("check", project, "--samples", 3, "--snapshots", status=1)
assert bad_contrast["contrast"]["errorCount"] > 0, bad_contrast
assert bad_contrast["snapshots"]["findingFiles"], bad_contrast
assert all("undefined" not in name and (project / name).exists() for name in bad_contrast["snapshots"]["findingFiles"])

(project / "index.html").write_text(base.replace("EXTRA", "").replace("window.__timelines=", "console.error('intentional failure');window.__timelines="))
runtime = report("check", project, "--no-contrast", status=1)
assert runtime["runtime"]["errorCount"] > 0, runtime

(project / "index.html").write_text(base.replace("EXTRA", '<div id="child" class="clip" data-start="0" data-duration="2" data-composition-id="child" data-composition-src="child.html"></div>'))
(project / "child.html").write_text('<template><div data-composition-id="child" data-width="320" data-height="180" data-duration="2"><div style="position:absolute;left:250px;top:20px;width:40px;height:40px;background:blue"></div></div></template>')
run("snapshot", project, "--at", "1")
assert size(project / "snapshots/frame-00-at-1.000s.png") == (320, 180)
assert len(report("compositions", project)["compositions"]) == 2

# Media metadata and decoded video frames use AVFoundation, with no ffprobe at runtime.
subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=red:s=64x64:d=2:r=30','-c:v','libx264','-pix_fmt','yuv420p',str(project/'clip.mp4')],check=True)
with wave.open(str(project/'tone.wav'),'wb') as audio:
    audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(48000); audio.writeframes(b'\0\0'*96000)
media='<video id="video" class="clip" src="clip.mp4" data-start="0" muted playsinline style="position:absolute;left:0;top:0;width:64px;height:64px"></video><audio id="audio" class="clip" src="tone.wav" data-start="0"></audio>'
(project/'index.html').write_text(base.replace('EXTRA',media))
timeline=report('timeline',project)
media_rows=[row for track in timeline['tracks'] if track['kind'] in ['video','audio'] for row in track['rows']]
assert len(media_rows)==2 and all(abs(row['duration']-2)<.01 for row in media_rows), timeline
run('snapshot',project,'--at','1')
(project/'child.html').unlink()
(project/'tone.wav').unlink()
# Caption-zone geometry is evaluated by the same driver as layout.
(project/'index.html').write_text(base.replace('EXTRA','').replace('id="label"','id="label" class="caption-group"'))
zone=report('check',project,'--samples',3,'--no-contrast','--caption-zone','x0=0;y0=0;x1=1;y1=1;severity=error;seek=.5,1',status=1)
assert any('caption' in f['code'] for f in zone['layout']['findings']), zone

(project / "index.html").write_text(base.replace("EXTRA", ""))
with subprocess.Popen([binary, "preview", str(project), "--foreground", "--no-open", "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as server:
    try:
        # Read the pretty-printed readiness object without waiting for the foreground process.
        lines=[]
        while True:
            lines.append(server.stdout.readline())
            if lines[-1].strip() == "}": break
        url=json.loads(''.join(lines))["url"]
        assert b"hyperframes-player" in urllib.request.urlopen(url).read()
        assert b"Readable" in urllib.request.urlopen(url+"__hyperframes_composition.html").read()
        (project / "index.html").write_text(base.replace("EXTRA", "").replace("Readable", "Refreshed"))
        assert b"Refreshed" in urllib.request.urlopen(url+"__hyperframes_composition.html").read()
        request=urllib.request.Request(url+"assets/gsap.min.js", headers={"Range":"bytes=0-7"})
        response=urllib.request.urlopen(request)
        assert response.status == 206 and len(response.read()) == 8
        (root / "secret.html").write_text("private")
        (project / "escape").symlink_to(root)
        try: urllib.request.urlopen(url+"escape/secret.html")
        except urllib.error.HTTPError as error: assert error.code == 403
        else: raise AssertionError("Escaping symlink was served")
    finally:
        server.send_signal(signal.SIGINT)
        server.communicate(timeout=10)
        assert server.returncode == 130, server.returncode
island='<script type="application/hyperframes-slideshow+json">{"slides":[{"sceneId":"scene-one"},{"sceneId":"scene-two","fragments":[1.5]}]}</script>'
scenes='<div data-composition-id="scene-one" data-start="0" data-duration="1"></div><div data-composition-id="scene-two" data-start="1" data-duration="1"></div>'
(project/'index.html').write_text(base.replace('EXTRA',scenes+island))
with subprocess.Popen([binary,'present',str(project),'--no-open','--json'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) as server:
    try:
        lines=[]
        while True:
            lines.append(server.stdout.readline())
            if lines[-1].strip()=='}': break
        url=json.loads(''.join(lines))['url']
        html=urllib.request.urlopen(url).read()
        assert b'<hyperframes-slideshow tabindex="0" sound>' in html and b'fragments' in html and b'hf-sfx' in html
        assert b'scene-two' in urllib.request.urlopen(url+'__hyperframes_composition.html').read()
        assert urllib.request.urlopen(url+'assets/hyperframes-slideshow.global.js').status==200
    finally:
        server.send_signal(signal.SIGINT);server.communicate(timeout=10)
        assert server.returncode==130
print(f"PASS: scaffold, lint, timeline, compositions, animation, zoom, nested HTML, contrast, motion, runtime errors, live preview, ranges, containment, cancellation ({root})")

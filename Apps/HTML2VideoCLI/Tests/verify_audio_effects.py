#!/usr/bin/env python3
"""End-to-end Web Audio FX checks against decoded exported sound (ffmpeg test-only)."""
import argparse
import array
import html
import json
import math
import pathlib
import signal
import subprocess
import tempfile
import time
import wave

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=pathlib.Path)
parser.add_argument('--catalyst', action='store_true')
args = parser.parse_args()
binary = args.binary.resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix='html2video-fx-test-'))
print(root, flush=True)
rate = 48000

def tone(name, amplitude=.2, duration=1, frequencies=(440, 660)):
    samples = array.array('h')
    for i in range(round(duration * rate)):
        for frequency in frequencies:
            samples.append(round(amplitude * 32767 * math.sin(i * frequency * 2 * math.pi / rate)))
    with wave.open(str(root / name), 'wb') as output:
        output.setparams((len(frequencies), 2, rate, 0, 'NONE', 'not compressed'))
        output.writeframes(samples.tobytes())

def attr(value):
    return html.escape(json.dumps(value, separators=(',', ':')), quote=True)

def chain(kind, params=None):
    return {'version': 1, 'nodes': [{'id': 'n1', 'type': kind, 'params': params or {}}]}

def audio(fx=None, source='tone.wav', **attributes):
    attributes = {'src': source, **attributes}
    if fx is not None:
        attributes['data-fx-chain'] = json.dumps(fx)
    return '<audio ' + ' '.join(f'{key}="{html.escape(str(value), quote=True)}"' for key, value in attributes.items()) + '></audio>'

def render(name, body, duration=1.5, success=True, runtime=False):
    page, movie = root / (name + '.html'), root / (name + '.mp4')
    scripts = ''
    timeline = ''
    if runtime:
        resources = pathlib.Path(__file__).resolve().parents[2] / 'HyperFramesCLI/Resources/HyperFrames'
        for asset in ['gsap.min.js', 'hyperframe.runtime.iife.js']:
            (root / asset).write_bytes((resources / asset).read_bytes())
            scripts += f'<script src="{asset}"></script>'
        timeline = f'<script>window.__timelines={{test:gsap.timeline({{paused:true}}).to({{}},{{duration:{duration}}})}};</script>'
    page.write_text(f'<!doctype html>{scripts}<div data-composition-id="test" data-width="64" data-height="64" data-duration="{duration}">{body}</div>{timeline}')
    command = [str(binary), str(page)] + ([str(movie)] if args.catalyst else ['-o', str(movie), '--fps', '4'])
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
    if not success:
        assert not movie.exists(), name
        print('PASS rejection', name, flush=True)
        return result.stderr
    decoded = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(movie), '-vn', '-f', 'f32le', '-ac', '2', '-ar', str(rate), '-'])
    samples = array.array('f', decoded)
    assert all(math.isfinite(v) for v in samples), name
    assert len(samples) > 0, name
    samples.extend([0.] * max(0, round(duration * rate * 2) - len(samples)))
    print('PASS export', name, flush=True)
    return samples

def rms(samples, start=.15, end=.75, channel=0):
    values = samples[round(start * rate) * 2 + channel:round(end * rate) * 2:2]
    return math.sqrt(sum(v * v for v in values) / max(1, len(values)))

def frequency(samples, start=.2, end=.7, channel=0):
    values = samples[round(start * rate) * 2 + channel:round(end * rate) * 2:2]
    return sum(a <= 0 < b for a, b in zip(values, values[1:])) / (end - start)

def close(actual, expected, tolerance=.08):
    assert abs(actual - expected) <= max(.001, abs(expected) * tolerance), (actual, expected)

def matches_crop(cropped, reference, offset, windows):
    for start, end in windows:
        close(rms(cropped, start, end), rms(reference, start + offset, end + offset), .12)

tone('tone.wav')
tone('hot.wav', amplitude=.7)
tone('short.wav', duration=.1)
baseline = render('dry', audio())
base = rms(baseline)
close(base, .2 / math.sqrt(2))

# Exercise every upstream builder, including all five custom worklets.
for kind in ['gain', 'peaking', 'lowshelf', 'highshelf', 'highpass', 'lowpass',
             'compressor', 'limiter', 'gate', 'saturate', 'bitcrush', 'pitchshift',
             'delay', 'chorus', 'phaser', 'reverb']:
    samples = render(kind, audio(chain(kind, {'semitones': 12} if kind == 'pitchshift' else None)))
    assert rms(samples) > .0001, kind
    if kind == 'compressor': assert rms(samples) < base * .9
    if kind == 'pitchshift': close(frequency(samples), 880, .06)
    if kind == 'gain':
        close(frequency(samples), 440, .01)
        close(frequency(samples, channel=1), 660, .01)
        close(rms(samples, channel=1), base)

# Quantitative filter and dynamics checks, beyond merely producing audio.
samples = render('lowpass-cut', audio(chain('lowpass', {'frequency': 80, 'q': .707})))
assert rms(samples) < base * .08
samples = render('eq-boost', audio(chain('peaking', {'frequency': 440, 'gain': 6, 'q': 3})))
close(rms(samples), base * 10 ** (6 / 20), .12)
samples = render('gate-close', audio(chain('gate', {'threshold': 0})))
assert rms(samples, .4, .8) < base * .1

# The export graph lives outside author scripts and ignores page-owned globals.
samples = render('isolated-world', '<script>globalThis.__html2videoFX = {render() {throw Error("author graph");}};</script>' + audio(chain('gain', {'gain': -6})))
close(rms(samples), base * 10 ** (-6 / 20))

# Effect gain must precede the fader without an intermediate integer clamp.
samples = render('gain-before-fader', audio(chain('gain', {'gain': 12}), source='hot.wav', **{'data-volume': .1}))
close(rms(samples), .7 * 10 ** (12 / 20) * .1 / math.sqrt(2))

# Static clip and group faders share upstream's +12 dB authoring ceiling.
for gain in [2, 10 ** (12 / 20), 8]:
    expected = base * min(gain, 10 ** (12 / 20))
    samples = render(f'clip-boost-{gain}', audio(**{'data-volume': gain}))
    close(rms(samples), expected)
    group = f'<hf-audio-group id="bus" data-volume="{gain}"></hf-audio-group>'
    samples = render(f'group-boost-{gain}', group + audio(**{'data-audio-group': 'bus'}))
    close(rms(samples), expected)
samples = render('boost-with-fx', audio(chain('gain', {'gain': -6}), **{'data-volume': 2}))
close(rms(samples), base * 2 * 10 ** (-6 / 20))
boost_lane = {'version': 1, 'lanes': [{'target': 'volume', 'points': [{'t': 0, 'v': 2}, {'t': 1, 'v': 2}]}]}
samples = render('boost-lane', audio(**{'data-automation': json.dumps(boost_lane)}))
close(rms(samples), base * 2)

# The preview runtime must not clamp native export's sampled gain back to unity.
samples = render('runtime-clip-boost', audio(**{'id': 'tone', 'data-volume': 2}), runtime=True)
close(rms(samples), base * 2)
group = '<hf-audio-group id="bus" data-volume="2"></hf-audio-group>'
samples = render('runtime-group-boost', group + audio(**{'id': 'tone', 'data-audio-group': 'bus'}), runtime=True)
close(rms(samples), base * 2)

# Native capture owns muting even with the preview media transport disabled.
# An audible reference keeps an audio track present when every other clip is hidden.
reference = audio(**{'id': 'reference', 'data-volume': .1})
for name, hidden in [
    ('clip', audio(**{'id': 'hidden', 'data-hidden': ''})),
    ('ancestor', '<div data-hidden><div>' + audio(**{'id': 'hidden'}) + '</div></div>'),
    ('ancestor-fx', '<div data-hidden>' + audio(chain('gain', {'gain': 6}), **{'id': 'hidden'}) + '</div>'),
    ('group', '<hf-audio-group id="bus" data-hidden></hf-audio-group>' + audio(**{'id': 'hidden', 'data-audio-group': 'bus'})),
]:
    samples = render('runtime-hidden-' + name, reference + hidden, runtime=True)
    close(rms(samples), base * .1)

def check_envelope(samples, gain, windows=((.05, .15), (.4, .45), (.55, .6), (.85, .95))):
    for start, end in windows:
        # Expected energy of the authored envelope, independent of the renderer's
        # frame cadence and Web Audio automation scheduling.
        mean_square = sum(gain(start + (i + .5) * (end - start) / 1000) ** 2 for i in range(1000)) / 1000
        close(rms(samples, start, end), base * math.sqrt(mean_square))

triangle = lambda t: max(0, min(1, 2 * t, 2 * (1 - t)))
fades = {'id': 'tone', 'data-duration': 1, 'data-fade-in': .5, 'data-fade-out': .5}
for runtime in [False, True]:
    samples = render(f'fades-dry-{runtime}', audio(**fades), runtime=runtime)
    check_envelope(samples, triangle)
    samples = render(f'fades-fx-boost-{runtime}', audio(chain('gain', {'gain': -6}), **{**fades, 'data-volume': 2}), runtime=runtime)
    check_envelope(samples, lambda t: triangle(t) * 2 * 10 ** (-6 / 20))

# The lane replaces base volume but still multiplies by the fade; the product
# of these two ramps is not itself a linear ramp between output video frames.
fade_lane = {'version': 1, 'lanes': [{'target': 'volume', 'points': [{'t': 0, 'v': 1}, {'t': 1, 'v': 2}]}]}
samples = render('fades-volume-lane', audio(**{**fades, 'data-volume': .1, 'data-automation': json.dumps(fade_lane)}), runtime=True)
check_envelope(samples, lambda t: triangle(t) * (1 + t))
group = '<hf-audio-group id="bus" data-volume="0.5" data-fx-chain="' + attr(chain('gain', {'gain': 6})) + '"></hf-audio-group>'
samples = render('fades-group', group + audio(**{**fades, 'data-volume': 2, 'data-audio-group': 'bus'}), runtime=True)
check_envelope(samples, lambda t: triangle(t) * 10 ** (6 / 20))

# Upstream scales fades that exceed clip duration, and ignores invalid lengths.
samples = render('fades-overlap', audio(**{**fades, 'data-fade-in': 2, 'data-fade-out': 2}), runtime=True)
check_envelope(samples, triangle)
for name, attributes, gain in [
    ('in', {'data-fade-in': .5}, lambda t: min(1, 2 * t)),
    ('out', {'data-fade-out': .5}, lambda t: min(1, 2 * (1 - t))),
    ('zero', {'data-fade-in': 0, 'data-fade-out': 0}, lambda t: 1),
    ('invalid', {'data-fade-in': 'Infinity', 'data-fade-out': -1}, lambda t: 1),
]:
    samples = render('fade-' + name, audio(**{'data-duration': 1, **attributes}))
    check_envelope(samples, gain)

# Export/visibility cuts preserve the authored fade clock and duration.
samples = render('fades-negative-start', audio(**{**fades, 'data-start': -.25}), runtime=True)
check_envelope(samples, lambda t: triangle(t + .25), ((.05, .15), (.35, .45), (.55, .65)))
assert rms(samples, .8, .95) < .001
samples = render('fades-visibility-cut', '<div data-start="0.25" data-duration="0.5">' + audio(**fades) + '</div>', runtime=True)
check_envelope(samples, triangle, ((.3, .4), (.6, .7)))
assert rms(samples, 0, .2) < .001
assert rms(samples, .8, .95) < .001

# A post-FX fade-out also silences delayed output beyond the authored clip end.
samples = render('fade-delay-tail', audio(chain('delay', {'time': 200, 'mix': 1, 'feedback': .4}), source='short.wav', **{'data-duration': .1, 'data-fade-out': .1}), duration=1)
assert rms(samples, .2, .9) < .001

# Chain automation is clip-local; the explicit volume lane supersedes base volume.
automation = {'version': 1, 'lanes': [
    {'target': 'fx.n1.gain', 'points': [{'t': 0, 'v': 0}, {'t': .8, 'v': -20}]},
    {'target': 'volume', 'points': [{'t': 0, 'v': .5}, {'t': 1, 'v': .5}]},
]}
samples = render('automated-offset', audio(chain('gain'), **{'data-start': .5, 'data-volume': .1, 'data-automation': json.dumps(automation)}), duration=2)
assert rms(samples, 0, .4) < .001
assert rms(samples, .6, .7) > rms(samples, 1.2, 1.3) * 4
close(rms(samples, 1.32, 1.42), base * .05, .15)

# Delay must survive the end of its input clip and stop at the composition boundary.
samples = render('delay-tail', audio(chain('delay', {'time': 200, 'mix': 1, 'feedback': .4}), source='short.wav'), duration=1)
assert rms(samples, .01, .07) < .001
assert rms(samples, .22, .28) > .02
assert rms(samples, .42, .48) > .005

# Loop/trim/rate preparation stays ahead of effects; constant rate preserves pitch.
samples = render('rate-loop', audio(chain('gain'), source='short.wav', **{'loop': '', 'data-media-start': .02, 'data-playback-rate': 2, 'data-duration': .6}), duration=1)
assert rms(samples, .3, .5) > .02
assert rms(samples, .8, .95) < .001

# Group effects operate on the floating-point sum after members' own effects/faders.
group = '<hf-audio-group id="bus" data-volume="0.1" data-fx-chain="' + attr(chain('gain')) + '"></hf-audio-group>'
samples = render('group-headroom', group + audio(source='hot.wav', **{'data-audio-group': 'bus'}) * 2)
close(rms(samples), .7 * 2 * .1 / math.sqrt(2))
samples = render('member-and-group', group + audio(chain('gain', {'gain': 6}), source='hot.wav', **{'data-audio-group': 'bus', 'data-volume': .5}) * 2)
close(rms(samples), .7 * 10 ** (6 / 20) * .5 * 2 * .1 / math.sqrt(2))

# Group fader/effect automation uses composition time, including leading silence.
group_auto = {'version': 1, 'lanes': [{'target': 'fx.n1.gain', 'points': [{'t': 0, 'v': 0}, {'t': .5, 'v': -20}]}]}
group = '<hf-audio-group id="bus" data-fx-chain="' + attr(chain('gain')) + '" data-automation="' + attr(group_auto) + '"></hf-audio-group>'
samples = render('group-clock', group + audio(**{'data-audio-group': 'bus', 'data-start': .5}), duration=2)
close(rms(samples, .7, 1.2), base * .1)

# Negative and nested visibility starts must sample the same clip-local FX envelope.
auto = {'version': 1, 'lanes': [{'target': 'fx.n1.gain', 'points': [{'t': 0, 'v': 0}, {'t': .5, 'v': -20}]}]}
samples = render('negative-start', audio(chain('gain'), **{'data-start': -.5, 'data-automation': json.dumps(auto)}), duration=1)
close(rms(samples, .1, .4), base * .1)
samples = render('nested-visibility', '<div data-start="0.5" data-duration="0.5">' + audio(chain('gain'), **{'data-automation': json.dumps(auto)}) + '</div>', duration=1.5)
assert rms(samples, 0, .4) < .001
close(rms(samples, .6, .9), base * .1)

# A clip that starts before time zero must sound like the matching portion of a
# full export, including delay state built from the discarded prefix.
delay = chain('delay', {'time': 200, 'mix': 1, 'feedback': .4})
reference = render('history-reference', audio(delay, **{'data-duration': 1}))
samples = render('history-negative', audio(delay, **{'data-start': -.5, 'data-duration': 1}), duration=1)
matches_crop(samples, reference, .5, ((.05, .15), (.3, .4), (.65, .75), (.85, .95)))
assert rms(samples, .05, .15) > base * .5
samples = render('history-visibility', '<div data-start="0.5" data-duration="0.5">' + audio(delay, **{'data-duration': 1}) + '</div>')
matches_crop(samples, reference, 0, ((.55, .65), (.8, .9), (1.1, 1.2)))
assert rms(samples, 0, .45) < .001

# Pitch-preserving conversion of short loops varies in phase across AVFoundation
# runs, so compare onset instead of cross-export RMS. Resetting the delay at the
# crop would make this entire window silent, even though the source is playing.
samples = render('history-rate-loop-negative', audio(delay, source='short.wav', **{
    'data-start': -.5, 'data-duration': 1, 'loop': '', 'data-media-start': .02,
    'data-playback-rate': 2}), duration=1, runtime=True)
assert rms(samples, .05, .15) > .02

# Preserve history through the downstream fader, fades, and group. Automation
# remains clip-local, with the full export as the reference for the audible crop.
history_lane = {'version': 1, 'lanes': [{'target': 'volume', 'points': [{'t': 0, 'v': 0}, {'t': 1, 'v': 2}]}]}
group = '<hf-audio-group id="bus" data-volume="0.5"></hf-audio-group>'
attributes = {'data-duration': 1, 'data-volume': 2, 'data-fade-in': .2, 'data-fade-out': .2,
              'data-automation': json.dumps(history_lane), 'data-audio-group': 'bus'}
reference = render('history-envelope-reference', group + audio(delay, **attributes), runtime=True)
samples = render('history-envelope-negative', group + audio(delay, **{**attributes, 'data-start': -.5}), duration=1, runtime=True)
matches_crop(samples, reference, .5, ((.05, .15), (.3, .4), (.65, .75)))

# Input entirely before the output boundary can still leave an audible FX tail.
reference = render('history-tail-reference', audio(delay, source='short.wav', **{'data-duration': .1}), duration=1)
samples = render('history-tail-negative', audio(delay, source='short.wav', **{'data-duration': .1, 'data-start': -.15}), duration=1)
matches_crop(samples, reference, .15, ((.06, .12), (.26, .32), (.46, .52)))
assert rms(samples, .06, .12) > .02
# A fully elapsed tail contributes no audio, while the remaining clip still plays.
samples = render('history-tail-expired', audio(**{'data-volume': .1}) + audio(delay, source='short.wav', **{'data-start': -10}), duration=1)
close(rms(samples), base * .1)

# Compiled instance keys select distinct buses even when author IDs repeat.
groups = '<hf-audio-group id="bus" data-hf-render-id="one" data-volume="0.2"></hf-audio-group><hf-audio-group id="bus" data-hf-render-id="two" data-hidden></hf-audio-group>'
samples = render('group-instances', groups + audio(**{'data-audio-group': 'bus', 'data-hf-group-render-id': 'one'}) + audio(**{'data-audio-group': 'bus', 'data-hf-group-render-id': 'two'}))
close(rms(samples), base * .2)

for name, bad in [('unknown-effect', {'version': 1, 'nodes': [{'type': 'unknown'}]}), ('bad-version', {'version': 99, 'nodes': []})]:
    error = render(name, audio(bad), success=False)
    assert 'frames' not in error, error
render('empty-chain', audio(**{'data-fx-chain': ''}), success=False)
render('broken-json', audio(**{'data-fx-chain': 'oops'}), success=False)
render('unknown-lane', audio(chain('gain'), **{'data-automation': json.dumps({'version': 1, 'lanes': [{'target': 'invalid', 'points': []}]})}), success=False)
# Cancel after picture capture, while the effects path is transferring/rendering
# a long clip; no audio intermediates or final movie may be left behind.
if not args.catalyst:
    page, movie = root / 'cancel.html', root / 'cancel.mp4'
    page.write_text('<div data-composition-id="test" data-width="64" data-height="64" data-duration="120">' + audio(chain('reverb'), **{'loop': '', 'data-duration': 120}) + '</div>')
    before = set(pathlib.Path(tempfile.gettempdir()).glob('html2video-audio-*'))
    process = subprocess.Popen([str(binary), str(page), '-o', str(movie), '--fps', '1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for line in process.stderr:
        if '120/120 frames' in line:
            break
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and process.poll() is None:
        if set(pathlib.Path(tempfile.gettempdir()).glob('html2video-audio-*')) - before:
            process.send_signal(signal.SIGINT)
            break
        time.sleep(.01)
    stdout, stderr = process.communicate(timeout=15)
    assert process.returncode == 130, (process.returncode, stdout, stderr)
    assert not movie.exists()
    assert not (set(pathlib.Path(tempfile.gettempdir()).glob('html2video-audio-*')) - before)
    print('PASS audio-phase cancellation and cleanup', flush=True)

assert not list(root.glob('.html2video-*')), 'Leaked temporary export files'
print('PASS audio effects, automation, fades, muting, stereo, tails, groups, rate preparation, and errors', flush=True)

#!/usr/bin/env python3
"""Audio timing/processing contracts, measured through the production exporter.

Oracles below are authored gain formulas and sums of delayed tone pulses, not
the HyperFrames scheduler. FFmpeg is used only to decode the final movie.
"""
import argparse
import array
import html
import json
import math
from pathlib import Path
import subprocess
import tempfile
import wave

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=Path)
parser.add_argument('--catalyst', action='store_true')
args = parser.parse_args()
binary = args.binary.resolve()
root = Path(tempfile.mkdtemp(prefix='html2video-audio-contract-'))
print(root, flush=True)
sample_rate = 48000
amplitude = .2
exports = 0


def tone(name, duration):
    pcm = array.array('h', (round(amplitude * 32767 * math.sin(i * 440 * 2 * math.pi / sample_rate))
                           for i in range(round(duration * sample_rate))))
    with wave.open(str(root / name), 'wb') as stream:
        stream.setparams((1, 2, sample_rate, 0, 'NONE', 'not compressed'))
        stream.writeframes(pcm.tobytes())


def element(tag, **attributes):
    def value(item):
        return json.dumps(item) if isinstance(item, dict) else str(item)
    return '<' + tag + ' ' + ' '.join(f'{key}="{html.escape(value(item), quote=True)}"'
                                     for key, item in attributes.items()) + f'></{tag}>'


def chain(kind, **params):
    return {'version': 1, 'nodes': [{'id': 'fx', 'type': kind, 'params': params}]}


def automation(target, points):
    return {'version': 1, 'lanes': [{'target': target, 'points': points}]}


def render(name, body, duration=1.75):
    global exports
    page, movie = root / (name + '.html'), root / (name + '.mp4')
    page.write_text(f'<!doctype html><div data-composition-id="root" data-width="64" '
                    f'data-height="64" data-duration="{duration}">{body}</div>')
    command = [str(binary), str(page)]
    command += [str(movie)] if args.catalyst else ['-o', str(movie), '--fps', '4']
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, (name, result.stdout, result.stderr)
    pcm = array.array('f', subprocess.check_output([
        'ffmpeg', '-v', 'error', '-i', str(movie), '-vn', '-f', 'f32le',
        '-ac', '1', '-ar', str(sample_rate), '-']))
    assert pcm and all(math.isfinite(v) for v in pcm), name
    # A movie may end its audio track before its picture; that suffix is silence.
    pcm.extend([0.] * max(0, round(duration * sample_rate) - len(pcm)))
    exports += 1
    return pcm


def rms(pcm, start, end):
    values = pcm[round(start * sample_rate):round(end * sample_rate)]
    return math.sqrt(sum(v * v for v in values) / len(values))


def check(name, pcm, gain, windows, tolerance=.08):
    for start, end in windows:
        energy = sum(gain(start + (i + .5) * (end - start) / 1000) ** 2 for i in range(1000)) / 1000
        expected = amplitude / math.sqrt(2) * math.sqrt(energy)
        actual = rms(pcm, start, end)
        assert abs(actual - expected) <= max(.001, expected * tolerance), (name, start, end, actual, expected)
    print('PASS', name, flush=True)


def ramp(t):
    return max(0, min(1, (t - .5) / .5))


tone('tone.wav', 3)
tone('loop.wav', .5)
tone('pulse.wav', .1)

# The first value holds until its own timestamp, including for group automation.
# This is the P2 regression: (0.5, 0) -> (1, 1) must be silent before 0.5s.
windows = ((.15, .35), (.55, .65), (.8, .9), (1.1, 1.2))
for owner in ['clip', 'group']:
    for shape, point, curve in [
        ('linear', {}, lambda x: x),
        ('curved', {'curve': .5}, lambda x: x * x),
        ('via', {'viaX': .5, 'viaY': .25}, lambda x: x * x),
    ]:
        lane = automation('volume', [{'t': .5, 'v': 0, **point}, {'t': 1, 'v': 1}])
        attributes = {'src': 'tone.wav', 'data-duration': 1.5, 'data-volume': .1}
        group = ''
        if owner == 'clip':
            attributes['data-automation'] = lane
        else:
            attributes['data-volume'] = 1
            attributes['data-audio-group'] = 'bus'
            group = element('hf-audio-group', id='bus', **{'data-volume': .1, 'data-automation': lane})
        name = f'first-point-{owner}-{shape}'
        pcm = render(name, group + element('audio', **attributes))
        check(name, pcm, lambda t: curve(ramp(t)), windows)

# Mapped FX automation and an unmapped linear FX parameter both retain the
# initial hold. Reverb's wet=0 isolates its dry gain from convolution.
for kind, params, target, initial, final, gain in [
    ('gain', {}, 'gain', -20, 0, lambda t: 10 ** ((-20 + 20 * ramp(t)) / 20)),
    ('reverb', {'wet': 0, 'dry': 0}, 'dry', 0, 1, ramp),
]:
    name = 'first-point-fx-' + kind
    lane = automation('fx.fx.' + target, [{'t': .5, 'v': initial}, {'t': 1, 'v': final}])
    pcm = render(name, element('audio', src='tone.wav', **{
        'data-duration': 1.5, 'data-fx-chain': chain(kind, **params), 'data-automation': lane}))
    check(name, pcm, gain, windows)

# One point and already-elapsed points hold; an offset starts on the clip clock.
for label, points, start, gain in [
    ('single', [{'t': .5, 'v': .4}], 0, lambda t: .4),
    ('elapsed', [{'t': .2, 'v': .2}, {'t': .4, 'v': .6}], -.5, lambda t: .6),
    ('offset', [{'t': .5, 'v': 0}, {'t': 1, 'v': 1}], .25, lambda t: ramp(t - .25)),
    ('negative', [{'t': .5, 'v': 0}, {'t': 1, 'v': 1}], -.25, lambda t: ramp(t + .25)),
]:
    name = 'hold-' + label
    pcm = render(name, element('audio', src='tone.wav', **{
        'data-start': start, 'data-duration': 2.5,
        'data-automation': automation('volume', points)}))
    check(name, pcm, gain, windows)

# Compare plain clips, identity clip FX, and an identity group. Plain unity-rate
# clips use the native dry path; rate changes need bounded PCM preparation even
# without authored FX. Every route must preserve the sampled envelope and timing.
# Visibility intersects the authored clip; it never restarts its local clock.
clock_cases = [
    ('origin', 0, None, {}),
    ('offset', .25, None, {}),
    ('negative', -.25, None, {}),
    ('visibility', 0, (.25, 1), {}),
    ('negative-visible', -.25, (.25, 1), {}),
    ('trim-rate', .25, None, {'data-media-start': .2, 'data-playback-rate': 2}),
    ('slow-trim', -.25, None, {'data-media-start': .2, 'data-playback-rate': .5}),
    ('loop-trim', .25, None, {'src': 'loop.wav', 'loop': '', 'data-media-start': .1}),
    ('rate-lane', -.25, None, {'data-media-start': .2, 'data-automation': automation(
        'rate', [{'t': 0, 'v': .75}, {'t': 1.25, 'v': 1.5}])}),
]
windows = ((.05, .15), (.3, .4), (.6, .7), (1.05, 1.15), (1.6, 1.7))
for label, start, visibility, extra in clock_cases:
    lower = max(0, start, visibility[0] if visibility else start)
    upper = min(start + 1.25, visibility[1] if visibility else start + 1.25)
    clock_windows = (*windows, (upper + .02, upper + .08))
    gain = lambda t: .2 + .4 * min(1, max(0, t - start)) if lower <= t < upper else 0
    outputs = []
    for route in ['dry', 'clip-fx', 'group']:
        attributes = {'id': 'tone', 'src': 'tone.wav', 'data-start': start, 'data-duration': 1.25, **extra}
        group = ''
        if route == 'clip-fx':
            attributes['data-fx-chain'] = chain('gain', gain=0)
        if route == 'group':
            attributes['data-audio-group'] = 'bus'
            group = element('hf-audio-group', id='bus', **{'data-fx-chain': chain('gain', gain=0)})
        body = element('audio', **attributes)
        if visibility:
            body = f'<div data-start="{visibility[0]}" data-duration="{visibility[1] - visibility[0]}">{body}</div>'
        body += '<script>window.html2video={seek(t){document.getElementById("tone").volume=' + \
                f'.2+.4*Math.min(1,Math.max(0,t-({start})))' + ';}};</script>'
        name = 'clock-' + label + '-' + route
        pcm = render(name, group + body)
        check(name, pcm, gain, clock_windows)
        outputs.append(pcm)
    for pcm in outputs[1:]:
        for a, b in clock_windows:
            reference, actual = rms(outputs[0], a, b), rms(pcm, a, b)
            assert abs(actual - reference) <= max(.001, reference * .08), (label, a, b, actual, reference)

# The volume lane replaces the sampled timeline and the static baseline; fades
# multiply that lane. Parent cuts retain the original fade duration. Group gain
# follows the member's processing and is applied once.
for start, visibility in [(0, None), (-.25, None), (0, (.25, .9)), (-.25, (.25, .9))]:
    for grouped in [False, True]:
        name = f'envelope-{start}-{visibility}-{grouped}'
        lane = automation('volume', [{'t': .5, 'v': .2}, {'t': 1, 'v': 2}])
        attributes = {'id': 'tone', 'src': 'tone.wav', 'data-start': start, 'data-duration': 1.25,
                      'data-volume': .1, 'data-fade-in': .25, 'data-fade-out': .25,
                      'data-automation': lane, 'data-fx-chain': chain('gain', gain=6)}
        group = ''
        if grouped:
            attributes['data-audio-group'] = 'bus'
            group = element('hf-audio-group', id='bus', **{'data-volume': .25})
        body = element('audio', **attributes)
        if visibility:
            body = f'<div data-start="{visibility[0]}" data-duration="{visibility[1] - visibility[0]}">{body}</div>'
        body += '<script>window.html2video={seek(){document.getElementById("tone").volume=.9;}};</script>'
        lower = max(0, start, visibility[0] if visibility else start)
        upper = min(start + 1.25, visibility[1] if visibility else start + 1.25)

        def gain(t):
            local = t - start
            if not lower <= t < upper:
                return 0
            fade = max(0, min(1, local / .25, (1.25 - local) / .25))
            return (10 ** (6 / 20)) * (.2 + 1.8 * ramp(local)) * fade * (.25 if grouped else 1)

        pcm = render(name, group + body)
        check(name, pcm, gain, windows)

# Stateful FX get clip pre-roll, then visibility/output trimming. A group starts
# at composition zero and receives only those audible member contributions;
# moving a delay from a clip to its group is therefore NOT a crop invariant.
# Delay=200ms keeps successive 100ms tone pulses separate. Measure inside each
# pulse, away from codec edges and Web Audio's feedback-block boundary, so the
# expected amplitude is a geometric series independent of phase.
delay = chain('delay', time=200, mix=1, feedback=.4)
windows = ((.07, .09), (.22, .24), (.27, .29), (.42, .44), (.47, .49), (.67, .69), (.87, .89))
for label, start, visible, clip_fx, group_fx in [
    ('clip', 0, 0, True, False),
    ('clip-negative-tail', -.15, 0, True, False),
    ('clip-visibility', 0, .25, True, False),
    ('group', 0, 0, False, True),
    ('group-negative', -.05, 0, False, True),
    ('group-expired', -.15, 0, False, True),
    ('clip-and-group', -.15, 0, True, True),
]:
    attributes = {'src': 'pulse.wav', 'data-start': start, 'data-duration': .1}
    if clip_fx:
        attributes['data-fx-chain'] = delay
    group = ''
    if group_fx:
        attributes['data-audio-group'] = 'bus'
        group = element('hf-audio-group', id='bus', **{'data-fx-chain': delay})
    body = element('audio', **attributes)
    if visible > 0:
        body = f'<div data-start="{visible}" data-duration="1">{body}</div>'
    # Keep an audio track even when every group member ended before time zero.
    body += element('audio', src='tone.wav', **{'data-duration': 1.5, 'data-volume': 0})

    def member(t):
        if t < max(0, start, visible):
            return 0
        if clip_fx:
            return sum(.4 ** k for k in range(10) if 0 <= t - start - .2 * (k + 1) < .1)
        return 1 if 0 <= t - start < .1 else 0

    def gain(t):
        return (sum(.4 ** k * member(t - .2 * (k + 1)) for k in range(10))
                if group_fx else member(t))

    name = 'history-' + label
    pcm = render(name, group + body, duration=1)
    check(name, pcm, gain, windows, tolerance=.12)

assert not list(root.glob('.html2video-*')), 'Leaked temporary export files'
print(f'PASS audio contract: {exports} exports; first-point holds, dry/FX/group equivalence, '
      'clock intersections, gain/fade ordering, rate/trim/loop preparation, and effect history', flush=True)

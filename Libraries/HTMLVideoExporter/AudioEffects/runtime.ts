// The effect implementations are the pinned HyperFrames sources. This adapter
// only moves PCM between AVFoundation and Web Audio and applies clip gain/fades.
import { parseAudioFxChain } from '../../../Apps/HyperFramesCLI/Upstream/packages/core/src/audioFx';
import { parseAutomation, resolveAutomation } from '../../../Apps/HyperFramesCLI/Upstream/packages/core/src/audioAutomation';
import { buildFxChain, chainNeedsWorklets, ensureAudioFxWorklets } from '../../../Apps/HyperFramesCLI/Upstream/packages/core/src/audio/audioFxGraph';
import { chainTailSeconds } from '../../../Apps/HyperFramesCLI/Upstream/packages/core/src/audio/audioFxTail';
import { scheduleChainAutomation, scheduleParamLane, volumeLane } from '../../../Apps/HyperFramesCLI/Upstream/packages/core/src/audio/audioFxAutomation';

import { clampAudioGain } from '../../../Apps/HyperFramesCLI/Upstream/packages/core/src/audioGain';
import { clampFadesToDuration, fadeGain, readFadeSeconds } from '../../../Apps/HyperFramesCLI/Upstream/packages/core/src/audioFade';

const empty = { version: 1, nodes: [] };
function settings(clip) {
  const chain = parseAudioFxChain(clip.fxChain ?? JSON.stringify(empty));
  const raw = clip.automation || { version: 1, lanes: [] };
  const automation = resolveAutomation(parseAutomation(JSON.stringify(raw)), chain);
  const authoredVolume = clip.volume ?? 1;
  if (!Number.isFinite(authoredVolume) || authoredVolume < 0) throw Error('Audio volume must be finite and nonnegative.');
  const volume = clampAudioGain(authoredVolume);
  return { chain, automation, volume };
}
let input: AudioBuffer | null = null;
let result: AudioBuffer | null = null;

(globalThis as any).__html2videoFX = {
  validate(clip) { settings(clip); },
  begin(frames: number, channels: number, sampleRate: number) {
    result = null;
    // AudioBuffer construction does not create a live playback context.
    input = new AudioBuffer({ length: frames, numberOfChannels: channels, sampleRate });
  },
  append(base64: string, offset: number) {
    if (!input) throw Error('Audio input is not initialized.');
    const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
    const samples = new Float32Array(bytes.buffer);
    const count = samples.length / input.numberOfChannels;
    if (!Number.isInteger(count) || offset + count > input.length) throw Error('Invalid audio sample count.');
    for (let c = 0; c < input.numberOfChannels; c++) {
      const plane = input.getChannelData(c);
      for (let f = 0; f < count; f++) plane[offset + f] = samples[f * input.numberOfChannels + c];
    }
  },
  async render(clip, elapsed: number, remaining: number) {
    if (!input) throw Error('Audio input is not initialized.');
    const { chain, automation, volume } = settings(clip);
    const frames = Math.max(1, Math.min(
      Math.ceil(remaining * input.sampleRate),
      input.length + Math.ceil(chainTailSeconds(chain, automation) * input.sampleRate)));
    const ctx = new OfflineAudioContext(input.numberOfChannels, frames, input.sampleRate);
    if (chainNeedsWorklets(chain)) await ensureAudioFxWorklets(ctx);
    const fx = buildFxChain(ctx, chain, elapsed);
    const timing = { scheduledAt: 0, elapsed, rate: 1 };
    scheduleChainAutomation(automation, chain, fx.nodes, timing, fx.presets);
    const gain = ctx.createGain();
    gain.gain.value = volume;
    // Explicit volume automation replaces sampled timeline volume, just as in preview.
    const sampled = resolveAutomation(parseAutomation(JSON.stringify({version: 1, lanes: clip.points?.length ? [{target: 'volume', points: clip.points}] : []})), chain);
    const lane = volumeLane(automation) || volumeLane(sampled);
    if (lane) scheduleParamLane([{ param: gain.gain }], lane, 'linear', timing);
    // Keep clip fades separate from the fader so automation and boosts multiply
    // by the envelope. Visibility cuts must not restart or shorten the fade.
    const duration = clip.duration ?? Infinity;
    const fades = clampFadesToDuration({
      fadeIn: readFadeSeconds(clip.fadeIn), fadeOut: readFadeSeconds(clip.fadeOut),
    }, duration);
    let fade: GainNode | null = null;
    if (fades.fadeIn > 0 || fades.fadeOut > 0) {
      fade = ctx.createGain();
      fade.gain.setValueAtTime(fadeGain(elapsed, duration, fades), 0);
      for (const time of [fades.fadeIn, duration - fades.fadeOut, duration]) {
        if (Number.isFinite(time) && time > elapsed)
          fade.gain.linearRampToValueAtTime(fadeGain(time, duration, fades), time - elapsed);
      }
    }
    const source = ctx.createBufferSource();
    source.buffer = input;
    source.connect(fx.input);
    fx.output.connect(gain);
    if (fade) {
      gain.connect(fade);
      fade.connect(ctx.destination);
    } else gain.connect(ctx.destination);
    source.start();
    try {
      result = await ctx.startRendering();
      return { frames: result.length, channels: result.numberOfChannels, sampleRate: result.sampleRate };
    } finally {
      source.disconnect();
      source.buffer = null;
      fx.dispose();
      gain.disconnect();
      fade?.disconnect();
      input = null;
    }
  },
  read(offset: number, count: number) {
    if (!result) throw Error('Audio output is not initialized.');
    const end = Math.min(result.length, offset + count);
    const samples = new Float32Array((end - offset) * result.numberOfChannels);
    for (let c = 0; c < result.numberOfChannels; c++) {
      const plane = result.getChannelData(c);
      for (let f = offset; f < end; f++) {
        const value = plane[f];
        if (!Number.isFinite(value)) throw Error('Audio effect produced a non-finite sample.');
        samples[(f - offset) * result.numberOfChannels + c] = value;
      }
    }
    let binary = '';
    for (const byte of new Uint8Array(samples.buffer)) binary += String.fromCharCode(byte);
    return btoa(binary);
  },
  clear() { input = null; result = null; },
};

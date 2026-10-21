import Foundation
import WebKit

// Injected before author scripts. The export host owns the clock, not browser playback.
enum HTMLVideoPage {
  /// Read declared dimensions in an inert document before any author scripts run.
  /// Snapshot and export must initialize layout-dependent animation at the same viewport.
  static func initialViewport(
    _ html: String, in webView: WKWebView, width: Int? = nil, height: Int? = nil,
    completion: @escaping (Result<CGSize, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    webView.callAsyncJavaScript(
      """
      const document = new DOMParser().parseFromString(html, 'text/html');
      const root = Array.from(document.querySelectorAll('[data-composition-id]'))
        .find(el => !el.parentElement?.closest('[data-composition-id]'));
      return {width: width || Number(root?.dataset.width) || 1920,
        height: height || Number(root?.dataset.height) || 1080};
      """,
      arguments: ["html": html, "width": width ?? 0, "height": height ?? 0],
      in: nil, in: .defaultClient
    ) { result in
      completion(
        Result {
          guard let dimensions = try result.get() as? [String: Double],
            let width = dimensions["width"], let height = dimensions["height"],
            width.isFinite, height.isFinite, (1...8192).contains(width), (1...8192).contains(height)
          else { throw HTMLVideoExportError.invalid("Invalid composition dimensions.") }
          return CGSize(width: width, height: height)
        })
    }
  }

  static let bootstrap = #"""
    window.__HF_RENDER_CAPTURE_MODE = true;
    window.__timelines = window.__timelines || {};
    window.__hyperframes = window.__hyperframes || {};
    window.__hyperframes.getVariables = () => {
      const defaults = Object.create(null);
      for (const el of document.querySelectorAll('[data-composition-variables]')) {
        for (const entry of JSON.parse(el.dataset.compositionVariables)) {
          if (typeof entry.id === 'string' && 'default' in entry) defaults[entry.id] = entry.default;
        }
      }
      return {...defaults, ...window.__hfVariables};
    };
    (() => {
      // Install before author scripts can retain a native upload/draw function.
      window.__html2videoFrames = new WeakMap();
      window.__html2videoFrameCallbacks = new WeakMap();
      const decodedSource = source => window.__html2videoFrames.get(source)?.image || source;
      for (const ctor of [window.CanvasRenderingContext2D, window.OffscreenCanvasRenderingContext2D]) {
        for (const method of ['drawImage', 'createPattern']) {
          const original = ctor?.prototype[method];
          if (!original) continue;
          ctor.prototype[method] = function(source, ...args) {
            return original.call(this, decodedSource(source), ...args);
          };
        }
      }
      for (const ctor of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
        for (const method of ['texImage2D', 'texSubImage2D']) {
          const original = ctor?.prototype[method];
          if (!original || original.__hfVideoPatched) continue;
          const patched = function(...args) {
            const last = args.length - 1;
            args[last] = decodedSource(args[last]);
            return original.apply(this, args);
          };
          patched.__hfVideoPatched = true;
          ctor.prototype[method] = patched;
        }
      }
      // Libraries such as Three.js use these callbacks to mark VideoTextures dirty.
      // They run once the host's decoded frame is ready, before the page draws it.
      let callbackID = 0;
      HTMLVideoElement.prototype.requestVideoFrameCallback = function(callback) {
        let callbacks = window.__html2videoFrameCallbacks.get(this);
        if (!callbacks) window.__html2videoFrameCallbacks.set(this, callbacks = new Map());
        callbacks.set(++callbackID, callback);
        return callbackID;
      };
      HTMLVideoElement.prototype.cancelVideoFrameCallback = function(id) {
        window.__html2videoFrameCallbacks.get(this)?.delete(id);
      };
    })();
    window.__html2videoErrors = [];
    addEventListener('error', event => {
      window.__html2videoErrors.push(event.message || ('Failed to load ' + (event.target.src || event.target.href || event.target.tagName)));
    }, true);
    addEventListener('unhandledrejection', event => {
      window.__html2videoErrors.push(String(event.reason));
    });
    """#

  static let prepare = #"""
    // A compiled page owns binding/scoping; the standalone path handles root variables.
    if (!window.__hf && !window.__player) {
      if (document.querySelector('[data-variable-values]'))
        throw new Error('Per-instance variables require a compiled HyperFrames page.');
      const values = window.__hyperframes.getVariables();
      for (const el of document.querySelectorAll('[data-composition-variables]')) {
        for (const entry of JSON.parse(el.dataset.compositionVariables)) {
          const value = values[entry.id];
          if (typeof value !== 'string' && typeof value !== 'number') continue;
          const name = '--' + (entry.id.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'node');
          if (Object.hasOwn(window.__hfVariables, entry.id) || !getComputedStyle(el).getPropertyValue(name).trim())
            el.style.setProperty(name, String(value));
        }
      }
      for (const el of document.querySelectorAll('[data-var-text], [data-var-src]')) {
        const text = values[el.dataset.varText];
        if (text !== undefined) {
          const nodes = Array.from(el.childNodes).filter(n => n.nodeType === Node.TEXT_NODE);
          if (nodes.length) { nodes[0].textContent = String(text); nodes.slice(1).forEach(n => n.remove()); }
          else el.prepend(document.createTextNode(String(text)));
        }
        const src = values[el.dataset.varSrc];
        if (src !== undefined) el.src = typeof src === 'object' ? src.url : String(src);
      }
    }
    await document.fonts.ready;
    await Promise.all(Array.from(document.images, async image => {
      if (!image.complete) await new Promise((resolve, reject) => {
        image.addEventListener('load', resolve, {once: true});
        image.addEventListener('error', () => reject(new Error('Image failed: ' + image.src)), {once: true});
      });
      if (!image.naturalWidth) throw new Error('Image failed: ' + image.src);
      if (image.decode) await image.decode();
    }));
    if (window.__html2videoErrors.length) throw new Error(window.__html2videoErrors.join('\n'));
    const roots = Array.from(document.querySelectorAll('[data-composition-id]'))
      .filter(el => !el.parentElement?.closest('[data-composition-id]'));
    if (roots.length > 1) throw new Error('Export requires one root composition. A navigable deck is not a linear video.');
    const root = roots[0];
    const custom = window.html2video;
    const runtime = window.__hf;
    if (runtime?.protocolVersion !== undefined && runtime.protocolVersion !== 1)
      throw new Error('Unsupported HyperFrames protocol version: ' + runtime.protocolVersion);
    if (runtime || window.__player) {
      while (window.__renderReady === false || window.__playerReady === false)
        await new Promise(resolve => setTimeout(resolve, 20));
      window.__player?.pause?.();
      // Native capture owns media timing and audio sampling. Prevent the preview
      // transport from replacing authored gain with HTMLMediaElement's 0…1 fader.
      window.dispatchEvent(new MessageEvent('message', {source: window, data: {
        source: 'hf-parent', type: 'control', action: 'set-native-media-sync-disabled', disabled: true
      }}));
    }
    if (!runtime && !window.__player && document.querySelector('[data-composition-src]'))
      throw new Error('External sub-compositions need a compiled HyperFrames page with its runtime.');

    for (const timeline of Object.values(window.__timelines)) timeline.pause?.();
    window.gsap?.ticker?.sleep();
    for (const animation of document.getAnimations()) animation.pause();
    const width = requestedWidth || custom?.width || Number(root?.dataset.width) || innerWidth;
    const height = requestedHeight || custom?.height || Number(root?.dataset.height) || innerHeight;
    let duration = requestedDuration || custom?.duration || Number(root?.dataset.duration);
    if (!duration && root) duration = window.__timelines[root.dataset.compositionId]?.duration?.();
    if (!duration || !Number.isFinite(duration)) throw new Error('Specify --duration, data-duration, or html2video.duration.');
    // A raw composition's clips are evaluated against their owning composition time.
    const compositionOffset = el => {
      let offset = 0;
      for (let owner = el?.closest('[data-composition-id]'); owner && owner !== root;
        owner = owner.parentElement?.closest('[data-composition-id]')) {
        offset += Number(owner.dataset.start || 0);
      }
      return offset;
    };
    const mapTime = (value, from, to, first, last) => {
      if (value <= 0) return value * first;
      const end = from.length - 1;
      if (value >= from[end]) return to[end] + (value - from[end]) * last;
      let lo = 0, hi = end;
      while (hi - lo > 1) {
        const mid = (lo + hi) >> 1;
        if (from[mid] <= value) lo = mid; else hi = mid;
      }
      return to[lo] + (to[hi] - to[lo]) * (value - from[lo]) / (from[hi] - from[lo]);
    };
    const groups = new Map(Array.from(document.querySelectorAll('hf-audio-group')).map(el => [
      el.dataset.hfRenderId || el.id, {id: el.dataset.hfRenderId || el.id,
        fxChain: el.getAttribute('data-fx-chain'),
        automation: el.dataset.automation ? JSON.parse(el.dataset.automation) : {version: 1, lanes: []},
        volume: Number(el.dataset.volume ?? 1), hidden: el.hasAttribute('data-hidden')}
    ]));
    const renderIDs = new Set();
    const media = await Promise.all(Array.from(document.querySelectorAll('video, audio'), async (el, index) => {
      el.pause();
      el.muted = true; // Sound is mixed offline; never play into the device speakers.
      const src = el.currentSrc || el.src || el.querySelector('source')?.src;
      const automation = el.dataset.automation ? JSON.parse(el.dataset.automation) : {version: 1, lanes: []};
      if (automation.version !== 1 || !Array.isArray(automation.lanes)) throw new Error('Invalid media automation schema.');
      const fxChain = el.getAttribute('data-fx-chain');
      const groupID = el.tagName === 'AUDIO' && (el.dataset.hfGroupRenderId || el.dataset.audioGroup);
      const group = groupID ? (groups.get(groupID) || {id: groupID, volume: 1}) : null;
      const rate = Number(el.dataset.playbackRate || 1);
      const ratePoints = automation.lanes.find(lane => lane.target === 'rate' && lane.points?.length)?.points || [];
      const metadata = await window.webkit.messageHandlers.html2videoMedia.postMessage({operation: 'metadata', src, rate, ratePoints});
      const rateMap = metadata.rateMap;
      const naturalDuration = source => mapTime(source, rateMap.sources, rateMap.times, 1 / rateMap.firstRate, 1 / rateMap.lastRate);
      const sourceDuration = metadata.duration;
      if (el.tagName === 'VIDEO') {
        if (!el.hasAttribute('width')) el.width = metadata.width;
        if (!el.hasAttribute('height')) el.height = metadata.height;
      }
      el.removeAttribute('src');
      el.querySelectorAll('source').forEach(source => source.remove());
      el.load();
      if (el.tagName === 'VIDEO') {
        let renderID = el.dataset.hfRenderId || el.id || 'html2video-video-' + index;
        while (renderIDs.has(renderID) || document.getElementById('__render_frame_' + renderID + '__')) renderID += '_';
        renderIDs.add(renderID);
        el.dataset.hfRenderId = renderID;
        const image = new Image();
        image.id = '__render_frame_' + renderID + '__';
        image.className = '__render_frame__';
        // DOM painting stays with the video's poster so its original CSS still applies.
        image.style.setProperty('display', 'none', 'important');
        el.after(image);
        const state = {image, time: 0, presentedFrames: 0};
        window.__html2videoFrames.set(el, state);
        Object.defineProperties(el, {
          readyState: {get: () => image.naturalWidth ? HTMLMediaElement.HAVE_ENOUGH_DATA : HTMLMediaElement.HAVE_NOTHING},
          videoWidth: {get: () => metadata.width}, videoHeight: {get: () => metadata.height},
          duration: {get: () => sourceDuration},
          currentTime: {get: () => state.time, set: () => {}} // The export clock owns source time.
        });
      }
      const start = Number(el.dataset.start || 0) +
        (el.dataset.hfMediaStartBasis === 'global' ? 0 : compositionOffset(el.parentElement));
      const trim = Number(el.dataset.mediaStart || 0);
      if (!Number.isFinite(start) || !Number.isFinite(trim) || trim < 0 || trim >= sourceDuration) throw new Error('Invalid media timing: ' + el.currentSrc);
      const length = el.hasAttribute('data-duration') ? Number(el.dataset.duration) : naturalDuration(sourceDuration - trim);
      if (!Number.isFinite(length) || length <= 0) throw new Error('Invalid media duration: ' + el.currentSrc);
      if (el.hasAttribute('data-audio-fx') || el.hasAttribute('data-audio-effects')) throw new Error('Use data-fx-chain for audio effects.');
      let end = start + length;
      let visibleStart = start;
      for (let owner = el.parentElement; owner; owner = owner.parentElement) {
        if (owner.hasAttribute('data-start')) {
          const offset = Number(owner.dataset.start || 0) + compositionOffset(owner.parentElement);
          visibleStart = Math.max(visibleStart, offset);
          if (owner.hasAttribute('data-duration')) end = Math.min(end, offset + Number(owner.dataset.duration));
        }
      }
      // Preserve authored gain for timeline sampling; the muted media element's
      // native volume remains in 0…1. Offline Web Audio applies the full gain.
      if (el.tagName === 'AUDIO') {
        const nativeSet = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume').set;
        let authored = Number(el.dataset.volume ?? el.volume);
        Object.defineProperty(el, 'volume', {configurable: true, get: () => authored, set: value => {
          authored = Number(value);
          nativeSet.call(el, Math.min(1, Math.max(0, authored)));
        }});
        el.volume = authored;
      } else if (el.hasAttribute('data-volume')) el.volume = Math.min(1, Math.max(0, Number(el.dataset.volume)));
      return {el, src, sourceDuration, start, visibleStart, end, duration: length, trim, rateMap,
        fadeIn: el.getAttribute('data-fade-in'), fadeOut: el.getAttribute('data-fade-out'),
        ...(fxChain !== null ? {fxChain} : {}), ...(group ? {group} : {}), automation,
        // Rate changes also need bounded PCM preparation: native export can
        // otherwise drain pitch-conversion samples beyond the clip's end.
        hasEffects: fxChain !== null || automation.lanes.length > 0 || rateMap.firstRate !== 1 ||
          Number.parseFloat(el.dataset.fadeIn) > 0 || Number.parseFloat(el.dataset.fadeOut) > 0,
        loop: el.loop, volume: Number(el.dataset.volume ?? el.volume),
        points: automation.lanes?.find(lane => lane.target === 'volume')?.points || [],
        samples: [], visibility: el.style.visibility};
    }));
    const clips = Array.from(document.querySelectorAll('[data-start]')).map(el => ({
      el, visibility: el.style.visibility, start: Number(el.dataset.start || 0) + compositionOffset(el.parentElement),
      duration: Number(el.dataset.duration), end: Number(el.dataset.end) + compositionOffset(el.parentElement)
    }));
    window.__html2videoSeek = async seconds => {
      if (window.__html2videoErrors.length) throw new Error(window.__html2videoErrors.join('\n'));
      // Decode before seek: Canvas/WebGL adapters must consume this frame, not the last one.
      for (const item of media) {
        const state = window.__html2videoFrames.get(item.el);
        if (!state) continue;
        const localTime = Math.max(0, Math.min(seconds, item.end) - item.start);
        let time = mapTime(localTime, item.rateMap.times, item.rateMap.sources, item.rateMap.firstRate, item.rateMap.lastRate);
        time = item.trim + (item.loop ? time % (item.sourceDuration - item.trim) : time);
        time = Math.min(time, Math.max(0, item.sourceDuration - 0.000001));
        const poster = await window.webkit.messageHandlers.html2videoMedia.postMessage({operation: 'frame', src: item.src, time});
        state.image.src = poster;
        await state.image.decode();
        state.time = time;
        state.presentedFrames++;
        item.el.poster = poster;
      }
      for (const item of media) {
        const state = window.__html2videoFrames.get(item.el);
        const callbacks = window.__html2videoFrameCallbacks.get(item.el);
        if (!state || !callbacks?.size) continue;
        const pending = Array.from(callbacks.keys());
        const now = performance.now();
        for (const id of pending) {
          const callback = callbacks.get(id);
          callbacks.delete(id);
          callback?.(now, {presentationTime: now, expectedDisplayTime: now, mediaTime: state.time,
            presentedFrames: state.presentedFrames, width: state.image.naturalWidth, height: state.image.naturalHeight,
            processingDuration: 0});
        }
      }
      if (custom?.seek) {
        await custom.seek(seconds);
      } else if (window.__player?.renderSeek) {
        await window.__player.renderSeek(seconds);
      } else if (runtime?.seek) {
        await runtime.seek(seconds);
      } else {
        for (const [id, timeline] of Object.entries(window.__timelines)) {
          const el = Array.from(document.querySelectorAll('[data-composition-id]')).find(e => e.dataset.compositionId === id);
          const start = compositionOffset(el);
          timeline.pause?.();
          timeline.seek(Math.max(0, seconds - start), false);
        }
        for (const clip of clips) {
          const end = clip.el.hasAttribute('data-duration') ? clip.start + clip.duration :
            clip.el.hasAttribute('data-end') ? clip.end : Infinity;
          clip.el.style.visibility = seconds >= clip.start && seconds < end && !clip.el.hasAttribute('data-hidden') ? clip.visibility : 'hidden';
        }
        const pending = [];
        dispatchEvent(new CustomEvent('hf-seek', {detail: {time: seconds, timeSeconds: seconds,
          waitUntil: promise => pending.push(Promise.resolve(promise))}}));
        await Promise.all(pending);
      }
      if (window.__hfWaitForSeekCompletion) await window.__hfWaitForSeekCompletion();
      // The runtime deduplicates hf-seek by time, including an initial seek to zero.
      // Use its injection hook after the first render settles so the new pixels paint.
      if (!custom?.seek && window.__hfReseekGpu && media.some(item => item.el.tagName === 'VIDEO')) {
        await window.__hfReseekGpu(seconds);
        if (window.__hfWaitForSeekCompletion) await window.__hfWaitForSeekCompletion();
      }
      if (!custom?.seek && !runtime && !window.__player) {
        for (const animation of document.getAnimations()) {
          animation.pause();
          animation.currentTime = seconds * 1000;
        }
      }
      for (const item of media) {
        const {el, start, visibleStart, end} = item;
        el.pause();
        el.muted = true;
        if (el.tagName === 'AUDIO') {
          if (!item.points.length && seconds >= visibleStart && seconds < end) {
            const point = {t: seconds - start, v: el.volume};
            const samples = item.samples;
            if (samples.length && point.t === samples[samples.length - 1].t) samples.pop();
            // Keep endpoints of constant runs without retaining a point for every output frame.
            if (samples.length > 1 && samples[samples.length - 1].v === point.v && samples[samples.length - 2].v === point.v)
              samples.pop();
            samples.push(point);
          }
          continue;
        }
        const active = seconds >= visibleStart && seconds < end && !el.hasAttribute('data-hidden');
        el.style.visibility = active ? item.visibility : 'hidden';
      }
      window.gsap?.ticker?.sleep();
      await document.fonts.ready;
      // Force style/layout before WebKit captures the page.
      document.documentElement.getBoundingClientRect();
      if (window.__html2videoErrors.length) throw new Error(window.__html2videoErrors.join('\n'));
    };
    window.__html2videoAudio = () => media.filter(item => item.el.tagName === 'AUDIO' && !item.el.closest('[data-hidden]') && !item.group?.hidden)
      .map(({el, visibility, samples, ...item}) => {
        const points = item.points.length ? item.points : samples;
        return {...item, points, hasEffects: item.hasEffects || item.volume > 1 || points.some(p => p.v > 1)};
      });
    await window.__html2videoSeek(0);
    return {width, height, duration, audio: window.__html2videoAudio()};
    """#
}

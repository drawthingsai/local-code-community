"use strict";var HyperframesPlayer=(()=>{var Te=Object.defineProperty;var bn=Object.getOwnPropertyDescriptor;var gn=Object.getOwnPropertyNames;var _n=Object.prototype.hasOwnProperty;var yn=(n,e)=>{for(var t in e)Te(n,t,{get:e[t],enumerable:!0})},vn=(n,e,t,i)=>{if(e&&typeof e=="object"||typeof e=="function")for(let r of gn(e))!_n.call(n,r)&&r!==t&&Te(n,r,{get:()=>e[r],enumerable:!(i=bn(e,r))||i.enumerable});return n};var An=n=>vn(Te({},"__esModule",{value:!0}),n);var Ji={};yn(Ji,{HyperframesPlayer:()=>Se,SPEED_PRESETS:()=>Re,formatSpeed:()=>G,formatTime:()=>oe});function pt(n){return n.hasRuntime||n.runtimeInjected?!1:!!(n.hasNestedCompositions||n.hasTimelines&&n.attempts>=5)}function H(n){return typeof n=="object"&&n!==null}function ft(n){return H(n)&&typeof n.getDuration=="function"}function ht(n){return H(n)&&typeof n.duration=="function"&&typeof n.time=="function"&&typeof n.seek=="function"&&typeof n.play=="function"&&typeof n.pause=="function"}var L="https://cdn.jsdelivr.net/npm/@hyperframes/core@0.8.77/dist/hyperframe.runtime.iife.js";function V(n){if(n===null)return null;let e=Number.parseInt(n,10);return Number.isFinite(e)&&e>0?e:null}function En(n){let e=n?.querySelector("[data-composition-id][data-width][data-height]")??n?.querySelector("[data-width][data-height]");if(!e)return null;let t=V(e.getAttribute("data-width")),i=V(e.getAttribute("data-height"));return t!==null&&i!==null?{width:t,height:i}:null}var re=class{constructor(e,t){this._iframe=e;this._callbacks=t}_iframe;_callbacks;_interval=null;_runtimeInjected=!1;get runtimeInjected(){return this._runtimeInjected}start(){this.stop(),this._runtimeInjected=!1;let e=0;this._interval=setInterval(()=>{e++;try{let t=this._iframe.contentWindow;if(!t)return;let i=!!(t.__hf||t.__player),r=!!(t.__timelines&&Object.keys(t.__timelines).length>0),o=!!this._iframe.contentDocument?.querySelector("[data-composition-src]");if(pt({hasRuntime:i,hasTimelines:r,hasNestedCompositions:o,runtimeInjected:this._runtimeInjected,attempts:e})){this._injectRuntime();return}if(this._runtimeInjected&&!i)return;let a=this._resolvePlaybackDurationAdapter(t);if(a&&a.getDuration()>0){this.stop();let s=En(this._iframe.contentDocument);this._callbacks.onReady({duration:a.getDuration(),adapter:a,compositionSize:s});return}}catch{}e>=40&&(this.stop(),this._callbacks.onError("Composition timeline not found after 8s"))},200)}stop(){this._interval!==null&&(clearInterval(this._interval),this._interval=null)}resolveDirectTimelineAdapter(){try{let e=this._iframe.contentWindow;return e?this._resolveDirectTimelineAdapterFromWindow(e):null}catch{return null}}resolveDirectTimelineAdapterFromWindow(e){return this._resolveDirectTimelineAdapterFromWindow(e)}hasRuntimeBridge(e){return Reflect.get(e,"__hf")!==void 0||H(Reflect.get(e,"__player"))}_injectRuntime(){this._runtimeInjected=!0;try{let e=this._iframe.contentDocument;if(!e)return;let t=e.createElement("script");t.src=L,(e.head||e.documentElement).appendChild(t),this._callbacks.onRuntimeInjected?.()}catch{}}_resolveDirectTimelineAdapterFromWindow(e){if(this.hasRuntimeBridge(e))return null;let t=Reflect.get(e,"__timelines");if(!H(t))return null;let i=Object.keys(t);if(i.length===0)return null;let r=this._iframe.contentDocument?.querySelector("[data-composition-id]")?.getAttribute("data-composition-id"),o=r&&r in t?r:i[i.length-1],a=t[o];return ht(a)?a:null}_resolvePlaybackDurationAdapter(e){let t=Reflect.get(e,"__player");if(ft(t))return{kind:"runtime",getDuration:()=>t.getDuration()};let i=this._resolveDirectTimelineAdapterFromWindow(e);return i?{kind:"direct-timeline",timeline:i,getDuration:()=>i.duration()}:null}};var bt=`
  :host {
    display: block;
    position: relative;
    overflow: hidden;
    background: #000;
    contain: layout style;
  }

  .hfp-container {
    position: absolute;
    inset: 0;
    overflow: hidden;
    pointer-events: none;
  }


  .hfp-iframe {
    position: absolute;
    top: 50%;
    left: 50%;
    border: none;
    pointer-events: none;
  }

  /* Opt-in: an interactive composition (e.g. a live slideshow/app with playable
     media or controls) \u2014 let pointer events reach the iframe content. */
  :host([interactive]) .hfp-container,
  :host([interactive]) .hfp-iframe {
    pointer-events: auto;
  }

  .hfp-poster {
    position: absolute;
    inset: 0;
    object-fit: contain;
    z-index: 1;
    pointer-events: none;
  }

  .hfp-shader-loader {
    position: absolute;
    inset: 0;
    z-index: 20;
    display: grid;
    place-items: center;
    visibility: hidden;
    opacity: 0;
    pointer-events: none;
    background: #030504;
    color: #f4f7fb;
    cursor: default;
    user-select: none;
    -webkit-user-select: none;
    transition: opacity 420ms ease-out, visibility 420ms ease-out;
  }

  .hfp-shader-loader.hfp-visible,
  .hfp-shader-loader.hfp-hiding {
    visibility: visible;
  }

  .hfp-shader-loader.hfp-visible {
    opacity: 1;
    pointer-events: auto;
  }

  .hfp-shader-loader.hfp-hiding {
    opacity: 0;
    pointer-events: none;
  }

  .hfp-shader-loader-panel {
    display: grid;
    grid-template-rows: 86px 40px 26px 12px 44px;
    justify-items: center;
    align-items: center;
    gap: 8px;
    width: min(620px, 82%);
    text-align: center;
    font-family: Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }

  .hfp-shader-loader-mark {
    width: 86px;
    height: 86px;
    display: grid;
    place-items: center;
    overflow: visible;
  }

  .hfp-shader-loader-mark svg {
    display: block;
    overflow: visible;
    filter: drop-shadow(0 0 5px rgba(79, 219, 94, 0.16));
    pointer-events: none;
  }

  .hfp-shader-loader-title {
    width: 100%;
    height: 40px;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    font-size: 26px;
    line-height: 40px;
    font-weight: 700;
    letter-spacing: 0;
  }

  .hfp-shader-loader-title-text {
    color: transparent;
    background: linear-gradient(
      90deg,
      rgba(244, 247, 251, 0.84) 0%,
      #ffffff 42%,
      #80efe4 52%,
      #ffffff 62%,
      rgba(244, 247, 251, 0.84) 100%
    );
    background-size: 220% 100%;
    -webkit-background-clip: text;
    background-clip: text;
    animation: hfp-shader-loader-sheen 1.9s linear infinite;
  }

  .hfp-shader-loader:not(.hfp-visible):not(.hfp-hiding) .hfp-shader-loader-title-text {
    animation-play-state: paused;
  }

  .hfp-shader-loader-detail {
    width: 100%;
    height: 26px;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    color: rgba(244, 247, 251, 0.62);
    font-size: 15px;
    line-height: 26px;
    font-weight: 500;
  }

  .hfp-shader-loader-track {
    width: min(360px, 100%);
    height: 8px;
    overflow: hidden;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.1);
  }

  .hfp-shader-loader-fill {
    width: 100%;
    height: 100%;
    border-radius: inherit;
    background: linear-gradient(90deg, #06e3fa, #4fdb5e);
    transform: scaleX(0);
    transform-origin: left center;
    transition: transform 160ms ease;
  }

  .hfp-shader-loader-progress {
    width: min(420px, 100%);
    height: 44px;
    display: grid;
    grid-template-rows: repeat(2, 22px);
    color: rgba(244, 247, 251, 0.48);
    font: 600 13px/22px "IBM Plex Mono", "SF Mono", "Fira Code", "Courier New", monospace;
    font-variant-numeric: tabular-nums;
  }

  .hfp-shader-loader-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 74px;
    align-items: center;
    column-gap: 20px;
    width: 100%;
    white-space: nowrap;
  }

  .hfp-shader-loader-label {
    min-width: 0;
    overflow: hidden;
    text-align: left;
    text-overflow: ellipsis;
  }

  .hfp-shader-loader-value {
    text-align: right;
  }

  @keyframes hfp-shader-loader-sheen {
    from {
      background-position: 140% 0;
    }
    to {
      background-position: -140% 0;
    }
  }

  /* \u2500\u2500 Theming via CSS custom properties \u2500\u2500
   *
   * Override from outside the shadow DOM:
   *   hyperframes-player {
   *     --hfp-controls-bg: linear-gradient(transparent, rgba(0,0,0,0.9));
   *     --hfp-accent: #ff6b6b;
   *     --hfp-font: "Inter", sans-serif;
   *   }
   */

  .hfp-controls {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    display: flex;
    align-items: center;
    gap: var(--hfp-controls-gap, 12px);
    padding: var(--hfp-controls-padding, 8px 16px);
    background: var(--hfp-controls-bg, linear-gradient(transparent, rgba(0, 0, 0, 0.7)));
    color: var(--hfp-color, #fff);
    font-family: var(--hfp-font, system-ui, -apple-system, sans-serif);
    font-size: var(--hfp-font-size, 13px);
    z-index: 10;
    pointer-events: auto;
    opacity: 1;
    transition: opacity 0.3s ease;
    user-select: none;
  }

  .hfp-controls.hfp-hidden {
    opacity: 0;
    pointer-events: none;
  }

  .hfp-play-btn {
    position: relative;
    background: none;
    border: none;
    color: var(--hfp-color, #fff);
    cursor: pointer;
    padding: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 40px;
    height: 40px;
    flex-shrink: 0;
    z-index: 10;
  }

  .hfp-play-btn:hover {
    opacity: 0.8;
  }

  /* Stacked play/pause glyphs that crossfade-morph on toggle (rotate + scale). */
  .hfp-play-btn .hfp-ico {
    position: absolute;
    display: flex;
    align-items: center;
    justify-content: center;
    transition:
      opacity 200ms ease,
      transform 220ms cubic-bezier(0.4, 0, 0.2, 1);
  }
  .hfp-play-btn .hfp-ico-play {
    opacity: 1;
    transform: rotate(0) scale(1);
  }
  .hfp-play-btn .hfp-ico-pause {
    opacity: 0;
    transform: rotate(-90deg) scale(0.4);
  }
  .hfp-play-btn.hfp-playing .hfp-ico-play {
    opacity: 0;
    transform: rotate(90deg) scale(0.4);
  }
  .hfp-play-btn.hfp-playing .hfp-ico-pause {
    opacity: 1;
    transform: rotate(0) scale(1);
  }
  @media (prefers-reduced-motion: reduce) {
    .hfp-play-btn .hfp-ico {
      transition-duration: 0ms;
      transform: none;
    }
  }

  .hfp-play-btn svg,
  .hfp-play-btn svg * {
    pointer-events: none;
  }

  .hfp-scrubber {
    flex: 1;
    min-width: 0;
    height: var(--hfp-scrubber-height, 4px);
    background: var(--hfp-scrubber-bg, rgba(255, 255, 255, 0.3));
    border-radius: var(--hfp-scrubber-radius, 2px);
    cursor: pointer;
    position: relative;
    overflow: hidden;
  }

  .hfp-scrubber:hover {
    height: var(--hfp-scrubber-height-hover, 6px);
  }

  .hfp-progress {
    position: absolute;
    top: 0;
    left: 0;
    height: 100%;
    background: var(--hfp-accent, #fff);
    pointer-events: none;
  }

  .hfp-time {
    flex-shrink: 0;
    font-variant-numeric: tabular-nums;
    opacity: 0.9;
  }

  .hfp-speed-wrap {
    position: relative;
    flex-shrink: 0;
  }

  .hfp-speed-btn {
    background: var(--hfp-speed-btn-bg, rgba(255, 255, 255, 0.15));
    border: none;
    border-radius: var(--hfp-speed-btn-radius, 4px);
    color: var(--hfp-color, #fff);
    cursor: pointer;
    font-family: var(--hfp-font, system-ui, -apple-system, sans-serif);
    font-size: 12px;
    font-variant-numeric: tabular-nums;
    font-weight: 600;
    padding: 4px 8px;
    min-width: 40px;
    text-align: center;
    transition: background 0.15s ease;
  }

  .hfp-speed-btn:hover {
    background: var(--hfp-speed-btn-bg-hover, rgba(255, 255, 255, 0.3));
  }

  .hfp-speed-menu {
    position: absolute;
    bottom: calc(100% + 8px);
    right: 0;
    background: var(--hfp-menu-bg, rgba(20, 20, 20, 0.95));
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    border: 1px solid var(--hfp-menu-border, rgba(255, 255, 255, 0.1));
    border-radius: var(--hfp-menu-radius, 8px);
    padding: 4px;
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 80px;
    opacity: 0;
    visibility: hidden;
    transform: translateY(4px);
    transition: opacity 0.15s ease, transform 0.15s ease, visibility 0.15s;
    box-shadow: var(--hfp-menu-shadow, 0 8px 24px rgba(0, 0, 0, 0.4));
  }

  .hfp-speed-menu.hfp-open {
    opacity: 1;
    visibility: visible;
    transform: translateY(0);
  }

  .hfp-speed-option {
    background: none;
    border: none;
    border-radius: 4px;
    color: var(--hfp-menu-color, rgba(255, 255, 255, 0.7));
    cursor: pointer;
    font-family: var(--hfp-font, system-ui, -apple-system, sans-serif);
    font-size: 13px;
    font-variant-numeric: tabular-nums;
    padding: 6px 12px;
    text-align: left;
    transition: background 0.1s ease, color 0.1s ease;
    white-space: nowrap;
  }

  .hfp-speed-option:hover {
    background: var(--hfp-menu-hover-bg, rgba(255, 255, 255, 0.1));
    color: var(--hfp-color, #fff);
  }

  .hfp-speed-option.hfp-active {
    color: var(--hfp-accent, #fff);
    font-weight: 600;
  }

  .hfp-volume-wrap {
    position: relative;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 0;
  }

  .hfp-mute-btn {
    background: none;
    border: none;
    color: var(--hfp-color, #fff);
    cursor: pointer;
    padding: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    flex-shrink: 0;
  }

  .hfp-mute-btn:hover {
    opacity: 0.8;
  }

  .hfp-mute-btn svg,
  .hfp-mute-btn svg * {
    pointer-events: none;
  }

  .hfp-volume-slider-wrap {
    width: 0;
    overflow: hidden;
    transition: width 0.2s ease;
    display: flex;
    align-items: center;
  }

  .hfp-volume-wrap:hover .hfp-volume-slider-wrap {
    width: 64px;
  }

  .hfp-volume-slider {
    width: 56px;
    height: var(--hfp-scrubber-height, 4px);
    background: var(--hfp-scrubber-bg, rgba(255, 255, 255, 0.3));
    border-radius: var(--hfp-scrubber-radius, 2px);
    cursor: pointer;
    position: relative;
    overflow: hidden;
    margin-left: 4px;
    margin-right: 4px;
  }

  .hfp-volume-fill {
    position: absolute;
    top: 0;
    left: 0;
    height: 100%;
    background: var(--hfp-accent, #fff);
    pointer-events: none;
  }
`,gt='<svg width="24" height="24" viewBox="46 21 54 56" fill="currentColor"><path d="M87.5129 57.5141L56.9696 73.5433C52.8371 75.7098 48.7046 73.2553 49.6688 69.2104L58.9483 30.1391C59.9125 26.0942 65.2097 23.6397 68.3154 25.8062L91.2447 41.8354C96.4668 45.4796 94.4631 53.8699 87.5129 57.5141Z"/></svg>',_t='<svg width="24" height="24" viewBox="0 0 18 18" fill="currentColor"><rect x="3" y="2" width="4" height="14"/><rect x="11" y="2" width="4" height="14"/></svg>',xe='<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3z"/><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02z"/><path d="M14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>',we='<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3z"/><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02z"/></svg>',yt='<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3z"/><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02z" opacity="0.3"/><line x1="18" y1="7" x2="14" y2="17" stroke="currentColor" stroke-width="2"/></svg>';var Re=[.25,.5,1,1.5,2,4];function G(n){return Number.isInteger(n)?`${n}x`:`${n}x`}function oe(n){if(!Number.isFinite(n)||n<0)return"0:00";let e=Math.floor(n),t=Math.floor(e/60),i=e%60;return`${t}:${i.toString().padStart(2,"0")}`}function vt(n,e,t={}){let i=t.speedPresets??Re,r=document.createElement("div");r.className="hfp-controls",r.addEventListener("click",l=>{l.stopPropagation()});let o=document.createElement("button");o.className="hfp-play-btn",o.type="button",o.innerHTML=`<span class="hfp-ico hfp-ico-play">${gt}</span><span class="hfp-ico hfp-ico-pause">${_t}</span>`,o.setAttribute("aria-label","Play");let a=document.createElement("div");a.className="hfp-scrubber";let s=document.createElement("div");s.className="hfp-progress",s.style.width="0%",a.appendChild(s);let u=document.createElement("span");u.className="hfp-time",u.textContent="0:00 / 0:00";let d=document.createElement("div");d.className="hfp-speed-wrap";let c=document.createElement("button");c.className="hfp-speed-btn",c.type="button",c.textContent="1x",c.setAttribute("aria-label","Playback speed");let g=document.createElement("div");g.className="hfp-speed-menu",g.setAttribute("role","menu");for(let l of i){let p=document.createElement("button");p.className="hfp-speed-option",p.type="button",p.setAttribute("role","menuitem"),p.dataset.speed=String(l),p.textContent=G(l),l===1&&p.classList.add("hfp-active"),g.appendChild(p)}d.appendChild(g),d.appendChild(c);let m=document.createElement("div");m.className="hfp-volume-wrap";let f=document.createElement("button");f.className="hfp-mute-btn",f.type="button",f.innerHTML=xe,f.setAttribute("aria-label","Mute");let h=document.createElement("div");h.className="hfp-volume-slider-wrap";let b=document.createElement("div");b.className="hfp-volume-slider",b.setAttribute("role","slider"),b.setAttribute("aria-label","Volume"),b.setAttribute("aria-valuemin","0"),b.setAttribute("aria-valuemax","100"),b.setAttribute("aria-valuenow","100"),b.tabIndex=0;let y=document.createElement("div");y.className="hfp-volume-fill",y.style.width="100%",b.appendChild(y),h.appendChild(b),m.appendChild(h),m.appendChild(f),t.audioLocked&&(m.style.display="none"),r.appendChild(o),r.appendChild(a),r.appendChild(u),r.appendChild(m),r.appendChild(d),n.appendChild(r);let S=!1,v=!1,w=1,A=null,R=i.indexOf(1);R===-1&&(R=0);let ee=(l,p)=>l?yt:p===0?we:p<.5?we:xe;o.addEventListener("click",l=>{l.stopPropagation(),S?e.onPause():e.onPlay()}),f.addEventListener("click",l=>{l.stopPropagation(),e.onMuteToggle()});let N=!1,te=l=>{let p=b.getBoundingClientRect(),E=Math.max(0,Math.min(1,(l-p.left)/p.width));w=E,y.style.width=`${E*100}%`,b.setAttribute("aria-valuenow",String(Math.round(E*100))),v&&E>0&&e.onMuteToggle(),f.innerHTML=ee(v,E),e.onVolumeChange(E)};b.addEventListener("mousedown",l=>{l.stopPropagation(),N=!0,te(l.clientX)});let Qe=l=>{N&&te(l.clientX)},et=()=>{N=!1};document.addEventListener("mousemove",Qe),document.addEventListener("mouseup",et),b.addEventListener("touchstart",l=>{N=!0;let p=l.touches[0];p&&te(p.clientX)},{passive:!0});let tt=l=>{if(N){let p=l.touches[0];p&&te(p.clientX)}},nt=()=>{N=!1};document.addEventListener("touchmove",tt,{passive:!0}),document.addEventListener("touchend",nt);let it=.05;b.addEventListener("keydown",l=>{let p=w;if(l.key==="ArrowRight"||l.key==="ArrowUp")p=Math.min(1,w+it);else if(l.key==="ArrowLeft"||l.key==="ArrowDown")p=Math.max(0,w-it);else return;l.preventDefault(),l.stopPropagation(),w=p,y.style.width=`${p*100}%`,b.setAttribute("aria-valuenow",String(Math.round(p*100))),v&&p>0&&e.onMuteToggle(),f.innerHTML=ee(v,p),e.onVolumeChange(p)});let rt=l=>{for(let p of g.querySelectorAll(".hfp-speed-option"))p.classList.toggle("hfp-active",p.dataset.speed===String(l))};c.addEventListener("click",l=>{l.stopPropagation();let p=g.classList.toggle("hfp-open");c.setAttribute("aria-expanded",String(p))}),g.addEventListener("click",l=>{l.stopPropagation();let p=l.target.closest(".hfp-speed-option");if(!p)return;let E=parseFloat(p.dataset.speed);R=i.indexOf(E),c.textContent=G(E),rt(E),g.classList.remove("hfp-open"),c.setAttribute("aria-expanded","false"),e.onSpeedChange(E)});let ot=()=>{g.classList.remove("hfp-open"),c.setAttribute("aria-expanded","false")};document.addEventListener("click",ot);let ne=l=>{let p=a.getBoundingClientRect(),E=Math.max(0,Math.min(1,(l-p.left)/p.width));e.onSeek(E)},I=!1;a.addEventListener("mousedown",l=>{l.stopPropagation(),I=!0,e.onScrubStart?.(),ne(l.clientX)});let at=l=>{I&&ne(l.clientX)},st=()=>{I&&(I=!1,e.onScrubEnd?.())};document.addEventListener("mousemove",at),document.addEventListener("mouseup",st),a.addEventListener("touchstart",l=>{I=!0,e.onScrubStart?.();let p=l.touches[0];p&&ne(p.clientX)},{passive:!0});let ut=l=>{if(I){let p=l.touches[0];p&&ne(p.clientX)}},lt=()=>{I&&(I=!1,e.onScrubEnd?.())};document.addEventListener("touchmove",ut,{passive:!0}),document.addEventListener("touchend",lt);let dt=()=>{A&&clearTimeout(A),A=setTimeout(()=>{S&&r.classList.add("hfp-hidden")},3e3)},ie=n instanceof ShadowRoot?n.host:n,ct=()=>{r.classList.remove("hfp-hidden"),dt()},mt=()=>{S&&r.classList.add("hfp-hidden")};return ie.addEventListener("mousemove",ct),ie.addEventListener("mouseleave",mt),{updateTime(l,p){let E=p>0?Math.min(l,p):l,hn=p>0?E/p*100:0;s.style.width=`${hn}%`,u.textContent=`${oe(E)} / ${oe(p)}`},updatePlaying(l){S=l,o.classList.toggle("hfp-playing",l),o.setAttribute("aria-label",l?"Pause":"Play"),l?dt():r.classList.remove("hfp-hidden")},updateSpeed(l){let p=i.indexOf(l);p!==-1&&(R=p),c.textContent=G(l),rt(l)},updateMuted(l){v=l,f.innerHTML=ee(l,w),f.setAttribute("aria-label",l?"Unmute":"Mute")},updateVolume(l){w=l,y.style.width=`${l*100}%`,b.setAttribute("aria-valuenow",String(Math.round(l*100))),f.innerHTML=ee(v,l)},setVolumeControlsHidden(l){m.style.display=l?"none":""},show(){r.style.display=""},hide(){r.style.display="none"},destroy(){document.removeEventListener("mousemove",at),document.removeEventListener("mouseup",st),document.removeEventListener("touchmove",ut),document.removeEventListener("touchend",lt),document.removeEventListener("mousemove",Qe),document.removeEventListener("mouseup",et),document.removeEventListener("touchmove",tt),document.removeEventListener("touchend",nt),document.removeEventListener("click",ot),ie.removeEventListener("mousemove",ct),ie.removeEventListener("mouseleave",mt),A&&clearTimeout(A),r.remove()}}}function At(n,e,t,i,r,o=!1){let a=i?i.split(",").map(Number).filter(d=>!isNaN(d)&&d>0):void 0,s={...a?{speedPresets:a}:{},audioLocked:o},u=vt(n,r,s);return u.updateMuted(e),u.updateVolume(t),u}function ke(n,e,t){return e?(t||(t=document.createElement("img"),t.className="hfp-poster",n.appendChild(t)),t.src=e,t):(t?.remove(),null)}function Et(n){return n.composedPath().some(e=>e instanceof HTMLElement&&e.classList.contains("hfp-controls"))}var ae=null;function St(n,e){if(typeof CSSStyleSheet<"u")try{ae||(ae=new CSSStyleSheet,ae.replaceSync(e)),n.adoptedStyleSheets=[ae];return}catch{}let t=document.createElement("style");t.textContent=e,n.appendChild(t)}function Tt(){let n=document.createElement("div");n.className="hfp-container";let e=document.createElement("iframe");return e.className="hfp-iframe",e.sandbox.add("allow-scripts","allow-same-origin"),e.allow="autoplay; fullscreen",e.referrerPolicy="no-referrer",e.title="HyperFrames Composition",n.appendChild(e),{container:n,iframe:e}}function xt(n,e,t,i){let r=n.offsetWidth,o=n.offsetHeight;if(r===0||o===0)return!1;let a=Math.min(r/t,o/i);return e.style.width=`${t}px`,e.style.height=`${i}px`,e.style.transform=`translate(-50%, -50%) scale(${a})`,!0}var se=class{constructor(e){this._callbacks=e}_callbacks;_raf=null;_lastUpdateMs=0;start(e,t,i,r){this.stop();let o=()=>{if(r()){this._raf=null;return}let a;try{a=e.time()}catch{this._raf=null;return}let s=i();s>0&&(a=Math.min(a,s));let u=s>0&&a>=s,d=performance.now();if((d-this._lastUpdateMs>100||u)&&(this._lastUpdateMs=d,this._callbacks.onTimeUpdate(a,s)),u){if(this._callbacks.getLoop()){this._callbacks.restart();return}try{e.pause()}catch{}this._callbacks.onPaused(),this._raf=null;return}this._raf=requestAnimationFrame(o)};this._raf=requestAnimationFrame(o)}stop(){this._raf!==null&&(cancelAnimationFrame(this._raf),this._raf=null)}get isRunning(){return this._raf!==null}};function wt(n){let e=Array.from(n.querySelectorAll("[data-composition-id]"));if(e.length===0)return n.body?[n.body]:[];let t=[];for(let i of e)Tn(i)||t.push(i);return Sn(n),t}function Sn(n){let e=n.body;if(!e||typeof console>"u"||typeof console.warn!="function")return;let t=e.querySelectorAll("audio[data-start], video[data-start]");if(t.length===0)return;let i=[];for(let r of t)r.closest("[data-composition-id]")||i.push(r);i.length!==0&&console.warn(`[hyperframes-player] selectMediaObserverTargets: composition hosts are present, but ${i.length} body-level timed media element(s) sit outside every [data-composition-id] subtree and will not be observed. Move them inside a composition host or the parent-frame proxy will never adopt them.`,i)}function Tn(n){let e=n.parentElement;for(;e;){if(e.hasAttribute("data-composition-id"))return!0;e=e.parentElement}return!1}function Rt(){return globalThis}function B(n,e){if(typeof window>"u")return;let t=Rt(),i=t.__hf?.onSwallowed;if(i)try{i({label:n,error:e})}catch(r){}(t.__hfDebug||t.__HYPERFRAMES_DEBUG)&&console.debug(`[hyperframes] ${n} swallowed:`,e)}var kt="data-hf-authored-duration",Mt="data-hf-authored-end";function W(n){if(n==null||typeof n=="string"&&n.trim()==="")return null;let e=typeof n=="number"?n:Number(n);return Number.isFinite(e)?e:null}function ue(n){let e=W(n.start);if(e==null)return null;let t=Math.max(0,e),i=W(n.duration),r=W(n.authoredDuration),o=i!=null&&i>0?i:r!=null&&r>0?r:null;if(o!=null)return{start:t,duration:o,end:t+o};let a=W(n.end),s=W(n.authoredEnd),u=a!=null&&a>t?a:s!=null&&s>t?s:null;return{start:t,duration:u==null?null:u-t,end:u}}var P=Object.freeze({start:"data-start",duration:"data-duration",trackIndex:"data-track-index",derivedEnd:"data-end",legacyTrack:"data-layer"}),yr=Object.freeze([P.start,P.duration,P.trackIndex]),vr=Object.freeze([P.derivedEnd]),Ar=Object.freeze([P.derivedEnd,P.legacyTrack]);function Me(n){if(n==null||n.trim()==="")return null;let e=Number(n);return Number.isFinite(e)?e:null}var It=n=>{let e=Me(n);return e!==null&&e>=0?e:null};function Ct(n){return It(n("data-playback-start"))??It(n("data-media-start"))??0}var $=.1,q=10;function Ie(n){return Number.isFinite(n)&&n>0?Math.max($,Math.min(q,n)):1}function Dt(n,e=1){let t=Number.parseFloat(n("data-playback-rate")??"");return Ie(Number.isFinite(t)&&t>0?t:e)}function Nt(n){let e=Me(n("data-duration"));return e!==null&&e>0?e:null}function Lt(n,e){let t=Nt(n);if(t!==null)return t;let i=Me(n("data-end"));return i!==null?i-e:null}var xn=3;function Ce(n,e,t){return Number.isFinite(n)?Math.max(0,n-e)/Ie(t):null}function Pt(n){let{tag:e,authoredDurationSeconds:t,sourceDurationSeconds:i,mediaStartSeconds:r,playbackRate:o}=n;if(t!==null&&t>0)return{seconds:t,source:"authored"};if(e==="img")return{seconds:xn,source:"default"};if(i===null)return{seconds:null,source:"pending",reason:"source duration not yet probed"};let a=Ce(i,r,o);return a===null?{seconds:null,source:"pending",reason:"source reported a non-finite duration"}:{seconds:a,source:"media"}}var Ot="data-fx-chain",Sr=Ot.slice(5);var z=(n="frequency",e="Frequency",t=1e3,i=20,r=2e4)=>({kind:"number",key:n,label:e,unit:"Hz",min:i,max:r,step:1,default:t,scale:"log",automatable:!0}),De=(n=.707,e="Bandwidth \u2014 higher is narrower.")=>({kind:"number",key:"q",label:"Q",unit:"",min:.1,max:20,step:.01,default:n,scale:"log",automatable:!0,hint:e}),le=(n=-40,e=40,t=0)=>({kind:"number",key:"gain",label:"Gain",unit:"dB",min:n,max:e,step:.1,default:t,automatable:!0}),Ft={kind:"enum",key:"poles",label:"Slope",options:[{value:"1",label:"6 dB/oct"},{value:"2",label:"12 dB/oct"}],default:"2",hint:"Two poles is the usual biquad; one pole is gentler."},Ut=[{id:"gain",label:"Gain",group:"dynamics",description:"Raise or lower the whole signal. Automate it to duck under something else.",params:[le(-60,12,0)],web:"gain-node"},{id:"peaking",label:"Peaking EQ",group:"filter",description:"Boost or cut a band, leaving everything either side alone.",params:[z("frequency","Frequency",1e3),le(-40,40,0),De(1)],web:"biquad-peaking"},{id:"lowshelf",label:"Low Shelf",group:"filter",description:"Lift or drop everything below the corner frequency.",params:[z("frequency","Frequency",200,20,2e3),le(-40,40,0)],web:"biquad-lowshelf"},{id:"highshelf",label:"High Shelf",group:"filter",description:"Lift or drop everything above the corner frequency.",params:[z("frequency","Frequency",4e3,500,2e4),le(-40,40,0)],web:"biquad-highshelf"},{id:"highpass",label:"High-pass",group:"filter",description:"Remove low frequencies \u2014 the usual fix for rumble on a voice.",params:[z("frequency","Cutoff",300,20,2e4),De(.707),Ft],web:"biquad-highpass"},{id:"lowpass",label:"Low-pass",group:"filter",description:"Remove high frequencies \u2014 darkens or muffles a track.",params:[z("frequency","Cutoff",8e3,100,2e4),De(.707),Ft],web:"biquad-lowpass"},{id:"compressor",label:"Compressor",group:"dynamics",description:"Pull loud parts down so the quiet ones can come up.",params:[{kind:"number",key:"threshold",label:"Threshold",unit:"dB",min:-60,max:0,step:.5,default:-24,hint:"Level above which the compressor starts working."},{kind:"number",key:"ratio",label:"Ratio",unit:":1",min:1,max:20,step:.1,default:4},{kind:"number",key:"attack",label:"Attack",unit:"ms",min:.01,max:2e3,step:.1,default:20,scale:"log"},{kind:"number",key:"release",label:"Release",unit:"ms",min:.01,max:9e3,step:1,default:250,scale:"log"},{kind:"number",key:"knee",label:"Knee",unit:"",min:1,max:8,step:.01,default:2.83,hint:"1 is a hard corner; higher eases into it."},{kind:"number",key:"makeup",label:"Makeup",unit:"dB",min:0,max:36,step:.1,default:0},{kind:"number",key:"mix",label:"Mix",unit:"",min:0,max:1,step:.01,default:1,hint:"Below 1 blends the dry signal back in."}],web:"worklet-compressor"},{id:"limiter",label:"Limiter",group:"dynamics",description:"Hard ceiling \u2014 nothing gets past the limit.",params:[{kind:"number",key:"limit",label:"Ceiling",unit:"dB",min:-24,max:0,step:.1,default:-1},{kind:"number",key:"attack",label:"Attack",unit:"ms",min:.1,max:80,step:.1,default:5},{kind:"number",key:"release",label:"Release",unit:"ms",min:1,max:8e3,step:1,default:50,scale:"log"},{kind:"number",key:"level_out",label:"Output",unit:"dB",min:-24,max:24,step:.1,default:0}],web:"worklet-limiter"},{id:"gate",label:"Noise Gate",group:"dynamics",description:"Silence the track when it drops below the threshold.",params:[{kind:"number",key:"threshold",label:"Threshold",unit:"dB",min:-80,max:0,step:.5,default:-35},{kind:"number",key:"range",label:"Range",unit:"dB",min:-80,max:0,step:.5,default:-24,hint:"How far down the gate pulls when closed."},{kind:"number",key:"ratio",label:"Ratio",unit:":1",min:1,max:20,step:.1,default:10},{kind:"number",key:"attack",label:"Attack",unit:"ms",min:.01,max:9e3,step:.1,default:1,scale:"log"},{kind:"number",key:"release",label:"Release",unit:"ms",min:.01,max:9e3,step:1,default:100,scale:"log"},{kind:"number",key:"knee",label:"Knee",unit:"",min:1,max:8,step:.01,default:2.83}],web:"worklet-gate"},{id:"saturate",label:"Saturation",group:"nonlinear",description:"Soft-clip the waveform for warmth or outright distortion.",params:[{kind:"enum",key:"type",label:"Curve",options:[{value:"tanh",label:"Tanh"},{value:"atan",label:"Arctan"},{value:"cubic",label:"Cubic"},{value:"exp",label:"Exponential"},{value:"alg",label:"Algebraic"},{value:"quintic",label:"Quintic"},{value:"sin",label:"Sine"},{value:"erf",label:"Error function"},{value:"hard",label:"Hard clip"}],default:"tanh"},{kind:"number",key:"threshold",label:"Threshold",unit:"dB",min:-40,max:0,step:.1,default:-6},{kind:"number",key:"output",automatable:!0,label:"Output",unit:"dB",min:-24,max:24,step:.1,default:0},{kind:"number",key:"oversample",label:"Oversample",unit:"x",min:1,max:8,step:1,default:4,hint:"Higher costs more but keeps aliasing down."}],web:"waveshaper"},{id:"bitcrush",label:"Bitcrush",group:"nonlinear",description:"Drop bit depth and sample rate for a lo-fi, digital sound.",params:[{kind:"number",key:"bits",label:"Bit depth",unit:"bit",min:1,max:32,step:.1,default:8},{kind:"number",key:"samples",label:"Sample hold",unit:"x",min:1,max:250,step:1,default:1,hint:"Repeats each sample N times \u2014 a crude downsample."},{kind:"number",key:"mix",label:"Mix",unit:"",min:0,max:1,step:.01,default:1}],web:"worklet-bitcrush"},{id:"pitchshift",label:"Pitch shift",group:"time",description:"Shifts pitch up or down without changing playback speed. Adds ~50 ms of latency.",params:[{kind:"number",key:"semitones",label:"Semitones",unit:"st",min:-12,max:12,step:1,default:0},{kind:"number",key:"mix",label:"Mix",unit:"",min:0,max:1,step:.01,default:1}],web:"worklet-pitchshift"},{id:"delay",label:"Delay",group:"time",description:"Repeating echoes behind the dry signal.",params:[{kind:"number",key:"time",automatable:!0,label:"Time",unit:"ms",min:1,max:5e3,step:1,default:250,scale:"log"},{kind:"number",key:"feedback",automatable:!0,label:"Feedback",unit:"",min:.01,max:.95,step:.01,default:.35},{kind:"number",key:"mix",automatable:!0,label:"Mix",unit:"",min:0,max:1,step:.01,default:.4}],web:"delay-feedback"},{id:"chorus",label:"Chorus",group:"time",description:"Detuned copies of the signal for width and thickness.",params:[{kind:"number",key:"delay",automatable:!0,label:"Delay",unit:"ms",min:1,max:100,step:.1,default:7},{kind:"number",key:"depth",automatable:!0,label:"Depth",unit:"ms",min:0,max:10,step:.01,default:2},{kind:"number",key:"speed",automatable:!0,label:"Rate",unit:"Hz",min:.01,max:10,step:.01,default:1},{kind:"number",key:"mix",automatable:!0,label:"Mix",unit:"",min:0,max:1,step:.01,default:.5}],web:"chorus-lfo"},{id:"phaser",label:"Phaser",group:"time",description:"Sweeping notches moving through the spectrum.",params:[{kind:"number",key:"in_gain",automatable:!0,label:"Input",unit:"",min:0,max:1,step:.01,default:.4},{kind:"number",key:"out_gain",automatable:!0,label:"Output",unit:"",min:0,max:2,step:.01,default:.74},{kind:"number",key:"delay",label:"Delay",unit:"ms",min:.1,max:5,step:.1,default:3},{kind:"number",key:"decay",label:"Decay",unit:"",min:0,max:.99,step:.01,default:.4},{kind:"number",key:"speed",automatable:!0,label:"Rate",unit:"Hz",min:.1,max:2,step:.01,default:.5},{kind:"enum",key:"type",label:"Waveform",options:[{value:"0",label:"Triangular"},{value:"1",label:"Sinusoidal"}],default:"0"}],web:"allpass-phaser"},{id:"reverb",label:"Reverb",group:"time",description:"Room tail. Both ends convolve the same generated impulse, so preview matches render.",params:[{kind:"number",key:"size",label:"Room size",unit:"",min:.05,max:1,step:.01,default:.7},{kind:"number",key:"damping",label:"Damping",unit:"",min:0,max:1,step:.01,default:.5,hint:"Higher rolls the top off the tail faster."},{kind:"number",key:"wet",automatable:!0,label:"Wet",unit:"",min:0,max:1,step:.01,default:.35},{kind:"number",key:"dry",automatable:!0,label:"Dry",unit:"",min:0,max:1,step:.01,default:.7}],web:"convolver"}],Tr=new Map(Ut.map(n=>[n.id,n]));var xr=Ut.map(n=>n.id);function wn(n){return 10**(n/20)}var Ht=wn(12);var Le="data-automation",Lr=Le.slice(5),Ne=1,Rn=512,k=class extends Error{constructor(e){super(e),this.name="AudioAutomationError"}},de="volume",ce="rate";function Vt(n){if(n===de)return{kind:"volume"};if(n===ce)return{kind:"rate"};let e=n.split(".");if(e.length===3&&e[0]==="fx"&&e[1]===kn){let r=e[2];return r?{kind:"preset",presetId:r}:null}if(e.length!==3||e[0]!=="fx")return null;let[,t,i]=e;return!t||!i?null:{kind:"fx",nodeId:t,param:i}}var kn="preset";var Mn={min:0,max:Ht,step:.01,unit:"",label:"Volume",scale:"linear",default:1},In={min:$,max:q,step:.05,unit:"x",label:"Speed",scale:"log",default:1};function j(n){if(typeof n=="number")return Number.isFinite(n)?n:null;if(typeof n=="string"&&n.trim()!==""){let e=Number(n);return Number.isFinite(e)?e:null}return null}function Cn(n){let e=j(n);return e===null||e===0?0:Math.min(1,Math.max(-1,e))}function Gt(n,e){let t=j(n),i=j(e);if(t===null||i===null)return null;let r=s=>Math.min(.999,Math.max(.001,s)),o=r(t),a=r(i);return Math.abs(o-a)<1e-6?null:{x:o,y:a}}function Dn(n){let e=Cn(n?.curve),t=Gt(n?.viaX,n?.viaY);return{...e?{curve:e}:{},...t?{viaX:t.x,viaY:t.y}:{}}}function Nn(n,e){let t=j(n?.t),i=j(n?.v);if(t===null||i===null)return null;let r=e?Math.min(e.max,Math.max(e.min,i)):i;return{t:Math.max(0,t),v:r,...Dn(n)}}function Ln(n,e){let t=n.map(r=>Nn(r,e)).filter(r=>r!==null).sort((r,o)=>r.t-o.t),i=[];for(let r of t)i.length>0&&i[i.length-1].t===r.t?i[i.length-1]=r:i.push(r);return i.slice(0,Rn)}function Pn(n){let e=[];for(let t of n.lanes){if(!Vt(t.target))continue;let i=t.target===de?Mn:t.target===ce?In:null,r=Ln(t.points??[],i);r.length>0&&e.push({target:t.target,points:r})}return{version:Ne,lanes:e}}function Bt(n){let e;try{e=JSON.parse(n)}catch(r){throw new k(`Automation is not valid JSON: ${r.message}`)}if(typeof e!="object"||e===null)throw new k("Automation must be a JSON object.");let t=e;if(t.version!==Ne)throw new k(`Unsupported automation version: ${String(t.version)}`);if(!Array.isArray(t.lanes))throw new k("Automation is missing a `lanes` array.");let i=t.lanes.map((r,o)=>{if(typeof r!="object"||r===null)throw new k(`Lane ${o} is not an object.`);let a=r;if(typeof a.target!="string"||!Vt(a.target))throw new k(`Lane ${o} has an unreadable target: ${String(a.target)}`);if(!Array.isArray(a.points))throw new k(`Lane ${o} is missing a \`points\` array.`);return{target:a.target,points:a.points}});return Pn({version:Ne,lanes:i})}function Fn(n,e){return e?Math.pow(n,Math.pow(2,2*e)):n}function On(n,e){let t=n-.5,i=e-.5,r=.999,o=1e6,a=t>0?t/(r-n):t<0?-t/(n-(1-r)):0,s=i>0?i/(r-e):i<0?-i/(e-(1-r)):0,u=Math.min(o,Math.max(1,a,s));return{cx:n+t/u,cy:e+i/u,w:u}}function Un(n,e,t){let{cx:i,cy:r,w:o}=On(e,t),a=2-2*o,s=n*a-1+2*o*i,u=-n*a-2*o*i,d=Hn(s,u,n),c=1-d,g=c*c+2*o*d*c+d*d;return g>0?(2*o*r*d*c+d*d)/g:n}function Hn(n,e,t){if(Math.abs(n)<1e-12)return Math.abs(e)<1e-12?t:-t/e;let i=Math.sqrt(Math.max(0,e*e-4*n*t)),r=(-e+i)/(2*n),o=(-e-i)/(2*n),a=s=>s>=-1e-9&&s<=1+1e-9;return a(r)?Math.min(1,Math.max(0,r)):a(o)?Math.min(1,Math.max(0,o)):t}function Vn(n,e){let t=Gt(e.viaX,e.viaY);return t?Un(Math.min(1,Math.max(0,n)),t.x,t.y):Fn(n,e.curve)}function Gn(n,e,t,i){return i==="log"&&n>0&&e>0?Math.exp(Math.log(n)+(Math.log(e)-Math.log(n))*t):n+(e-n)*t}function me(n,e,t="linear"){let i=n.points;if(i.length===0)return 0;let r=i[0];if(e<=r.t)return r.v;let o=i[i.length-1];if(e>=o.t)return o.v;let a=0,s=i.length-1;for(;s-a>1;){let g=a+s>>1;i[g].t<=e?a=g:s=g}let u=i[a],d=i[s],c=d.t-u.t;return c<=0?d.v:Gn(u.v,d.v,Vn((e-u.t)/c,u),t)}var pe=new Map,Bn=64;function Wt(n,e=de){let t=`${e}\0${n}`,i=pe.get(t);if(i!==void 0)return i;let r=null;try{r=Bt(n).lanes.find(o=>o.target===e)??null}catch{r=null}return pe.size>Bn&&pe.clear(),pe.set(t,r),r}var $t=48,qt=new WeakMap;function Wn(n){let e=n.points,t=e[0].v,i=e[e.length-1].v,r=[0],o=[0],a=u=>{let d=r[r.length-1];if(u<=d)return;let c=me(n,d,"log");r.push(u),o.push(o[o.length-1]+(c+me(n,u,"log"))/2*(u-d))},s=Math.max(0,e[0].t);a(s);for(let u=1;u<e.length;u+=1){let d=e[u-1].t,c=e[u].t;if(!(c<=0))for(let g=1;g<=$t;g+=1)a(Math.max(d,0)+(c-d)*g/$t)}return{ts:Float64Array.from(r),ss:Float64Array.from(o),firstRate:t,lastRate:i}}function $n(n){let e=qt.get(n);return e||(e=Wn(n),qt.set(n,e)),e}function qn(n){return typeof n!="number"&&n.points.length>0}function zn(n,e,t){let i=0,r=n.length-1;for(;r-i>1;){let o=i+r>>1;n[o]<=t?i=o:r=o}return e[i]+(e[r]-e[i])*(t-n[i])/(n[r]-n[i])}function Pe(n,e){if(typeof n=="number")return e/n;if(!qn(n))return e;let{ts:t,ss:i,firstRate:r,lastRate:o}=$n(n),a=t.length-1;return e<=0?e/r:e>=i[a]?t[a]+(e-i[a])/o:zn(i,t,e)}function jn(n){return n?Wt(n,ce):null}function zt(n,e){return jn(n)??e}var Yn="http://www.w3.org/1999/xhtml";function jt(n){return n!=null&&n.nodeType===1}function Xn(n){return jt(n)&&n.namespaceURI===Yn}function Fe(n,e){return Xn(n)&&n.localName===e}function Kn(n){return Fe(n,"video")}function Jn(n){return Fe(n,"audio")}function C(n){return Kn(n)||Jn(n)}function Oe(n){return Fe(n,"img")}var _=Object.freeze({start:"data-start",duration:"data-duration",trackIndex:"data-track-index",derivedEnd:"data-end",legacyTrack:"data-layer"}),Wr=Object.freeze([_.start,_.duration,_.trackIndex]),$r=Object.freeze([_.derivedEnd]),qr=Object.freeze([_.derivedEnd,_.legacyTrack]);function M(n){if(n==null||n.trim()==="")return null;let e=Number(n);return Number.isFinite(e)?e:null}var Kt=/^[A-Za-z0-9_.:-]+$/;function Jt(n,e){let t=n.charCodeAt(e);return t>=48&&t<=57}function Yt(n,e){let t=e;for(;t>=0&&Jt(n,t);)t--;return t}function Zn(n,e){let t=e;for(;t>=0&&(n[t]??"").trim()==="";)t--;return t}function Qn(n){let e=n.length-1;if(!Jt(n,e))return null;let t=Yt(n,e);return n[t]==="."&&(t=Yt(n,t-1)),t+1}function ei(n){let e=Qn(n);if(e==null)return null;let t=Zn(n,e-1),i=n[t];if(i!=="+"&&i!=="-")return null;let r=n.slice(0,t).trim();if(!Kt.test(r))return null;let o=Number(n.slice(e));return Number.isFinite(o)?{refId:r,operator:i,magnitude:o}:null}function fe(n){let e=(n??"").trim();if(!e)return null;let t=M(e);if(t!=null)return{kind:"absolute",value:t};if(Kt.test(e))return{kind:"reference",refId:e,offset:0};let i=ei(e);return i?{kind:"reference",refId:i.refId,offset:i.operator==="-"?-i.magnitude:i.magnitude}:null}function T(n,e,t,i){n.push({code:e,attribute:t,value:i})}function ti(n,e,t,i){if(e==null||e.trim()==="")return t.defaultStart===void 0?0:t.defaultStart;if(!n)return T(i,"invalid-start",_.start,e),null;if(n.kind==="absolute")return Math.max(0,n.value);let r=t.resolveReferenceEnd?.(n.refId);return r==null||!Number.isFinite(r)?(T(i,"unresolved-start-reference",_.start,e),null):Math.max(0,r+n.offset)}var ni=1e-9;function ii(n,e){return Math.abs(n-e)<=ni}function ri(n,e,t){let i=M(n);if(i==null){T(t,"deprecated-end",_.derivedEnd,n),T(t,"invalid-end",_.derivedEnd,n);return}if(e==null){T(t,"deprecated-end",_.derivedEnd,n);return}ii(i,e)||(T(t,"deprecated-end",_.derivedEnd,n),T(t,"conflicting-end",_.derivedEnd,n))}function oi(n,e,t){let i=M(n);return i==null||i<0?(T(t,"invalid-duration",_.duration,n),{duration:null,end:null,durationSource:"invalid"}):{duration:i,end:e==null?null:e+i,durationSource:"duration"}}function ai(n,e,t){T(t,"deprecated-end",_.derivedEnd,n);let i=M(n);return i==null?(T(t,"invalid-end",_.derivedEnd,n),{duration:null,end:null,durationSource:"invalid"}):e==null?{duration:null,end:i,durationSource:"legacy-end"}:i<e?(T(t,"end-before-start",_.derivedEnd,n),{duration:null,end:null,durationSource:"invalid"}):{duration:i-e,end:i,durationSource:"legacy-end"}}function si(n,e,t){let i=n.getAttribute(_.duration),r=n.getAttribute(_.derivedEnd);if(i==null)return r==null?{duration:null,end:null,durationSource:"missing"}:ai(r,e,t);let o=oi(i,e,t);return r!=null&&ri(r,o.end,t),o}function Xt(n,e,t,i){let r=M(n);return r==null||!Number.isInteger(r)?(T(i,"invalid-track-index",e,n),{trackIndex:0,trackSource:"invalid"}):{trackIndex:r,trackSource:t}}function ui(n,e){let t=n.getAttribute(_.trackIndex),i=n.getAttribute(_.legacyTrack);if(t==null&&i==null)return{trackIndex:0,trackSource:"default"};if(t==null&&i!=null)return T(e,"deprecated-layer",_.legacyTrack,i),Xt(i,_.legacyTrack,"legacy-layer",e);let r=Xt(t??"",_.trackIndex,"track-index",e);if(i==null)return r;T(e,"deprecated-layer",_.legacyTrack,i);let o=M(i);return o!=null&&o!==r.trackIndex&&T(e,"conflicting-layer",_.legacyTrack,i),r}function Ue(n,e={}){let t=[],i=n.getAttribute(_.start),r=fe(i),o=ti(r,i,e,t),a=si(n,o,t),s=ui(n,t);return{startExpression:r,start:o,...a,...s,diagnostics:t}}function Y(n){return M(n)}function he(n){return Dt(e=>n.getAttribute(e),C(n)?n.defaultPlaybackRate:1)}function He(n){return zt(n.getAttribute("data-automation"),he(n))}function Zt(n){return Ct(e=>n.getAttribute(e))}function X(n,e){return li(e,Zt(n),He(n))}function be(n,e=0){return!Oe(n)||!n.hasAttribute("data-start")&&!n.hasAttribute("data-track-index")?null:Pt({tag:"img",authoredDurationSeconds:Lt(t=>n.getAttribute(t),e),sourceDurationSeconds:null,mediaStartSeconds:0,playbackRate:1}).seconds}function li(n,e,t){return typeof t=="number"?Ce(n,e,t):Number.isFinite(n)?Pe(t,Math.max(0,n-e)):null}var Qt="data-hf-media-start-basis";function di(n){return n?.trim().toLowerCase()==="global"?"global":"local"}function ci(n){return di(n.basis)==="global"?n.authoredStart:n.hostStart+n.authoredStart}function en(n){return n.hasAutoStart||n.authoredStart==null||n.hostStart<=0?n.ordinaryStart():ci({authoredStart:n.authoredStart,hostStart:n.hostStart,basis:n.basis})}function ge(n){let e=n.timelineRegistry??{},t=n.includeAuthoredTimingAttrs??!1,i=n.documentRef??document,r=new WeakMap,o=new WeakMap,a=new Set,s=m=>{let f=i.getElementById(m);return f||(i.querySelector(`[data-composition-id="${CSS.escape(m)}"]`)??null)},u=m=>{let f=o.get(m);if(f!==void 0)return f;let h=null,b=ue({start:0,duration:m.getAttribute("data-duration"),authoredDuration:t?m.getAttribute("data-hf-authored-duration"):null});if(b?.duration!=null&&b.duration>0&&(h=b.duration),h==null||h<=0){let y=c(m,0),S=ue({start:y,end:m.getAttribute("data-end"),authoredEnd:t?m.getAttribute("data-hf-authored-end"):null});S?.duration!=null&&S.duration>0&&(h=S.duration)}if((h==null||h<=0)&&C(m)&&(h=X(m,m.duration)),(h==null||h<=0)&&(h=be(m)),h==null||h<=0){let y=m.getAttribute("data-composition-id");if(y){let S=e[y]??null;if(S&&typeof S.duration=="function")try{let v=Number(S.duration());Number.isFinite(v)&&v>0&&(h=v)}catch(v){B("runtime.startResolver.site1",v)}}}return h!=null&&Number.isFinite(h)&&h>0?(o.set(m,h),h):(o.set(m,null),null)},d=(m,f)=>{if(m.hasAttribute("data-composition-id")){let b=m.parentElement?.closest("[data-composition-id]");return b?c(b,f):0}let h=m.closest("[data-composition-id]");return h?c(h,f):0},c=(m,f)=>{let h=r.get(m);if(h!==void 0)return h??f;if(a.has(m))return f;a.add(m);try{let b=fe(m.getAttribute("data-start"));if(!b){if(m.hasAttribute("data-composition-id")){let A=m.parentElement;if(A&&(A.hasAttribute("data-composition-src")||A.hasAttribute("data-composition-id")||A.hasAttribute("data-composition-file"))){let R=c(A,f);return r.set(m,R),R}}return r.set(m,f),f}if(b.kind==="absolute"){let A=Math.max(0,b.value),R=Math.max(0,d(m,f)+A);return r.set(m,R),R}let y=s(b.refId);if(!y)return r.set(m,f),f;let S=c(y,0),v=u(y);if(v==null||v<=0){let A=Math.max(0,S+b.offset);return r.set(m,A),A}let w=Math.max(0,S+v+b.offset);return r.set(m,w),w}finally{a.delete(m)}};return{resolveStartForElement:(m,f=0)=>c(m,Math.max(0,f)),resolveDurationForElement:m=>u(m),resolveMediaStartForElement:m=>{let f=m.closest("[data-composition-id]"),h=f?c(f,0):0;return en({authoredStart:Y(m.getAttribute("data-start")),hostStart:h,hasAutoStart:m.hasAttribute("data-hf-auto-start"),basis:m.getAttribute(Qt),ordinaryStart:()=>c(m,h)})}}}var _e=(n,e,t)=>n>=e&&n<t;var Ve=(n,e,t,i)=>_e(n,e,t)||n>=e&&i>0&&t>=i-1e-6;var pi="data-fade-in",fi="data-fade-out",yo=pi.slice(5),vo=fi.slice(5),hi=Object.freeze({fadeIn:0,fadeOut:0});var gi=["backdrop-filter","clip-path","filter","mask","mask-border-source","mask-image","perspective","rotate","scale","transform","translate","-webkit-mask-image"],ta=new Set([...gi,"contain","isolation","mask-border","mix-blend-mode","opacity"]);function _i(n){return Number.isFinite(n)&&n>0?n:30}function yi(n){return Number.isFinite(n)&&n>0?n:0}function Ge(n,e){let t=_i(e),i=yi(n),r=i*t,o=Math.round(r);return Math.abs(r-o)<=.001?o/t:i}var vi=["seconds-time","rational-fps","seek-keep-playing","composition-manifest-v1","runtime-data"];function Ai(n,e){let t=Math.abs(n),i=Math.abs(e);for(;i!==0;){let r=t%i;t=i,i=r}return t||1}function Ei(n){let e=Number.isFinite(n)&&n>0?n:30,t=Number.isInteger(e)?1:1e6,i=Math.round(e*t),r=Ai(i,t);return{numerator:i/r,denominator:t/r}}function Si(n){if(typeof n!="object"||n===null)return null;let e=n;return!Number.isFinite(e.numerator)||!Number.isFinite(e.denominator)||(e.numerator??0)<=0||(e.denominator??0)<=0?null:Number(e.numerator)/Number(e.denominator)}function Be(n){return{protocolVersion:1,capabilities:vi,fps:Ei(n)}}function Ti(n){return Array.isArray(n)&&n.every(e=>typeof e=="string")}function tn(n,e=30){if(typeof n!="object"||n===null)return{status:"legacy",fps:e};let t=n;if(t.protocolVersion===void 0)return{status:"legacy",fps:e};if(t.protocolVersion!==1)return{status:"unsupported",code:"unsupported_protocol_version",receivedVersion:t.protocolVersion};let i=Si(t.fps);return i===null||!Ti(t.capabilities)?{status:"unsupported",code:"invalid_protocol_metadata",receivedVersion:t.protocolVersion}:{status:"supported",fps:i,metadata:t}}function nn(n,e){let t=n.tagName.toLowerCase();if(t==="script"||t==="style"||t==="link"||t==="meta")return!1;let r=t==="video"||t==="audio"?e.resolver.resolveMediaStartForElement(n):e.resolver.resolveStartForElement(n,0),o=e.resolver.resolveDurationForElement(n),a=n.getAttribute("data-composition-id");if(a){let c=e.timelineRegistry[a],g=c&&typeof c.duration=="function"?Number(c.duration()):null;!(n.hasAttribute("data-duration")||n.hasAttribute("data-end")||n.hasAttribute(kt)||n.hasAttribute(Mt))&&(o==null||o<=0)&&g!=null&&Number.isFinite(g)&&g>0&&(o=g)}let s=o!=null&&o>0?r+o:Number.POSITIVE_INFINITY,u=e.exportRenderSeek?Ge(r,e.canonicalFps):r,d=e.exportRenderSeek&&Number.isFinite(s)?Ge(s,e.canonicalFps):s;return Ve(e.currentTime,u,d,e.compositionDuration)}var $e="first-frame",xi=3;function K(n){let e=n.ownerDocument?.defaultView;return e&&n instanceof e.Element?!0:n instanceof Element}function x(n){if(!K(n)||n.tagName!=="AUDIO"&&n.tagName!=="VIDEO")return!1;let e=n.ownerDocument?.defaultView;return e&&n instanceof e.HTMLMediaElement?!0:n instanceof HTMLMediaElement}function wi(n){return n.hasAttribute("data-start")||n.hasAttribute("data-track-index")}function Ri(n,e,t){let i=n;for(;i;){if(wi(i)&&!nn(i,{currentTime:0,compositionDuration:Number.POSITIVE_INFINITY,canonicalFps:30,exportRenderSeek:!1,timelineRegistry:t,resolver:e}))return!1;i=i.parentElement}return!0}function rn(n,e,t,i){return e==="all"?!0:Ri(n,t,i)}function qe(n,{scope:e="all"}={}){let t=n.defaultView,i=ge({documentRef:n,timelineRegistry:t?.__timelines,includeAuthoredTimingAttrs:!0}),r=Array.from(n.querySelectorAll("video, audio")).filter(x).filter(s=>rn(s,e,i,t?.__timelines??{})).filter(s=>s.readyState<xi),o=Array.from(n.querySelectorAll("img")).filter(s=>rn(s,e,i,t?.__timelines??{})).filter(s=>!s.complete),a=n.fonts?.status==="loading";return{pendingMedia:r,pendingImages:o,fontsLoading:a}}function ki(n,{pendingMedia:e,pendingImages:t,fontsLoading:i},r){let o=e.map(u=>new Promise(d=>{if(u.error){d();return}let c=()=>{u.removeEventListener("canplay",c),u.removeEventListener("error",c),r.removeEventListener("abort",c),d()};u.addEventListener("canplay",c),u.addEventListener("error",c),r.addEventListener("abort",c,{once:!0})})),a=t.map(u=>u.decode?u.decode().catch(()=>{}):Promise.resolve()),s=i&&n.fonts?n.fonts.ready.then(()=>{}):Promise.resolve();return Promise.all([...o,...a,s]).then(()=>{})}function Mi(n,e,{scope:t="all"}={}){let i=qe(n,{scope:t});return i.pendingMedia.length===0&&i.pendingImages.length===0&&!i.fontsLoading?null:ki(n,i,e)}var Ii=50;function Ci(n,e){let t=n.defaultView;return!t||t.__renderReady||!t.__hf?null:new Promise(i=>{let r,o=()=>{r!==void 0&&clearTimeout(r),e.removeEventListener("abort",o),i()};if(e.aborted){o();return}e.addEventListener("abort",o,{once:!0});let a=()=>{if(t.__renderReady){o();return}r=setTimeout(a,Ii)};a()})}var Di=50,Ni=2,Li=1500;function We(n,e){return new Promise(t=>{if(e.aborted){t(-1);return}let i=0,r=()=>{n.cancelAnimationFrame?.(i),t(-1)};e.addEventListener("abort",r,{once:!0}),i=n.requestAnimationFrame(o=>{e.removeEventListener("abort",r),t(o)})})}function Pi(n,e){let t=n.defaultView;return t?(async()=>{let i=await We(t,e);if(e.aborted)return;let r=await We(t,e),o=0;for(;!e.aborted&&o<Ni;){if(r-i>=Li)return;let a=await We(t,e);if(e.aborted)return;o=a-r<Di?o+1:0,r=a}})():null}var Fi=8e3;function Oi(n,e,t={}){let i=t.inputs??[(d,c)=>Mi(d,c,{scope:t.scope}),Ci,Pi],r=new AbortController,o=i.map(d=>d(n,r.signal)).filter(d=>d!==null);if(o.length===0){e({timedOut:!1});return}let a=t.timeoutMs??Fi,s,u=new Promise(d=>{s=setTimeout(()=>d("timed-out"),a)});Promise.race([Promise.all(o).then(()=>"done"),u]).then(d=>{clearTimeout(s),r.abort(),e({timedOut:d==="timed-out"})})}function on(n,e,t={}){Oi(n,e,{...t,scope:$e})}var Ui=.05,Hi=2,ye=class{_entries=[];_mediaObserver;_playbackErrorPosted=!1;_audioOwner="runtime";_urlAudioEntry=null;_urlAudioSrc=null;_dispatchEvent;_getMuted;_getVolume;_getPlaybackRate;_getCurrentTime;_isPaused;constructor(e){this._dispatchEvent=e.dispatchEvent,this._getMuted=e.getMuted,this._getVolume=e.getVolume,this._getPlaybackRate=e.getPlaybackRate,this._getCurrentTime=e.getCurrentTime,this._isPaused=e.isPaused}get audioOwner(){return this._audioOwner}get entries(){return this._entries}resetForIframeLoad(){this._playbackErrorPosted=!1;let e=this._audioOwner==="parent";this._audioOwner="runtime",this.pauseAll(),this.teardownObserver(),e&&this._dispatchEvent(new CustomEvent("audioownershipchange",{detail:{owner:"runtime",reason:"iframe-reload"}}))}destroy(){this.teardownObserver();for(let e of this._entries)e.el.pause(),e.el.src="";this._entries=[],this._urlAudioEntry=null,this._urlAudioSrc=null,this._audioOwner="runtime",this._playbackErrorPosted=!1}updateMuted(e){for(let t of this._entries)t.el.muted=e}updateVolume(e){for(let t of this._entries)t.el.volume=e}updatePlaybackRate(e){for(let t of this._entries)t.el.playbackRate=e}_playEntry(e){e.el.src&&e.el.play().catch(t=>this._reportPlaybackError(t))}_playEntryIfActive(e){this._refreshEntryBounds(e),this._inWindow(e,this._getCurrentTime())&&this._playEntry(e)}_refreshEntryBounds(e){if(!e.source?.isConnected)return;let t=Ue(e.source);e.start=t.start??0,e.duration=t.duration!=null&&t.duration>0?t.duration:Number.POSITIVE_INFINITY}_inWindow(e,t){return _e(t,e.start,e.start+e.duration)}_gateEntryPlayback(e,t){return this._inWindow(e,t)?(this._audioOwner==="parent"&&!this._isPaused()&&e.el.paused&&this._playEntry(e),!0):(e.el.paused||e.el.pause(),e.driftSamples=0,!1)}playAll(){for(let e of this._entries)this._playEntryIfActive(e)}pauseAll(){for(let e of this._entries)e.el.pause()}stopAdoptedMedia(){for(let e of this._entries)e.source&&e.el.pause()}seekAll(e){for(let t of this._entries)this._refreshEntryBounds(t),this._inWindow(t,e)&&(t.el.currentTime=e-t.start)}scrubAll(e){for(let t of this._entries)this._refreshEntryBounds(t),this._inWindow(t,e)?(t.el.currentTime=e-t.start,this._playEntry(t)):t.el.paused||t.el.pause()}mirrorTime(e,t){let i=t?.force===!0;for(let r of this._entries){if(this._refreshEntryBounds(r),!this._gateEntryPlayback(r,e))continue;let o=e-r.start;Math.abs(r.el.currentTime-o)>Ui?(r.driftSamples+=1,(i||r.driftSamples>=Hi)&&(r.el.currentTime=o,r.driftSamples=0)):r.driftSamples=0}}promoteToParentProxy(e,t){if(this._audioOwner==="parent")return;if(this._audioOwner="parent",e)for(let r of e.querySelectorAll("video, audio"))x(r)&&(r.muted=!0);let i=this._getCurrentTime();t?t(i,{force:!0}):this.mirrorTime(i,{force:!0}),this._isPaused()||this.playAll(),this._dispatchEvent(new CustomEvent("audioownershipchange",{detail:{owner:"parent",reason:"autoplay-blocked"}}))}setupFromIframe(e){let t=e.querySelectorAll("audio[data-start], video[data-start]");for(let i of t)x(i)&&this._adoptIframeMedia(i);this._observeDynamicMedia(e)}setupFromUrl(e){if(this._urlAudioSrc===e&&this._urlAudioEntry)return;this.teardownUrlAudio();let t=this._createEntry(e,"audio",0,1/0);this._urlAudioEntry=t,this._urlAudioSrc=t?e:null,t&&this._audioOwner==="parent"&&!this._isPaused()&&(this.mirrorTime(this._getCurrentTime(),{force:!0}),this.playAll())}teardownUrlAudio(){let e=this._urlAudioEntry;if(this._urlAudioEntry=null,this._urlAudioSrc=null,!e)return;e.el.pause(),e.el.src="";let t=this._entries.indexOf(e);t!==-1&&this._entries.splice(t,1)}teardownObserver(){this._mediaObserver?.disconnect(),this._mediaObserver=void 0}_reportPlaybackError(e){this._playbackErrorPosted||(this._playbackErrorPosted=!0,this._dispatchEvent(new CustomEvent("playbackerror",{detail:{source:"parent-proxy",error:e}})))}_createEntry(e,t,i,r,o){if(this._entries.some(d=>d.el.src===e))return null;let a=t==="video"?document.createElement("video"):new Audio;a.preload="auto",a.src=e,a.load(),a.muted=this._getMuted(),a.volume=this._getVolume();let s=this._getPlaybackRate();s!==1&&(a.playbackRate=s);let u={el:a,start:i,duration:r,driftSamples:0,source:o};return this._entries.push(u),u}_resolveIframeMediaSrc(e){let t=e.getAttribute("src")||e.querySelector("source")?.getAttribute("src");return t?new URL(t,e.ownerDocument.baseURI).href:null}_adoptIframeMedia(e){if(e.preload==="metadata"||e.preload==="none")return;let t=this._resolveIframeMediaSrc(e);if(!t)return;let i=Ue(e),r=i.start??0,o=i.duration??Number.POSITIVE_INFINITY,a=e.tagName==="VIDEO"?"video":"audio",s=this._createEntry(t,a,r,o,e);s&&this._audioOwner==="parent"&&(this.mirrorTime(this._getCurrentTime(),{force:!0}),this._isPaused()||this._playEntryIfActive(s))}_detachIframeMedia(e){let t=this._resolveIframeMediaSrc(e);if(!t)return;let i=this._entries.findIndex(o=>o.el.src===t);if(i===-1)return;let r=this._entries[i];r.el.pause(),r.el.src="",this._entries.splice(i,1)}_observeDynamicMedia(e){if(this.teardownObserver(),typeof MutationObserver>"u"||!e.body)return;let t=new MutationObserver(o=>{for(let a of o){if(a.type==="attributes"&&a.attributeName==="preload"){let s=a.target;x(s)&&s.matches("audio[data-start], video[data-start]")&&s.preload==="auto"&&this._adoptIframeMedia(s);continue}for(let s of a.addedNodes){if(!K(s))continue;let u=[];x(s)&&s.matches("audio[data-start], video[data-start]")&&u.push(s);let d=s.querySelectorAll("audio[data-start], video[data-start]");for(let c of d)x(c)&&u.push(c);for(let c of u)this._adoptIframeMedia(c)}for(let s of a.removedNodes){if(!K(s))continue;let u=[];x(s)&&s.matches("audio[data-start], video[data-start]")&&u.push(s);let d=s.querySelectorAll("audio[data-start], video[data-start]");for(let c of d)x(c)&&u.push(c);for(let c of u)this._detachIframeMedia(c)}}}),i={childList:!0,subtree:!0,attributes:!0,attributeFilter:["preload"]},r=wt(e);for(let o of r)t.observe(o,i);this._mediaObserver=t}};function an(n,e,t,i){let r=(n.frame??0)/e,o=t.duration>0?Math.min(r,t.duration):r,a=!t.paused,s=!n.isPlaying,u=t.duration>0&&o>=t.duration&&(a||n.isPlaying);if(u&&i.getLoop())return i.media.audioOwner==="parent"&&i.media.pauseAll(),i.seek(0),i.play(),{...t,currentTime:o,paused:!1};let d={...t,currentTime:o,paused:s};i.media.audioOwner==="parent"&&(a&&s?i.media.pauseAll():!a&&!s&&i.media.playAll(),i.media.mirrorTime(o));let c=performance.now(),g=s!==t.paused;return(c-t.lastUpdateMs>100||g)&&(d.lastUpdateMs=c,i.updateControlsTime(o,t.duration),i.updateControlsPlaying(!s),i.dispatchEvent(new CustomEvent("timeupdate",{detail:{currentTime:o}}))),u&&(i.media.audioOwner==="parent"&&i.media.pauseAll(),d.paused=!0,i.updateControlsPlaying(!1),i.dispatchEvent(new Event("ended"))),d}function Vi(n){return Array.isArray(n)?n.filter(e=>typeof e=="object"&&e!==null&&typeof e.id=="string"&&typeof e.start=="number"&&typeof e.duration=="number"):[]}function sn(n,e,t){if(n.source!==e)return;let i=n.data;if(!i||i.source!=="hf-preview")return;let r=tn(i);if(r.status==="unsupported"){t.dispatchEvent(new CustomEvent("runtimeprotocolerror",{detail:{code:r.code,receivedVersion:r.receivedVersion}}));return}if(t.setRuntimeFps?.(r.fps),i.type==="shader-transition-state"){let o=i.state&&typeof i.state=="object"?i.state:{};t.shaderLoader.update(o,t.getShaderLoadingMode()),t.dispatchEvent(new CustomEvent("shadertransitionstate",{detail:{compositionId:i.compositionId,state:o}}));return}if(i.type==="ready"){t.onRuntimeReady();return}if(i.type==="assets-ready"){t.onRuntimeAssetsReady?.(i.timedOut===!0);return}if(i.type==="runtime-data-error"){t.onRuntimeDataError?.(i.channel,i.requestId,i.message);return}if(i.type==="runtime-data-applied"){t.onRuntimeDataApplied?.(i.channel,i.requestId);return}if(i.type==="state"){t.setPlaybackState(an({frame:i.frame??0,isPlaying:!!i.isPlaying},r.fps,t.getPlaybackState(),t));return}if(i.type==="media-autoplay-blocked"){if(t.shouldPromoteMediaAutoplayFallback?.()===!1)return;let o=null;try{o=t.getIframeDoc()}catch{}t.media.promoteToParentProxy(o,(a,s)=>t.media.mirrorTime(a,s)),t.sendControl("set-media-output-muted",{muted:!0});return}if(i.type==="timeline"&&i.durationInFrames>0){let o=Number(i.durationSeconds),a=Number(i.durationInFrames),s=Number.isFinite(o)&&o>0?o:a/r.fps;if(Number.isFinite(s)&&s>0){let u=t.getPlaybackState();t.setPlaybackState({...u,duration:s}),t.updateControlsTime(u.currentTime,s),t.onRuntimeTimelineReady(s,typeof i.assetsReady=="boolean"?i.assetsReady:void 0)}Number.isFinite(i.compositionWidth)&&i.compositionWidth>0&&Number.isFinite(i.compositionHeight)&&i.compositionHeight>0&&t.setCompositionSize(i.compositionWidth,i.compositionHeight),t.setScenes(Vi(i.scenes));return}i.type==="stage-size"&&Number.isFinite(i.width)&&i.width>0&&Number.isFinite(i.height)&&i.height>0&&t.setCompositionSize(i.width,i.height)}function Gi(n,e){return n.includes(e)?!0:/hyperframe\.runtime\.iife\.js|__hyperframes\s*=/.test(n)}var Bi=new Set([">"," ","	",`
`,"\r","\f"]);function ze(n,e){let t=n.toLowerCase(),i=`<${e}`,r=0;for(;r<t.length;){let o=t.indexOf(i,r);if(o<0)return null;let a=t[o+i.length];if(Bi.has(a)){let s=t.indexOf(">",o+i.length);return s<0?null:{index:o,end:s+1}}r=o+i.length}return null}function un(n,e){if(!n||Gi(n,e))return n;let t=`<script src="${e}"></script>`,i=ze(n,"head");if(i)return n.slice(0,i.end)+t+n.slice(i.end);let r=ze(n,"body");if(r)return n.slice(0,r.index)+t+n.slice(r.index);let o=ze(n,"html");return o?n.slice(0,o.end)+t+n.slice(o.end):t+n}var D="shader-capture-scale",F="shader-loading",ve="runtime-src",ln="__hf_shader_capture_scale",dn="__hf_shader_loading",O=["Preparing scene transitions","Sampling outgoing scene motion","Sampling incoming scene motion","Caching transition frames","Finalizing transition preview"];function je(n){if(n===null)return null;let e=Number(n);return!Number.isFinite(e)||e<=0?null:String(Math.min(1,Math.max(.25,e)))}function Wi(n){if(n===null||n.trim()==="")return"composition";let e=n.trim().toLowerCase();return e==="none"||e==="false"||e==="0"||e==="off"?"none":e==="player"||e==="true"||e==="1"||e==="on"?"player":"composition"}function cn(n,e){return n.filter(t=>t!==""&&t.split("=")[0]!==e)}function $i(n,e,t){let i=n.indexOf("#"),r=i>=0?n.slice(0,i):n,o=i>=0?n.slice(i):"",a=r.indexOf("?"),s=a>=0?r.slice(0,a):r,u=a>=0?r.slice(a+1):"",d=cn(u.split("&"),ln);d=cn(d,dn),e!==null&&d.push(`${ln}=${encodeURIComponent(e)}`),t!=="composition"&&d.push(`${dn}=${encodeURIComponent(t)}`);let c=d.join("&");return`${s}${c?`?${c}`:""}${o}`}function qi(n,e,t){if(e===null&&t==="composition")return n;let i=[];e!==null&&i.push(`window.__HF_SHADER_CAPTURE_SCALE=${JSON.stringify(e)};`),t!=="composition"&&i.push(`window.__HF_SHADER_LOADING=${JSON.stringify(t)};`);let r=`<script data-hyperframes-player-shader-options>${i.join("")}</script>`;return/<head\b[^>]*>/i.test(n)?n.replace(/<head\b[^>]*>/i,o=>`${o}${r}`):/<html\b[^>]*>/i.test(n)?n.replace(/<html\b[^>]*>/i,o=>`${o}${r}`):`${r}${n}`}function U(n){return Wi(n.getAttribute(F))}function mn(n){return Number(je(n.getAttribute(D))??"1")}function J(n,e){return $i(e,je(n.getAttribute(D)),U(n))}function Z(n,e){return un(qi(e,je(n.getAttribute(D)),U(n)),zi(n))}function zi(n){let e=n.getAttribute(ve)?.trim();if(!e)return L;try{let t=new URL(e,document.baseURI),i=t.protocol==="http:"||t.protocol==="https:",r=t.hostname==="127.0.0.1"||t.hostname==="localhost"||t.hostname==="[::1]";return i&&(r||t.origin===location.origin)?t.href:L}catch{return L}}function pn(){let n=document.createElement("div");n.className="hfp-shader-loader",n.setAttribute("role","status"),n.setAttribute("aria-live","polite"),n.setAttribute("aria-label","Preparing scene transitions"),n.setAttribute("data-hyperframes-ignore",""),n.draggable=!1;let e=f=>{f.preventDefault(),f.stopPropagation()};for(let f of["selectstart","dragstart","pointerdown","mousedown","click","dblclick","contextmenu","touchstart"])n.addEventListener(f,e,{capture:!0});let t=document.createElement("div");t.className="hfp-shader-loader-panel",t.draggable=!1;let i=document.createElement("div");i.className="hfp-shader-loader-mark",i.draggable=!1,i.innerHTML=['<svg width="78" height="78" viewBox="0 0 100 100" fill="none" aria-hidden="true" draggable="false">','<path d="M10.1851 57.8021L33.1145 73.8313C36.2202 75.9978 41.5173 73.5433 42.4816 69.4984L51.7611 30.4271C52.7253 26.3822 48.5802 23.9277 44.4602 26.0942L13.917 42.1235C6.96677 45.7676 4.97564 54.1579 10.1851 57.8021Z" fill="url(#hfp-shader-loader-grad-left)"/>','<path d="M87.5129 57.5141L56.9696 73.5433C52.8371 75.7098 48.7046 73.2553 49.6688 69.2104L58.9483 30.1391C59.9125 26.0942 65.2097 23.6397 68.3154 25.8062L91.2447 41.8354C96.4668 45.4796 94.4631 53.8699 87.5129 57.5141Z" fill="url(#hfp-shader-loader-grad-right)"/>',"<defs>",'<linearGradient id="hfp-shader-loader-grad-left" x1="48.5676" y1="25" x2="44.7804" y2="71.9384" gradientUnits="userSpaceOnUse">','<stop stop-color="#06E3FA"/>','<stop offset="1" stop-color="#4FDB5E"/>',"</linearGradient>",'<linearGradient id="hfp-shader-loader-grad-right" x1="54.8282" y1="73.8392" x2="72.0989" y2="32.8932" gradientUnits="userSpaceOnUse">','<stop stop-color="#06E3FA"/>','<stop offset="1" stop-color="#4FDB5E"/>',"</linearGradient>","</defs>","</svg>"].join("");let r=document.createElement("div");r.className="hfp-shader-loader-title";let o=document.createElement("span");o.className="hfp-shader-loader-title-text",o.textContent=O[0]||"Preparing scene transitions",r.appendChild(o);let a=document.createElement("div");a.className="hfp-shader-loader-detail",a.textContent="Rendering animated scene samples for shader transitions.";let s=document.createElement("div");s.className="hfp-shader-loader-track",s.setAttribute("aria-hidden","true");let u=document.createElement("div");u.className="hfp-shader-loader-fill",s.appendChild(u);let d=document.createElement("div");d.className="hfp-shader-loader-progress";let c=f=>{let h=document.createElement("div");h.className="hfp-shader-loader-row";let b=document.createElement("span");b.className="hfp-shader-loader-label",b.textContent=f;let y=document.createElement("span");return y.className="hfp-shader-loader-value",h.appendChild(b),h.appendChild(y),d.appendChild(h),{row:h,label:b,value:y}},g=c("transition"),m=c("transition frame");return t.appendChild(i),t.appendChild(r),t.appendChild(a),t.appendChild(s),t.appendChild(d),n.appendChild(t),{root:n,fill:u,title:o,detail:a,transitionValue:g.value,transitionRow:g.row,frameLabel:m.label,frameValue:m.value,frameRow:m.row}}var ji=420;function Ae(n,e,t){e.textContent=t,n.style.visibility=t?"visible":"hidden"}var Ee=class{_el;_hideTimeout=null;_hiddenCallbacks=[];_drawingAssets=!1;constructor(e){this._el=e}show(){this._hideTimeout&&(clearTimeout(this._hideTimeout),this._hideTimeout=null),this._el.root.classList.remove("hfp-hiding"),this._el.root.classList.add("hfp-visible")}hide(){if(this._el.root.classList.contains("hfp-hiding")){this._hideTimeout||this._scheduleCleanup();return}this._el.root.classList.contains("hfp-visible")&&(this._el.root.classList.add("hfp-hiding"),this._el.root.classList.remove("hfp-visible"),this._scheduleCleanup())}whenHidden(e){let t=this._el.root.classList;t.contains("hfp-visible")||t.contains("hfp-hiding")?this._hiddenCallbacks.push(e):e()}_flushHidden(){let e=this._hiddenCallbacks;this._hiddenCallbacks=[];for(let t of e)t()}reset(){this._hideTimeout&&(clearTimeout(this._hideTimeout),this._hideTimeout=null),this._el.root.classList.remove("hfp-visible","hfp-hiding"),this._drawingAssets=!1,this._flushHidden(),this._el.fill.style.transform="scaleX(0)",Ae(this._el.transitionRow,this._el.transitionValue,""),Ae(this._el.frameRow,this._el.frameValue,"")}update(e,t){let i=t==="player"&&e.loading&&!e.ready;if(this._drawingAssets&&!i)return;if(t!=="player"){this.reset();return}if(e.ready||!e.loading){this.hide();return}this._el.root.setAttribute("aria-label","Preparing scene transitions"),this._drawingAssets=!1;let r=typeof e.progress=="number"&&Number.isFinite(e.progress)?e.progress:0,o=typeof e.total=="number"&&Number.isFinite(e.total)?e.total:0,a=o>0?Math.min(1,Math.max(0,r/o)):0,s=Math.min(O.length-1,Math.floor(a*O.length));this._el.title.textContent=O[s]||"Preparing scene transitions",this._el.detail.textContent=e.phase==="cached"?"Loading cached transition frames before playback.":e.phase==="finalizing"?"Uploading transition textures for smooth playback.":"Rendering animated scene samples for shader transitions.",this._el.fill.style.transform=`scaleX(${a})`;let u=e.currentTransition!==void 0&&e.transitionTotal!==void 0?`${e.currentTransition}/${e.transitionTotal}`:o>0?`${r}/${o}`:"",d=e.transitionFrame!==void 0&&e.transitionFrames!==void 0?`${e.transitionFrame}/${e.transitionFrames}`:"";this._el.frameLabel.textContent=e.phase==="cached"?"cached transition frames":e.phase==="finalizing"?"finalizing transition frames":"rendering transition frames",Ae(this._el.transitionRow,this._el.transitionValue,u),Ae(this._el.frameRow,this._el.frameValue,d),this._el.root.setAttribute("aria-valuenow",String(Math.round(a*100))),this.show()}showAssetsLoading(){this.reset(),this._el.title.textContent="Loading assets",this._el.detail.textContent="Waiting for images, video and fonts to finish loading.",this._el.root.setAttribute("aria-label","Loading assets"),this._drawingAssets=!0,this.show()}hideAssetsLoading(){this._drawingAssets&&this.hide()}get hideTimeout(){return this._hideTimeout}destroy(){this._hideTimeout&&(clearTimeout(this._hideTimeout),this._hideTimeout=null),this._hiddenCallbacks=[]}_scheduleCleanup(){this._hideTimeout&&clearTimeout(this._hideTimeout),this._hideTimeout=setTimeout(()=>{this._el.root.classList.remove("hfp-hiding"),this._hideTimeout=null,this._flushHidden()},ji)}};var Yi=.1,Xi=5,Ye="sandbox-origin",fn=1e4,Xe=8e3,Ke="assets-loading",Q="assets-loading-ui",Je="low-power-idle",Ki=150;function Ze(n){return!Number.isFinite(n)||n<=0?1:Math.max(Yi,Math.min(Xi,n))}var Se=class extends HTMLElement{static get observedAttributes(){return["src","srcdoc","width","height","controls","muted","audio-locked","volume","poster","playback-rate","audio-src",Ye,ve,D,F,Q,Je]}shadow;container;iframe;posterEl=null;controlsApi=null;resizeObserver;shaderLoader;probe;_ready=!1;_assetsReady=!1;_painted=!1;_pendingPlay=!1;_assetsGeneration=0;_assetsLoadingShowTimer=null;_currentTime=0;_duration=0;_paused=!0;_scrubbing=!1;_lastUpdateMs=0;_volume=1;_compositionWidth=1920;_compositionHeight=1080;_rescaleWarned=!1;_directTimelineAdapter=null;_directTimelineClock;_parentTickRaf=null;_media;_scenes=[];_runtimeFps=30;_runtimeBridgeReady=!1;_runtimeAssetsReadyGeneration=-1;_runtimeData=new Map;_runtimeDataRequestId=0;_pendingRuntimeData=new Map;constructor(){super(),this.shadow=this.attachShadow({mode:"open"}),St(this.shadow,bt),{container:this.container,iframe:this.iframe}=Tt(),this.shadow.appendChild(this.container);let e=pn();this.shadow.appendChild(e.root),this.shaderLoader=new Ee(e),this._media=new ye({dispatchEvent:t=>this.dispatchEvent(t),getMuted:()=>this.muted,getVolume:()=>this._volume,getPlaybackRate:()=>this.playbackRate,getCurrentTime:()=>this._currentTime,isPaused:()=>this._paused}),this._directTimelineClock=new se({onTimeUpdate:(t,i)=>{this._currentTime=t,this.controlsApi?.updateTime(t,i),this.dispatchEvent(new CustomEvent("timeupdate",{detail:{currentTime:t}}))},getLoop:()=>this.loop,restart:()=>{this.seek(0),this.play()},onPaused:()=>{this._media.audioOwner==="parent"&&this._media.pauseAll(),this._paused=!0,this.controlsApi?.updatePlaying(!1),this.dispatchEvent(new Event("ended"))},onEnded:()=>this.loop}),this.probe=new re(this.iframe,{onReady:t=>this._onProbeReady(t),onError:t=>this.dispatchEvent(new CustomEvent("error",{detail:{message:t}}))}),this.addEventListener("click",t=>{Et(t)||(this._paused?this.play():this.pause())}),this.resizeObserver=new ResizeObserver(()=>this._rescale()),this._onMessage=this._onMessage.bind(this),this._onIframeLoad=this._onIframeLoad.bind(this)}connectedCallback(){this._applySandboxOriginPolicy(),this.resizeObserver.observe(this),window.addEventListener("message",this._onMessage),this.iframe.addEventListener("load",this._onIframeLoad),this.hasAttribute("controls")&&this._setupControls(),this.hasAttribute("poster")&&(this.posterEl=ke(this.shadow,this.getAttribute("poster"),this.posterEl)),this.hasAttribute("audio-src")&&this._media.setupFromUrl(this.getAttribute("audio-src")),this.hasAttribute("srcdoc")&&(this.iframe.srcdoc=Z(this,this.getAttribute("srcdoc"))),this.hasAttribute("src")&&(this.iframe.src=J(this,this.getAttribute("src"))),!this.hasAttribute("audio-locked")&&this._isLockedHostEnvironment()&&this._applyAudioLock(!0)}disconnectedCallback(){this._sendControl("pause"),this._stopIframeMedia(),this.resizeObserver.disconnect(),window.removeEventListener("message",this._onMessage),this.iframe.removeEventListener("load",this._onIframeLoad),this.probe.stop(),this._directTimelineClock.stop(),this._stopParentTickClock(),this._directTimelineAdapter=null,this.shaderLoader.destroy(),this._media.destroy(),this.controlsApi?.destroy(),this.controlsApi=null,this._paused=!0,this._pendingPlay=!1,this._abandonComposition("Player disconnected before runtime data was applied")}attributeChangedCallback(e,t,i){switch(e){case"src":if(!this.isConnected)break;i&&(this._pendingPlay=!1,this._abandonComposition("Composition navigated before runtime data was applied"),this.iframe.src=J(this,i));break;case"srcdoc":if(!this.isConnected)break;this._pendingPlay=!1,this._abandonComposition("Composition navigated before runtime data was applied"),i!==null?this.iframe.srcdoc=Z(this,i):this.iframe.removeAttribute("srcdoc");break;case Ye:this._applySandboxOriginPolicy(this.isConnected&&t!==i);break;case"width":this._compositionWidth=V(i)??1920,this._rescale();break;case"height":this._compositionHeight=V(i)??1080,this._rescale();break;case"controls":i!==null?this._setupControls():(this.controlsApi?.destroy(),this.controlsApi=null);break;case"poster":this.posterEl=ke(this.shadow,i,this.posterEl);break;case"playback-rate":{let r=Ze(parseFloat(i||"1"));this._media.updatePlaybackRate(r),this._sendControl("set-playback-rate",{playbackRate:r}),this._directTimelineAdapter?.timeScale?.(r),this.controlsApi?.updateSpeed(r),this.dispatchEvent(new Event("ratechange"));break}case"muted":this._handleMutedChange(i);break;case"audio-locked":this._applyAudioLock(i!==null);break;case"volume":{let r=Math.max(0,Math.min(1,parseFloat(i||"1")));this._volume=r,this._media.updateVolume(r),this._sendControl("set-volume",{volume:r}),this.controlsApi?.updateVolume(r),this.dispatchEvent(new Event("volumechange"));break}case"audio-src":i?this._media.setupFromUrl(i):this._media.teardownUrlAudio();break;case Q:i==="none"&&this.shaderLoader.hideAssetsLoading();break;case Je:this._sendControl("set-idle-heartbeat",{slow:i!==null});break;case D:case F:case ve:if(!this.isConnected)break;this._reloadShaderOptions();break}}_applySandboxOriginPolicy(e=!1){this.hasAttribute(Ye)?this.iframe.sandbox.remove("allow-same-origin"):this.iframe.sandbox.add("allow-same-origin"),e&&this._reloadForSandboxOriginPolicy()}_reloadForSandboxOriginPolicy(){this._abandonComposition("Sandbox policy changed before runtime data was applied");let e=this.getAttribute("srcdoc");if(e!==null){this.iframe.srcdoc=Z(this,e);return}let t=this.getAttribute("src");this.iframe.src=t===null?"about:blank":J(this,t)}get iframeElement(){return this.iframe}get scenes(){return this._scenes}play(){if(this._ready&&!this._assetsReady){this._pendingPlay=!0;return}this._pendingPlay=!1,this.posterEl?.remove(),this.posterEl=null,this._duration>0&&this._currentTime>=this._duration&&this.seek(0),this._paused=!1;let e=this._tryDirectTimelinePlay(),t=!1;e||(this._sendControl("play"),this._ready&&!this._directTimelineAdapter?this._startParentTickClock():this._ready||(this._pendingPlay=!0,t=!0)),this._media.audioOwner==="parent"&&this._media.playAll(),this.controlsApi?.updatePlaying(!0),t||this.dispatchEvent(new Event("play")),e&&this._directTimelineAdapter&&this._directTimelineClock.start(this._directTimelineAdapter,()=>this._currentTime,()=>this._duration,()=>this._paused)}pause(){this._pendingPlay=!1,this._tryDirectTimelinePause()||this._sendControl("pause"),this._directTimelineClock.stop(),this._stopParentTickClock(),this._media.audioOwner==="parent"&&this._media.pauseAll(),this._paused=!0,this.controlsApi?.updatePlaying(!1),this.dispatchEvent(new Event("pause"))}stopMedia(){this._sendControl("stop-media"),this._stopIframeMedia(),this._media.stopAdoptedMedia()}seek(e){this._pendingPlay=!1,!this._trySyncSeek(e)&&!this._tryDirectTimelineSeek(e)&&this._sendControl("seek",{timeSeconds:e,frame:Math.round(e*this._runtimeFps)}),this._directTimelineClock.stop(),this._stopParentTickClock(),this._currentTime=e,this._media.audioOwner==="parent"&&(this._scrubbing?this._media.scrubAll(e):(this._media.pauseAll(),this._media.seekAll(e))),this._paused=!0,this.controlsApi?.updatePlaying(!1),this.controlsApi?.updateTime(this._currentTime,this._duration)}setColorGrading(e,t){this._sendControl("set-color-grading",{target:e,grading:t})}clearColorGrading(e){this._sendControl("set-color-grading",{target:e,grading:null})}setColorGradingCompare(e,t){this._sendControl("set-color-grading-compare",{target:e,compare:t})}clearColorGradingCompare(e){this._sendControl("set-color-grading-compare",{target:e,compare:{enabled:!1}})}setRuntimeData(e,t){if(!/^[a-z][a-z0-9-]{0,63}$/.test(e))throw new Error(`Invalid HyperFrames runtime-data channel: ${e}`);if(typeof structuredClone!="function")throw new Error("HyperFrames runtime data requires structuredClone support; refusing an unverified payload");let i=structuredClone(t);this._runtimeData.set(e,i),this._deliverRuntimeData(e,i)}clearRuntimeData(e){if(!/^[a-z][a-z0-9-]{0,63}$/.test(e))throw new Error(`Invalid HyperFrames runtime-data channel: ${e}`);this._runtimeData.delete(e),this._deliverRuntimeDataClear(e)}get currentTime(){return this._currentTime}set currentTime(e){this.seek(e)}get duration(){return this._duration}get paused(){return this._paused}get ready(){return this._ready}get assetsReady(){return this._assetsReady}get painted(){return this._painted}get playbackRate(){return Ze(parseFloat(this.getAttribute("playback-rate")||"1"))}set playbackRate(e){this.setAttribute("playback-rate",String(Ze(e)))}get shaderCaptureScale(){return mn(this)}set shaderCaptureScale(e){this.setAttribute(D,String(e))}get shaderLoading(){return U(this)}set shaderLoading(e){e==="composition"?this.removeAttribute(F):this.setAttribute(F,e)}get assetsLoadingUi(){return this.getAttribute(Q)==="none"?"none":"player"}set assetsLoadingUi(e){e==="none"?this.setAttribute(Q,"none"):this.removeAttribute(Q)}get muted(){return this.hasAttribute("muted")}set muted(e){e?this.setAttribute("muted",""):this.removeAttribute("muted")}get audioLocked(){return this.hasAttribute("audio-locked")}set audioLocked(e){e?this.setAttribute("audio-locked",""):this.removeAttribute("audio-locked")}_isLockedHostEnvironment(){if(typeof navigator>"u")return!1;let e=navigator.userAgent||"";return/\bClaude\/\d/.test(e)&&/\bElectron\b/.test(e)}_isAudioLocked(){return this.hasAttribute("audio-locked")||this._isLockedHostEnvironment()}_isSlideshowPlayer(){return this.closest("hyperframes-slideshow")!==null}_handleMutedChange(e){if(e===null&&this._isAudioLocked()){this.setAttribute("muted","");return}this._media.updateMuted(e!==null),this._setIframeMediaMuted(e!==null),this._sendControl("set-muted",{muted:e!==null}),this.controlsApi?.updateMuted(e!==null),this.dispatchEvent(new Event("volumechange"))}_applyAudioLock(e){e&&(this.muted=!0),this.controlsApi?.setVolumeControlsHidden(e)}get volume(){return this._volume}set volume(e){this.setAttribute("volume",String(Math.max(0,Math.min(1,e))))}get loop(){return this.hasAttribute("loop")}set loop(e){e?this.setAttribute("loop",""):this.removeAttribute("loop")}_sendControl(e,t={}){try{let i=this.iframe.contentWindow;return i?(i.postMessage({...t,source:"hf-parent",type:"control",action:e,...Be(this._runtimeFps)},"*"),!0):((e==="set-runtime-data"||e==="clear-runtime-data")&&this._rejectRuntimeDataDelivery(t.channel,t.requestId,"Composition iframe is unavailable"),!1)}catch(i){return(e==="set-runtime-data"||e==="clear-runtime-data")&&this._rejectRuntimeDataDelivery(t.channel,t.requestId,i instanceof Error?i.message:String(i)),!1}}_deliverRuntimeData(e,t){if(!this.isConnected||!this._runtimeBridgeReady)return;let i=this._beginRuntimeDataDelivery(e);this._trySetRuntimeDataDirect(e,t,i)||this._sendControl("set-runtime-data",{channel:e,payload:t,requestId:i})}_deliverRuntimeDataClear(e){if(!this.isConnected||!this._runtimeBridgeReady)return;let t=this._beginRuntimeDataDelivery(e);this._tryClearRuntimeDataDirect(e,t)||this._sendControl("clear-runtime-data",{channel:e,requestId:t})}_trySetRuntimeDataDirect(e,t,i){try{let r=this.iframe.contentWindow?.__hyperframes;return typeof r?.setRuntimeData!="function"?!1:(r.setRuntimeData(e,t,i),!0)}catch{return!1}}_tryClearRuntimeDataDirect(e,t){try{let i=this.iframe.contentWindow?.__hyperframes;return typeof i?.clearRuntimeData!="function"?!1:(i.clearRuntimeData(e,t),!0)}catch{return!1}}_replayRuntimeData(){for(let[e,t]of this._runtimeData)this._deliverRuntimeData(e,t)}_beginRuntimeDataDelivery(e){let t=this._pendingRuntimeData.get(e);t&&window.clearTimeout(t.timeoutId),this._runtimeDataRequestId+=1;let i=this._runtimeDataRequestId,r=window.setTimeout(()=>{this._rejectRuntimeDataDelivery(e,i,`Runtime data delivery timed out after ${fn}ms`)},fn);return this._pendingRuntimeData.set(e,{requestId:i,timeoutId:r}),i}_resolveRuntimeDataDelivery(e,t){let i=this._takeRuntimeDataDelivery(e,t);i&&this.dispatchEvent(new CustomEvent("runtimedataapplied",{detail:{channel:e,requestId:i.requestId}}))}_rejectRuntimeDataDelivery(e,t,i){let r=this._takeRuntimeDataDelivery(e,t);r&&this.dispatchEvent(new CustomEvent("runtimedataerror",{detail:{channel:e,requestId:r.requestId,message:typeof i=="string"?i:String(i)}}))}_takeRuntimeDataDelivery(e,t){if(typeof e!="string"||typeof t!="number"||!Number.isSafeInteger(t))return null;let i=this._pendingRuntimeData.get(e);return!i||i.requestId!==t?null:(window.clearTimeout(i.timeoutId),this._pendingRuntimeData.delete(e),i)}_rejectAllRuntimeDataDeliveries(e){for(let[t,i]of[...this._pendingRuntimeData])this._rejectRuntimeDataDelivery(t,i.requestId,e)}_getSameOriginIframeDocument(){try{return this.iframe.contentDocument}catch{return null}}_setIframeMediaMuted(e){let t=this._getSameOriginIframeDocument();if(t)for(let i of t.querySelectorAll("video, audio"))x(i)&&(i.muted=e||i.defaultMuted)}_stopIframeMedia(){let e=this._getSameOriginIframeDocument();if(e)for(let t of e.querySelectorAll("video, audio"))x(t)&&t.pause()}_replayBridgeState(){this._sendControl("set-muted",{muted:this.muted}),this._sendControl("set-volume",{volume:this._volume}),this._sendControl("set-playback-rate",{playbackRate:this.playbackRate}),this._sendControl("set-native-media-sync-disabled",{disabled:this._isSlideshowPlayer()}),this._sendControl("set-web-audio-media-disabled",{disabled:this._isSlideshowPlayer()}),this._sendControl("set-idle-heartbeat",{slow:this.hasAttribute(Je)})}_reloadShaderOptions(){if(this._abandonComposition("Shader options changed before runtime data was applied"),U(this)!=="player"&&this.shaderLoader.reset(),this.hasAttribute("srcdoc")){this.iframe.srcdoc=Z(this,this.getAttribute("srcdoc")||"");return}this.hasAttribute("src")&&(this.iframe.src=J(this,this.getAttribute("src")||""))}_trySyncSeek(e){try{let i=this.iframe.contentWindow?.__player;return typeof i?.seek!="function"?!1:(i.seek.call(i,e),!0)}catch{return!1}}_withDirectTimeline(e){let t=this.probe.resolveDirectTimelineAdapter(),i=t||this._directTimelineAdapter;if(!i)return!1;try{if(e(i),t&&t!==this._directTimelineAdapter){let r=t.duration();Number.isFinite(r)&&r>0&&(this._duration=r,this.controlsApi?.updateTime(this._currentTime,r))}return this._directTimelineAdapter=i,!0}catch{return!1}}_tryDirectTimelineSeek(e){return this._withDirectTimeline(t=>{t.seek(e,!1),t.pause()})}_tryDirectTimelinePlay(){return this._withDirectTimeline(e=>{e.play()})}_tryDirectTimelinePause(){return this._withDirectTimeline(e=>{e.pause()})}_startParentTickClock(){this._stopParentTickClock();let e=()=>{if(this._paused){this._parentTickRaf=null;return}this._sendControl("tick"),this._parentTickRaf=requestAnimationFrame(e)};this._parentTickRaf=requestAnimationFrame(e)}_stopParentTickClock(){this._parentTickRaf!==null&&(cancelAnimationFrame(this._parentTickRaf),this._parentTickRaf=null)}_onMessage(e){sn(e,this.iframe.contentWindow,{getPlaybackState:()=>({currentTime:this._currentTime,duration:this._duration,paused:this._paused,lastUpdateMs:this._lastUpdateMs}),setPlaybackState:({currentTime:t,duration:i,paused:r,lastUpdateMs:o})=>{this._currentTime=t,this._duration=i,this._paused=r,this._lastUpdateMs=o},getShaderLoadingMode:()=>U(this),shaderLoader:this.shaderLoader,setCompositionSize:(t,i)=>{this._compositionWidth=t,this._compositionHeight=i,this._rescale()},sendControl:(t,i)=>this._sendControl(t,i),getIframeDoc:()=>this.iframe.contentDocument,onRuntimeReady:()=>{this._runtimeBridgeReady=!0,this._replayBridgeState(),this._replayRuntimeData()},onRuntimeAssetsReady:()=>{this._runtimeAssetsReadyGeneration===this._assetsGeneration&&this._settleAssetsReady(this._assetsGeneration)},onRuntimeDataApplied:(t,i)=>this._resolveRuntimeDataDelivery(t,i),onRuntimeDataError:(t,i,r)=>this._rejectRuntimeDataDelivery(t,i,r),onRuntimeTimelineReady:(t,i)=>this._onRuntimeTimelineReady(t,i),setRuntimeFps:t=>{this._runtimeFps=t},shouldPromoteMediaAutoplayFallback:()=>!this._isSlideshowPlayer(),setScenes:t=>{this._scenes=t,this.dispatchEvent(new CustomEvent("scenes",{detail:{scenes:t}}))},updateControlsTime:(t,i)=>this.controlsApi?.updateTime(t,i),updateControlsPlaying:t=>this.controlsApi?.updatePlaying(t),dispatchEvent:t=>this.dispatchEvent(t),seek:t=>this.seek(t),play:()=>this.play(),getLoop:()=>this.loop,media:this._media})}_onRuntimeTimelineReady(e,t){if(this._ready)return;this.probe.stop(),this._duration=e,this._directTimelineAdapter=null,this._ready=!0,this.controlsApi?.updateTime(this._currentTime,e),this.dispatchEvent(new CustomEvent("ready",{detail:{duration:e}})),this._rescale();let i=this._getSameOriginIframeDocument();i&&this._media.setupFromIframe(i),this._replayBridgeState(),this._setIframeMediaMuted(this.muted),this._waitForAssetsReady(i,t),(this.hasAttribute("autoplay")||this._pendingPlay)&&this.play()}_onProbeReady({duration:e,adapter:t,compositionSize:i}){this._duration=e,this._directTimelineAdapter=t.kind==="direct-timeline"?t.timeline:null,this._ready=!0,this.controlsApi?.updateTime(0,e),this.dispatchEvent(new CustomEvent("ready",{detail:{duration:e}})),i&&(this._compositionWidth=i.width,this._compositionHeight=i.height,this._rescale());let r=this._getSameOriginIframeDocument();r&&this._media.setupFromIframe(r),this._setIframeMediaMuted(this.muted),this._waitForAssetsReady(r),(this.hasAttribute("autoplay")||this._pendingPlay)&&this.play()}_waitForAssetsReady(e,t){this._clearAssetsLoadingShowTimer(),this._assetsReady=!1,this._painted=!1;let i=++this._assetsGeneration;if(!e){t===!1?(this._runtimeAssetsReadyGeneration=i,this._startAssetsLoadingOverlayTimer(i),setTimeout(()=>this._settleAssetsReady(i),Xe)):this._settleAssetsReady(i);return}on(e,({timedOut:r})=>{i===this._assetsGeneration&&(r&&this._warnStuckAssets(e),this._settleAssetsReady(i))},{timeoutMs:Xe}),this._assetsReady||this._startAssetsLoadingOverlayTimer(i)}_startAssetsLoadingOverlayTimer(e){this._assetsLoadingShowTimer=setTimeout(()=>{this._assetsLoadingShowTimer=null,!(e!==this._assetsGeneration||this._assetsReady)&&(this.setAttribute(Ke,""),this.assetsLoadingUi!=="none"&&this.shaderLoader.showAssetsLoading())},Ki)}_warnStuckAssets(e){let{pendingMedia:t,pendingImages:i,fontsLoading:r}=qe(e,{scope:$e}),o=e.defaultView;console.warn(`[hyperframes-player] assets-loading timed out after ${Xe}ms \u2014 playing anyway`,{stuckMedia:t.map(a=>a.currentSrc||a.getAttribute("src")||`<${a.tagName.toLowerCase()}>`),stuckImages:i.map(a=>a.currentSrc||a.getAttribute("src")||"<img>"),fontsLoading:r,computeReady:o?.__renderReady===!0,documentHidden:e.hidden===!0})}_settleAssetsReady(e){e!==this._assetsGeneration||this._assetsReady||(this._clearAssetsLoadingShowTimer(),this._assetsReady=!0,this.removeAttribute(Ke),this.shaderLoader.hideAssetsLoading(),this.dispatchEvent(new Event("assetsready")),this.shaderLoader.whenHidden(()=>{e===this._assetsGeneration&&(this._painted=!0,this.dispatchEvent(new Event("painted")))}),this._pendingPlay&&this.play())}_abandonComposition(e){this._ready=!1,this._invalidateAssetsWait(),this._runtimeBridgeReady=!1,this._rejectAllRuntimeDataDeliveries(e)}_invalidateAssetsWait(){this._clearAssetsLoadingShowTimer(),this._assetsReady=!1,this._painted=!1,this._assetsGeneration++,this.removeAttribute(Ke),this.shaderLoader.hide()}_clearAssetsLoadingShowTimer(){this._assetsLoadingShowTimer!==null&&(clearTimeout(this._assetsLoadingShowTimer),this._assetsLoadingShowTimer=null)}_rescale(){!xt(this,this.iframe,this._compositionWidth,this._compositionHeight)&&this._ready&&!this._rescaleWarned&&(this._rescaleWarned=!0,console.warn("[hyperframes-player] rescale no-op after ready \u2014 zero-size player element",{src:this.getAttribute("src"),offsetWidth:this.offsetWidth,offsetHeight:this.offsetHeight,compositionWidth:this._compositionWidth,compositionHeight:this._compositionHeight}))}_onIframeLoad(){this._ready&&this._getSameOriginIframeDocument()===null||(this._ready=!1,this._directTimelineAdapter=null,this._directTimelineClock.stop(),this._stopParentTickClock(),this._invalidateAssetsWait(),this.shaderLoader.reset(),this._media.resetForIframeLoad(),this.probe.start())}_setupControls(){this.controlsApi||(this.controlsApi=At(this.shadow,this.muted,this._volume,this.getAttribute("speed-presets"),{onPlay:()=>this.play(),onPause:()=>this.pause(),onSeek:e=>this.seek(e*this._duration),onScrubStart:()=>{this._scrubbing=!0},onScrubEnd:()=>{this._scrubbing=!1,this.seek(this._currentTime)},onSpeedChange:e=>{this.playbackRate=e},onMuteToggle:()=>{this.muted=!this.muted},onVolumeChange:e=>{this.volume=e}},this._isAudioLocked()))}get _audioOwner(){return this._media.audioOwner}get _parentMedia(){return this._media.entries}_mirrorParentMediaTime(e,t){this._media.mirrorTime(e,t)}_promoteToParentProxy(){let e=null;try{e=this.iframe.contentDocument}catch{}this._media.promoteToParentProxy(e,(t,i)=>this._mirrorParentMediaTime(t,i)),this._sendControl("set-media-output-muted",{muted:!0})}_observeDynamicMedia(e){this._media.setupFromIframe(e)}};customElements.get("hyperframes-player")||customElements.define("hyperframes-player",Se);return An(Ji);})();
//# sourceMappingURL=hyperframes-player.global.js.map
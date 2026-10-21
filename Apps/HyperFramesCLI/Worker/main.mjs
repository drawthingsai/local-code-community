import { parseArgs } from "node:util";
import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  copyFileSync,
  existsSync,
  realpathSync,
} from "node:fs";
import { resolve, join, basename } from "node:path";
import { DOMParser } from "linkedom";
import { lintProject } from "@hyperframes/lint";
import { bundleToSingleHtml } from "upstream/core/src/compiler/htmlBundler.ts";
import { buildPresentPage } from "upstream/cli/src/commands/present.ts";
import { parseCompositions } from "upstream/cli/src/commands/compositions.ts";
import { describeProject } from "upstream/cli/src/timeline/describeProject.ts";
import { formatTimeline } from "upstream/cli/src/timeline/formatTimeline.ts";
import {
  DEFAULT_CHECK_OPTIONS,
  runCheckPipeline,
  runAuditGrid,
  resolveMotionSpec,
  checkExitCode,
} from "upstream/cli/src/utils/checkPipeline.ts";
import { createPageDriver } from "upstream/cli/src/utils/checkBrowser.ts";
import { rpc, output, closeBridge } from "./bridge.mjs";
import { resources, page } from "./platform.mjs";
globalThis.DOMParser = DOMParser;
const definitions = {
  presentation: "boolean",
  "preview-page": "boolean",
  entry: "string",
  json: "boolean",
  verbose: "boolean",
  help: "boolean",
  "non-interactive": "boolean",
  example: "string",
  resolution: "string",
  samples: "string",
  at: "string",
  "at-transitions": "boolean",
  tolerance: "string",
  timeout: "string",
  "no-contrast": "boolean",
  strict: "boolean",
  snapshots: "boolean",
  "caption-zone": "string",
  "frame-check": "boolean",
  frames: "string",
  zoom: "string",
  "zoom-scale": "string",
  foreground: "boolean",
  "no-open": "boolean",
  port: "string",
};
const { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  allowPositionals: true,
  options: Object.fromEntries(
    Object.entries(definitions).map(([key, type]) => [key, { type }]),
  ),
});
const [command, projectArgument, ...extra] = positionals;
function number(name, fallback, min, max, integer = false) {
  const value = values[name] === undefined ? fallback : Number(values[name]);
  if (
    !Number.isFinite(value) ||
    value < min ||
    value > max ||
    (integer && !Number.isInteger(value))
  )
    throw new Error(
      `--${name} must be ${integer ? "an integer" : "a number"} in ${min}…${max}`,
    );
  return value;
}
function times(value) {
  const result = value
    .split(",")
    .map((value) => (value.trim() ? Number(value) : NaN));
  if (
    !result.length ||
    result.some((value) => !Number.isFinite(value) || value < 0)
  )
    throw new Error("Seek times must be comma-separated nonnegative numbers");
  return [...new Set(result)].sort((a, b) => a - b);
}
function project() {
  const dir = realpathSync(resolve(projectArgument ?? "."));
  const indexPath = join(dir, "index.html");
  if (!existsSync(indexPath)) throw new Error(`No index.html in ${dir}`);
  return { dir, indexPath, name: basename(dir) };
}
async function compile(p) {
  return bundleToSingleHtml(p.dir, {
    inlineAssets: false,
    probeMediaDuration: async (path) => (await rpc("probe", { path })).duration,
  });
}
async function open(p, timeout = 3000) {
  return rpc("load", {
    directory: p.dir,
    html: await compile(p),
    timeout: timeout / 1000,
  });
}
function save(p, name, data) {
  mkdirSync(join(p.dir, "snapshots"), { recursive: true });
  writeFileSync(join(p.dir, "snapshots", name), Buffer.from(data, "base64"));
  return join("snapshots", name);
}
function captionZone(value) {
  const zone = {};
  for (const entry of value.split(";")) {
    const [key, text] = entry.split("=");
    if (["x0", "y0", "x1", "y1"].includes(key)) zone[key] = Number(text);
    else if (key === "seek") zone.seek = times(text);
    else if (key === "severity" && ["error", "warning"].includes(text))
      zone.severity = text;
    else throw new Error(`Invalid caption-zone field: ${entry}`);
  }
  if (
    ["x0", "y0", "x1", "y1"].some(
      (key) => !Number.isFinite(zone[key]) || zone[key] < 0 || zone[key] > 1,
    ) ||
    zone.x1 <= zone.x0 ||
    zone.y1 <= zone.y0
  )
    throw new Error(
      "caption-zone requires an increasing rectangle with coordinates in 0…1",
    );
  return zone;
}
async function main() {
  if (extra.length) throw new Error("Too many positional arguments");
  if (values.help || !command) {
    output(`HyperFrames — author, inspect, and preview HTML video compositions.

Usage: hyperframes <command> [project] [options]
       hyperframes --version
       hyperframes --help

Run the supplied hyperframes command directly from the project directory.

Commands:
  init          Scaffold a new composition project
  lint          Validate composition source
  compositions  List compositions
  timeline      Describe tracks, clips, and timing
  preview       Serve the composition preview
  present       Serve a slideshow deck
  check         Audit runtime, layout, motion, and contrast
  snapshot      Capture composition frames as PNG images

Options:
  init: --non-interactive --example blank --resolution landscape|portrait|landscape-4k|portrait-4k|square|square-4k
  lint: --json --verbose
  compositions, timeline: --json
  preview, present: --foreground --no-open --port N --json
  check: --json --samples N --at 0,1 --at-transitions --tolerance N --timeout MS --no-contrast --strict --snapshots --caption-zone SPEC --frame-check
  snapshot: --frames N --at 0,1 --zoom SELECTOR|x,y,w,h --zoom-scale N

Video export uses the separate html2video command:
  1. From the project directory, keep this command running:
       hyperframes preview --foreground --no-open
  2. In another Bash invocation, from the same project directory, set
     PREVIEW_URL to the printed URL and fetch the compiled composition:
       curl --fail --silent --show-error "\${PREVIEW_URL%/}/__hyperframes_composition.html" --output .hyperframes-export.htm
  3. After the download succeeds, export the compiled page:
       html2video .hyperframes-export.htm --output out.mp4

Fetch the compiled page again after source edits. Keep it beside index.html
so project-relative assets resolve. Use html2video --help for export options.`);
    return 0;
  }
  if (command === "init") {
    if (!projectArgument) throw new Error("init requires a project directory");
    if (values.example && values.example !== "blank")
      throw new Error("Supported example: blank");
    const aliases = {
      "1080p": "landscape",
      "4k": "landscape-4k",
      uhd: "landscape-4k",
      "1080p-square": "square",
      "4k-square": "square-4k",
    };
    const presets = {
      landscape: [1920, 1080],
      portrait: [1080, 1920],
      "landscape-4k": [3840, 2160],
      "portrait-4k": [2160, 3840],
      square: [1080, 1080],
      "square-4k": [2160, 2160],
    };
    const resolution =
      aliases[values.resolution] ?? values.resolution ?? "landscape";
    if (!presets[resolution]) throw new Error("Unknown resolution preset");
    const [width, height] = presets[resolution];
    const dir = resolve(projectArgument);
    mkdirSync(dir); // Refuse to overwrite an existing project.
    mkdirSync(join(dir, "assets"));
    mkdirSync(join(dir, "public"));
    for (const name of [
      "gsap.min.js",
      "hyperframe.runtime.iife.js",
      "hyperframes-player.global.js",
      "hyperframes-slideshow.global.js",
    ])
      copyFileSync(join(resources, name), join(dir, "assets", name));
    writeFileSync(
      join(dir, "hyperframes.json"),
      JSON.stringify({ resolution }, null, 2) + "\n",
    );
    writeFileSync(
      join(dir, "index.html"),
      `<!doctype html>\n<html lang="en"><head><meta charset="UTF-8"><title>Untitled video</title>\n<script src="assets/gsap.min.js"></script><script src="assets/hyperframe.runtime.iife.js"></script>\n<style>html,body{margin:0;background:#111;color:white}*{box-sizing:border-box}#root{position:relative;width:${width}px;height:${height}px;overflow:hidden;display:grid;place-items:center;font-family:Arial,sans-serif}h1{font-size:96px}</style></head>\n<body><div id="root" data-composition-id="root" data-width="${width}" data-height="${height}" data-duration="5"><h1 id="title">Your story starts here.</h1></div>\n<script>window.__timelines=window.__timelines||{};window.__timelines.root=gsap.timeline({paused:true}).from('#title',{opacity:0,y:40,duration:0.8}).to('#title',{opacity:0,duration:0.5},4.5);</script></body></html>\n`,
    );
    output(
      values.json
        ? { ok: true, directory: dir, width, height }
        : `Created ${dir} (${width}×${height})`,
    );
    return 0;
  }
  const p = project();
  if (command === "__compile") {
    const entry =
      values.entry === "__hyperframes_composition.html"
        ? "index.html"
        : (values.entry ?? "index.html");
    const raw = readFileSync(join(p.dir, entry), "utf8");
    if (raw.includes("<hyperframes-player")) output(raw);
    else if (values.presentation || values["preview-page"]) {
      const document = new DOMParser().parseFromString(raw, "text/html");
      const island = document.querySelector(
        'script[type="application/hyperframes-slideshow+json"]',
      )?.textContent;
      if (values.presentation && !island)
        throw new Error("present requires a slideshow island");
      if (values.presentation) {
        output(
          buildPresentPage(
            p.name,
            JSON.stringify(JSON.parse(island)).replaceAll("<", "\\u003c"),
          )
            .replaceAll(
              "/composition/index.html",
              "/__hyperframes_composition.html",
            )
            .replaceAll("/composition/sfx/", "/sfx/")
            .replaceAll("/player.js", "/assets/hyperframes-player.global.js")
            .replaceAll(
              "/slideshow.js",
              "/assets/hyperframes-slideshow.global.js",
            ),
        );
        return 0;
      }
      const player =
        '<hyperframes-player interactive controls style="width:100%;height:100%;display:block" src="__hyperframes_composition.html"></hyperframes-player>';
      output(
        `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><script src="assets/hyperframes-player.global.js"></script><script src="assets/hyperframes-slideshow.global.js"></script><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#111}</style></head><body>${player}</body></html>`,
      );
    } else if (!raw.includes("data-composition-id")) output(raw);
    else
      output(
        await bundleToSingleHtml(p.dir, {
          entryFile: entry,
          inlineAssets: false,
          probeMediaDuration: async (path) =>
            (await rpc("probe", { path })).duration,
        }),
      );
    return 0;
  }
  if (command === "lint") {
    const result = await lintProject(p.dir);
    if (values.json)
      output({
        ok: result.totalErrors === 0,
        errorCount: result.totalErrors,
        warningCount: result.totalWarnings,
        infoCount: result.totalInfos,
        filesScanned: result.results.length,
        findings: result.results
          .flatMap((file) => file.result.findings)
          .filter((f) => values.verbose || f.severity !== "info"),
      });
    else {
      for (const file of result.results)
        for (const finding of file.result.findings ?? [])
          if (values.verbose || finding.severity !== "info")
            output(
              `${file.file}:${finding.line ?? ""} ${finding.severity} ${finding.code}: ${finding.message}`,
            );
      output(
        `${result.totalErrors} errors, ${result.totalWarnings} warnings, ${result.totalInfos} notes`,
      );
    }
    return result.totalErrors ? 1 : 0;
  }
  if (command === "compositions") {
    const compositions = parseCompositions(
      readFileSync(p.indexPath, "utf8"),
      p.dir,
    );
    output(
      values.json
        ? { compositions }
        : compositions
            .map(
              (c) =>
                `${c.id}  ${c.duration}s  ${c.width}×${c.height}  ${c.elementCount} elements${c.source ? " ← " + c.source : ""}`,
            )
            .join("\n"),
    );
    return 0;
  }
  if (command === "timeline") {
    const result = await describeProject(
      p.indexPath,
      async (file) => (await rpc("probe", { path: file })).duration,
    );
    output(values.json ? result : formatTimeline(result));
    return 0;
  }
  if (command === "preview" || command === "present") {
    const result = await rpc("serve", {
      directory: p.dir,
      port: number("port", 0, 0, 65535, true),
      present: command === "present",
      open: !values["no-open"],
    });
    output(values.json ? { ready: true, ...result } : result.url);
    return 0;
  }
  if (command === "snapshot") {
    const count = number("frames", 5, 1, 100, true),
      scale = number("zoom-scale", 3, 1, 8);
    const metadata = await open(p, 30000);
    const samples = values.at
      ? times(values.at)
      : Array.from({ length: count }, (_, i) =>
          count === 1
            ? 0
            : (i * Math.max(0, metadata.duration - 1 / 30)) / (count - 1),
        );
    if (samples.some((time) => time > metadata.duration))
      throw new Error("Snapshot time exceeds composition duration");
    const shots = [];
    const files = [];
    const shotTimes = [];
    for (const [i, time] of samples.entries()) {
      await rpc("seek", { time });
      const shot = await rpc("snapshot", {
        zoom: values.zoom,
        scale: values.zoom ? scale : 1,
      });
      if (!shot) {
        console.error(`Skipped collapsed zoom region at ${time}s`);
        continue;
      }
      files.push(
        save(
          p,
          `frame-${String(i).padStart(2, "0")}-at-${time.toFixed(3)}s.png`,
          shot,
        ),
      );
      shots.push(shot);
      shotTimes.push(time);
    }
    if (!shots.length) throw new Error("No visible snapshot regions");
    files.push(
      save(
        p,
        "contact-sheet.png",
        await rpc("contactSheet", { images: shots, times: shotTimes }),
      ),
    );
    output(
      values.json
        ? { files }
        : files.map((file) => join(p.dir, file)).join("\n"),
    );
    return 0;
  }
  if (command === "check") {
    const options = {
      ...DEFAULT_CHECK_OPTIONS,
      samples: number("samples", 9, 1, 100, true),
      tolerance: number("tolerance", 2, 0, 1000),
      timeout: number("timeout", 3000, 1, 300000),
      at: values.at ? times(values.at) : undefined,
      atTransitions: !!values["at-transitions"],
      contrast: !values["no-contrast"],
      strict: !!values.strict,
      snapshots: !!values.snapshots,
      captionZone: values["caption-zone"]
        ? captionZone(values["caption-zone"])
        : undefined,
      frameCheck: values["frame-check"] ? {} : undefined,
    };
    const result = await runCheckPipeline(p, options, {
      lintProject,
      resolveMotionSpec,
      inspectHdrAutoPromotion: async () => {
        throw new Error("HDR inspection unavailable");
      },
      runBrowserCheck: async (_p, opts, motion) => {
        await open(p, opts.timeout);
        const report = await runAuditGrid(
          createPageDriver(page, () => {}),
          opts,
          motion,
        );
        report.runtimeFindings = await rpc("runtimeFindings");
        return report;
      },
      writeSnapshot: async (_dir, index, time, data) =>
        save(p, `check-${index}-at-${time.toFixed(3)}s.png`, data),
      captureFindingCrops: async (_p, _opts, requests) => {
        const files = [];
        for (const [i, request] of requests.entries()) {
          await rpc("seek", { time: request.time });
          const box = request.bbox;
          const shot = await rpc("snapshot", {
            zoom: [box.x, box.y, box.width, box.height].join(","),
            scale: 2,
          });
          if (shot) files.push(save(p, request.filename, shot));
        }
        return files;
      },
    });
    if (values.json) output(result);
    else {
      output(result.ok ? "Check passed" : "Check failed");
      output(JSON.stringify(result, null, 2));
    }
    return checkExitCode(result);
  }
  throw new Error(`Unknown command: ${command}`);
}
main().then(
  (status) => {
    closeBridge();
    process.exitCode = status;
  },
  (error) => {
    if (values.json)
      output({
        ok: false,
        error: error.message,
        ...(command === "lint"
          ? {
              findings: [],
              errorCount: 0,
              warningCount: 0,
              infoCount: 0,
              filesScanned: 0,
            }
          : {}),
      });
    else console.error(`hyperframes: ${error.message}`);
    closeBridge();
    process.exitCode = 1;
  },
);

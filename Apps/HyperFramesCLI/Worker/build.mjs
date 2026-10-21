import { createRequire } from "node:module";
import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  copyFileSync,
  existsSync,
  realpathSync,
} from "node:fs";
import { dirname, join, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));
const upstream = realpathSync(
  process.env.HYPERFRAMES_UPSTREAM ?? join(here, "../Upstream"),
);
const dependencies =
  process.env.HYPERFRAMES_NODE_MODULES ?? join(here, "node_modules");
const require = createRequire(import.meta.url);
const { build } = require(process.env.ESBUILD_MODULE ?? "esbuild");
const platform = join(here, "platform.mjs");
const pkg = (name) =>
  JSON.parse(
    readFileSync(join(upstream, "packages", name, "package.json"), "utf8"),
  );
const manifests = { core: pkg("core"), parsers: pkg("parsers") };
const used = new Set();
const options = {
  entryPoints: [join(here, "main.mjs")],
  outfile: join(here, "../Resources/HyperFrames/worker.cjs"),
  bundle: true,
  minify: true,
  platform: "node",
  format: "cjs",
  target: "node24",
  metafile: true,
  nodePaths: dependencies ? [dependencies] : [],
  legalComments: "linked",
  plugins: [
    {
      name: "native-platform",
      setup(build) {
        build.onResolve({ filter: /^canvas$/ }, () => ({
          path: join(dependencies, "linkedom/commonjs/canvas-shim.cjs"),
        }));
        build.onResolve({ filter: /^upstream\// }, (args) => ({
          path: join(upstream, "packages", args.path.slice(9)),
        }));
        build.onResolve({ filter: /^@hyperframes\// }, (args) => {
          const [, name, ...parts] = args.path.split("/");
          if (name === "engine") return { path: join(here, "engine.mjs") };
          if (name === "core" && !parts.length)
            return {
              path: join(
                upstream,
                "packages/core/src/runtime/startExpression.ts",
              ),
            };
          if (parts.join("/") === "ff-binaries") return { path: platform };
          const entry =
            manifests[name]?.exports[
              parts.length ? "./" + parts.join("/") : "."
            ];
          if (entry)
            return {
              path: resolve(
                upstream,
                "packages",
                name,
                typeof entry === "string" ? entry : entry.import,
              ),
            };
          if (name === "lint")
            return { path: join(upstream, "packages/lint/src/index.ts") };
          throw new Error(`Unmapped HyperFrames import: ${args.path}`);
        });
        build.onResolve(
          { filter: /^(esbuild|node:child_process)$/ },
          (args) => {
            if (
              args.path === "esbuild" ||
              args.importer.endsWith("hevcPreviewLint.ts")
            )
              return { path: platform };
            throw new Error(`Unexpected process dependency: ${args.importer}`);
          },
        );
        build.onResolve({ filter: /generated\/runtime-inline$/ }, () => ({
          path: platform,
        }));
        build.onLoad({ filter: /\.ts$/ }, (args) => {
          if (!args.path.startsWith(upstream + "/")) return;
          used.add(args.path);
          let source = readFileSync(args.path, "utf8");
          if (args.path.endsWith("/hevcPreviewLint.ts")) {
            // Keep diagnostic guidance aligned with native media decoding.
            source = source
              .replace(
                "The render pipeline pre-decodes video with FFmpeg and never uses the browser's video decoder, so these render correctly. ",
                "Video export with html2video uses native media decoding. ",
              )
              .replace(
                "Live preview/player playback automatically uses a cached H.264 proxy when the browser cannot decode HEVC. ",
                "Preview playback depends on the browser's HEVC support. ",
              )
              .replace(
                "If playback still fails, verify ffmpeg/ffprobe are installed and auto-proxying is enabled.",
                "If preview playback fails, use an H.264 source and run hyperframes check.",
              )
              .replaceAll(
                "run hyperframes doctor and confirm media.autoProxy is not false.",
                "use an H.264 source and run hyperframes check.",
              );
          }
          if (args.path.endsWith("/checkPipeline.ts")) {
            source = source
              .replace(/^import .*from "\.\.\/telemetry\/.*;\n/gm, "")
              .replace(/^import .*from "\.\/hdrPromotion.js";\n/m, "")
              .replace(
                "dependencies: CheckDependencies = DEFAULT_DEPENDENCIES",
                "dependencies: CheckDependencies",
              )
              .replace(
                "(dependencies.inspectHdrAutoPromotion ?? inspectHdrAutoPromotion)(project)",
                "dependencies.inspectHdrAutoPromotion!(project)",
              )
              .replace(
                "function resolveMotionSpec(",
                "export function resolveMotionSpec(",
              );
            source = source.slice(
              0,
              source.indexOf("\nasync function runBrowserCheck("),
            );
            source =
              "const trackCheckReport = () => {}; const trackCommandFailure = () => {}; const trackLintRun = () => {}; const getRunId = () => undefined;\n" +
              source;
            source = source.replaceAll("Date.now()", "performance.now()");
          }
          if (args.path.endsWith("/checkBrowser.ts")) {
            source = source.slice(source.indexOf("function createPageDriver("));
            source = source.replace(
              "function createPageDriver(",
              "export function createPageDriver(",
            );
            source =
              `import {loadBrowserScript, seekCompositionTimeline, AUDIT_SEEK_OPTIONS, DENSE_GEOMETRY_SEEK_OPTIONS} from ${JSON.stringify(platform)};\nimport {ambiguousIssue} from './motionAudit.js';\nimport {rectToBbox} from './checkTypes.js';\n` +
              source;
          }
          if (args.path.endsWith("/commands/present.ts")) {
            source = source.slice(
              source.indexOf("function buildPresentPage("),
              source.indexOf(
                "export async function registerPresentCompositionRoute(",
              ),
            );
            source = source.replace(
              "function buildPresentPage(",
              "export function buildPresentPage(",
            );
          }
          if (args.path.endsWith("/commands/compositions.ts")) {
            source = source.slice(
              source.indexOf("interface CompositionInfo"),
              source.indexOf("\nexport default defineCommand"),
            );
            source =
              "import {existsSync,readFileSync} from 'node:fs'; import {resolve} from 'node:path'; import {resolveReferencedStart} from '@hyperframes/engine';\n" +
              source;
          }
          return {
            contents: source,
            loader: "ts",
            resolveDir: dirname(args.path),
          };
        });
      },
    },
  ],
};
const result = await build(options);
const runtime = await build({
  ...options,
  entryPoints: [join(upstream, "packages/core/src/runtime/entry.ts")],
  outfile: join(here, "../Resources/HyperFrames/hyperframe.runtime.iife.js"),
  platform: "browser",
  format: "iife",
  target: "safari15.4",
});
// Retain only the immutable upstream source files used by this build.
const vendored = join(here, "../Upstream");
for (const path of used) {
  const destination = join(vendored, relative(upstream, path));
  if (resolve(destination) !== resolve(path)) {
    mkdirSync(dirname(destination), { recursive: true });
    copyFileSync(path, destination);
  }
}
for (const name of ["core", "parsers"]) {
  const destination = join(vendored, "packages", name, "package.json");
  mkdirSync(dirname(destination), { recursive: true });
  if (!existsSync(destination))
    copyFileSync(join(upstream, "packages", name, "package.json"), destination);
}
const inputs = [
  ...Object.keys(result.metafile.inputs),
  ...Object.keys(runtime.metafile.inputs),
];
const licenses = new Map();
for (const input of inputs) {
  let directory = dirname(resolve(input));
  while (directory !== dirname(directory)) {
    const manifest = join(directory, "package.json");
    if (directory.includes("/node_modules/") && existsSync(manifest)) {
      const pkg = JSON.parse(readFileSync(manifest, "utf8"));
      const license = [
        "LICENSE",
        "LICENSE.md",
        "LICENSE.txt",
        "license",
        "license.md",
      ]
        .map((name) => join(directory, name))
        .find(existsSync);
      if (license)
        licenses.set(
          pkg.name + "@" + pkg.version,
          readFileSync(license, "utf8"),
        );
      break;
    }
    directory = dirname(directory);
  }
}
writeFileSync(
  join(here, "../Resources/HyperFrames/THIRD_PARTY_LICENSES.txt"),
  readFileSync(join(here, "../LICENSE.hyperframes"), "utf8") +
    "\n\nGSAP 3.15.0 — Copyright 2026 GreenSock. All rights reserved.\nhttps://gsap.com/standard-license\n\n" +
    [...licenses.entries()]
      .sort()
      .map(([name, text]) => name + "\n" + text)
      .join("\n\n"),
);

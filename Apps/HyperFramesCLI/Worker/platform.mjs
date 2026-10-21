import { readFileSync } from "node:fs";
import { join } from "node:path";
import { rpc } from "./bridge.mjs";
export const resources = process.env.HYPERFRAMES_RESOURCES;
export function getHyperframeRuntimeScript() {
  return readFileSync(join(resources, "hyperframe.runtime.iife.js"), "utf8");
}
export function loadBrowserScript(name) {
  return readFileSync(join(resources, name), "utf8");
}
// The upstream transform only strips comments from already-valid JavaScript.
// Keeping the authored source preserves its semantics without a native esbuild dependency.
export function transformSync(source) {
  return { code: source };
}
export const extractMediaMetadata = (file) => rpc("probe", { path: file });
export const extractAudioMetadata = extractMediaMetadata;
export const findFfBinary = () => "native-media-probe";
export function execFile(_file, args, _options, callback) {
  rpc("probe", { path: args.at(-1) }).then(
    (meta) =>
      callback(
        null,
        JSON.stringify({
          format: { duration: String(meta.duration) },
          streams: [
            { duration: String(meta.duration), codec_name: meta.codec },
          ],
        }),
      ),
    (error) => callback(error, ""),
  );
}
export const seekCompositionTimeline = (_page, time) => rpc("seek", { time });
export const AUDIT_SEEK_OPTIONS = {};
export const DENSE_GEOMETRY_SEEK_OPTIONS = {};
export const page = {
  evaluate: (fn, ...args) =>
    rpc("evaluate", { source: `return (${fn.toString()})(...args);`, args }),
  addScriptTag: ({ content }) => rpc("evaluate", { source: content, args: [] }),
  screenshot: (options) => rpc("snapshot", { ...options }),
};

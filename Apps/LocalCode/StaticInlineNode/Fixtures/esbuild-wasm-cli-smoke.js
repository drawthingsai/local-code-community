const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const packageRoot = process.env.NODE_MOBILE_ESBUILD_WASM_PACKAGE;
const inputPath = process.env.NODE_MOBILE_ESBUILD_WASM_INPUT;
const outputPath = process.env.NODE_MOBILE_ESBUILD_WASM_OUTPUT;
const expectedVersion = process.env.NODE_MOBILE_ESBUILD_WASM_VERSION;

assert.ok(
  packageRoot,
  "NODE_MOBILE_ESBUILD_WASM_PACKAGE must name the esbuild-wasm package root"
);
assert.ok(inputPath, "NODE_MOBILE_ESBUILD_WASM_INPUT must name the TypeScript input");
assert.ok(outputPath, "NODE_MOBILE_ESBUILD_WASM_OUTPUT must name a writable output");
assert.ok(expectedVersion, "NODE_MOBILE_ESBUILD_WASM_VERSION must be set");

const packageJSON = require(path.join(packageRoot, "package.json"));
assert.equal(packageJSON.version, expectedVersion);

const executable = path.join(packageRoot, "bin/esbuild");
process.argv = [
  process.execPath,
  executable,
  inputPath,
  "--bundle",
  "--format=esm",
  `--outfile=${outputPath}`,
];

process.on("exit", (status) => {
  if (status !== 0) {
    return;
  }
  const output = fs.readFileSync(outputPath, "utf8");
  assert.match(output, /var runtime = "NodeMobile"/);
  assert.match(output, /var answer = 6 \* 7/);
  console.log(
    "[StaticInlineNode] esbuild Wasm CLI fixture passed",
    JSON.stringify({
      esbuild: packageJSON.version,
      node: process.versions.node,
      platform: process.platform,
    })
  );
});

require(executable);

const assert = require("node:assert/strict");
const path = require("node:path");

const packageRoot = process.env.NODE_MOBILE_ROLLUP_WASM_PACKAGE;
const expectedVersion = process.env.NODE_MOBILE_ROLLUP_WASM_VERSION;

assert.ok(
  packageRoot,
  "NODE_MOBILE_ROLLUP_WASM_PACKAGE must name the @rollup/wasm-node package root"
);
assert.ok(expectedVersion, "NODE_MOBILE_ROLLUP_WASM_VERSION must be set");

const packageJSON = require(path.join(packageRoot, "package.json"));
assert.equal(packageJSON.version, expectedVersion);

const { rollup } = require(path.resolve(packageRoot));

rollup({
  input: "entry.js",
  plugins: [
    {
      name: "fixture-modules",
      resolveId(source) {
        return source === "entry.js" || source === "value.js" ? source : null;
      },
      load(id) {
        if (id === "entry.js") {
          return "import { value } from 'value.js'; export const answer = value;";
        }
        if (id === "value.js") {
          return "export const value = 6 * 7;";
        }
        return null;
      },
    },
  ],
})
  .then((bundle) => bundle.generate({ format: "es" }))
  .then((result) => {
    assert.equal(result.output.length, 1);
    assert.match(result.output[0].code, /const value = 6 \* 7/);
    assert.match(result.output[0].code, /answer/);
    console.log(
      "[StaticInlineNode] Rollup Wasm fixture passed",
      JSON.stringify({
        node: process.versions.node,
        platform: process.platform,
        rollup: packageJSON.version,
      })
    );
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });

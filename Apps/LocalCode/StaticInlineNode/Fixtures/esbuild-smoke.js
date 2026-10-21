const assert = require("node:assert/strict");
const path = require("node:path");

const packageRoot = process.env.NODE_MOBILE_ESBUILD_PACKAGE;
const expectedVersion = process.env.NODE_MOBILE_ESBUILD_VERSION;

assert.ok(packageRoot, "NODE_MOBILE_ESBUILD_PACKAGE must name the esbuild package root");
assert.ok(expectedVersion, "NODE_MOBILE_ESBUILD_VERSION must be set");

const esbuild = require(path.resolve(packageRoot));
assert.equal(esbuild.version, expectedVersion);

const transformed = esbuild.transformSync(
  "const answer: number = 6 * 7; console.log(answer);",
  {
    format: "esm",
    loader: "ts",
    target: "es2020",
  }
);
assert.match(transformed.code, /const answer = 6 \* 7/);

esbuild
  .build({
    bundle: true,
    format: "iife",
    platform: "browser",
    stdin: {
      contents:
        "import { value } from './value.js'; document.body.textContent = String(value);",
      resolveDir: __dirname,
      sourcefile: "entry.js",
    },
    plugins: [
      {
        name: "fixture-value",
        setup(build) {
          build.onResolve({ filter: /^\.\/value\.js$/ }, () => ({
            namespace: "fixture",
            path: "value.js",
          }));
          build.onLoad({ filter: /.*/, namespace: "fixture" }, () => ({
            contents: "export const value = 42;",
            loader: "js",
          }));
        },
      },
    ],
    write: false,
  })
  .then((result) => {
    assert.equal(result.outputFiles.length, 1);
    assert.match(result.outputFiles[0].text, /value = 42/);
    console.log(
      "[StaticInlineNode] esbuild fixture passed",
      JSON.stringify({
        esbuild: esbuild.version,
        node: process.versions.node,
        platform: process.platform,
      })
    );
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const packageRoot = process.env.NODE_MOBILE_VITE_PACKAGE;
const projectRoot = process.env.NODE_MOBILE_VITE_PROJECT;
const outputRoot = process.env.NODE_MOBILE_VITE_OUTPUT;
const expectedVersion = process.env.NODE_MOBILE_VITE_VERSION;
const expectedHTMLMarker =
  process.env.NODE_MOBILE_VITE_HTML_MARKER || "NodeMobile Vite fixture";

assert.ok(packageRoot, "NODE_MOBILE_VITE_PACKAGE must name the Vite package root");
assert.ok(projectRoot, "NODE_MOBILE_VITE_PROJECT must name the fixture project");
assert.ok(outputRoot, "NODE_MOBILE_VITE_OUTPUT must name a writable directory");
assert.ok(expectedVersion, "NODE_MOBILE_VITE_VERSION must be set");

const packageJSON = require(path.join(packageRoot, "package.json"));
assert.equal(packageJSON.version, expectedVersion);

import(pathToFileURL(path.join(packageRoot, "dist/node/index.js")).href)
  .then(({ build }) =>
    build({
      configFile: false,
      root: projectRoot,
      build: {
        emptyOutDir: true,
        outDir: outputRoot,
      },
    })
  )
  .then(() => {
    const indexHTML = fs.readFileSync(path.join(outputRoot, "index.html"), "utf8");
    assert.ok(indexHTML.includes(expectedHTMLMarker));
    const assets = fs.readdirSync(path.join(outputRoot, "assets"));
    assert.ok(assets.some((name) => name.endsWith(".js")));
    assert.ok(assets.some((name) => name.endsWith(".css")));
    console.log(
      "[StaticInlineNode] Vite Wasm fixture passed",
      JSON.stringify({
        node: process.versions.node,
        platform: process.platform,
        vite: packageJSON.version,
      })
    );
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });

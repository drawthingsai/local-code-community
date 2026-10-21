"use strict";

const fs = require("node:fs");
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
assert.equal(childProcess.spawnSync(process.execPath, ["-e", ""]).error.code, "ENOTSUP");
assert.throws(() => childProcess.execFile(process.execPath, ["-e", ""]), { code: "ENOTSUP" });

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.once("end", () => {
  process.stdout.write(
    `${JSON.stringify({
      argument: process.argv[2],
      environment: process.env.VIRTUAL_NODE_CHILD_VALUE,
      line: input.trimEnd(),
      selfProbe: process.kill(process.pid, 0),
    })}\n`
  );
  fs.writeSync(2, "virtual-child-stderr\n");
});

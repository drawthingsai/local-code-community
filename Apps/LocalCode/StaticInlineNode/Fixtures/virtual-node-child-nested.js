"use strict";

const { spawn } = require("node:child_process");
const path = require("node:path");

const child = spawn(
  "node",
  [path.join(__dirname, "virtual-node-child-echo.js"), "nested-argument"],
  {
    cwd: process.cwd(),
    env: {
      ...process.env,
      VIRTUAL_NODE_CHILD_VALUE: "nested-environment",
    },
    stdio: ["pipe", "pipe", "pipe"],
  }
);

let stdout = "";
let stderr = "";
child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => (stdout += chunk));
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => (stderr += chunk));
child.once("error", (error) => {
  console.error(error);
  process.exitCode = 1;
});
child.once("close", (code, signal) => {
  if (code !== 0 || signal !== null) {
    console.error(`nested child failed: code=${code} signal=${signal}`);
    process.exitCode = 1;
    return;
  }
  process.stdout.write(
    `${JSON.stringify({
      child: JSON.parse(stdout),
      stderr,
    })}\n`
  );
});
child.stdin.end("nested-input\n");

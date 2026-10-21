"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const path = require("node:path");

const childMarker = Symbol.for("localcode.virtualNodeChild.child");
const binPath = path.join(__dirname, "virtual-node-child-bin.js");
const echoPath = path.join(__dirname, "virtual-node-child-echo.js");
const nestedPath = path.join(__dirname, "virtual-node-child-nested.js");
const knownFileDescriptorWarnings =
  /^(?:\(node:\d+\) Warning: File descriptor \d+ closed but not opened in unmanaged mode\n(?:\(Use `node --trace-warnings \.\.\.` to show where the warning was created\)\n)?)*$/;
const nativeMarkerPath = path.join(
  __dirname,
  "virtual-node-child-native-marker.js"
);
const waitPath = path.join(__dirname, "virtual-node-child-wait.js");

(async () => {
  const esmChildProcess = await import("node:child_process");
  assert.equal(esmChildProcess.spawn, childProcess.spawn);

  // These internal paths bypass the public virtual spawn override. They must
  // reject before entering libuv or ios_system's virtual waitpid replacement.
  for (const api of [childProcess, esmChildProcess]) {
    assert.equal(api.spawnSync(process.execPath, ["-e", ""]).error.code, "ENOTSUP");
    for (const call of [
      () => api.execFile(process.execPath, ["-e", ""]),
      () => api.exec("true"),
      () => api.execFileSync(process.execPath, ["-e", ""]),
      () => api.execSync("true"),
      () => api.fork(echoPath),
    ]) {
      assert.throws(call, { code: "ENOTSUP" });
    }
  }

  await validatePipesArgumentsEnvironmentAndExit();
  await validateNestedLaunch();
  await validateSimpleShellNodeBin();
  await expectSpawnError("npx", ["--version"], "ENOTSUP");
  await expectSpawnError("/bin/echo", ["not allowed"], "ENOTSUP");
  await expectSpawnError("sh", ["-c", "echo not-allowed"], "EACCES");
  await expectSpawnError(
    "sh",
    ["-c", `${path.basename(binPath)} && echo not-allowed`],
    "ENOTSUP",
    {
      env: {
        ...process.env,
        PATH: `${__dirname}${path.delimiter}${process.env.PATH || ""}`,
      },
    }
  );
  await expectSpawnError("node", [process.execPath], "EACCES");
  await expectSpawnError("node", [nativeMarkerPath], "EACCES");
  await validateCancellation();

  console.log(
    "[StaticInlineNode] virtual Node child fixture passed",
    JSON.stringify({ node: process.versions.node, platform: process.platform })
  );
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

function validatePipesArgumentsEnvironmentAndExit() {
  return new Promise((resolve, reject) => {
    const child = childProcess.spawn("node", [echoPath, "argument-value"], {
      cwd: process.cwd(),
      env: {
        ...process.env,
        VIRTUAL_NODE_CHILD_VALUE: "environment-value",
      },
      stdio: ["pipe", "pipe", "pipe"],
    });

    assert.equal(child[childMarker], true);
    assert.ok(child.pid < 0);
    assert.ok(child.stdin);
    assert.ok(child.stdout);
    assert.ok(child.stderr);

    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.once("error", reject);
    child.once("close", (code, signal) => {
      try {
        assert.equal(code, 0);
        assert.equal(signal, null);
        assert.deepEqual(JSON.parse(stdout), {
          argument: "argument-value",
          environment: "environment-value",
          line: "stdin-value",
          selfProbe: true,
        });
        assert.equal(stderr, "virtual-child-stderr\n");
        resolve();
      } catch (error) {
        reject(error);
      }
    });
    child.stdin.end("stdin-value\n");
  });
}

function validateNestedLaunch() {
  return new Promise((resolve, reject) => {
    const child = childProcess.spawn("node", [nestedPath], {
      cwd: process.cwd(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.once("error", reject);
    child.once("close", (code, signal) => {
      try {
        assert.equal(code, 0);
        assert.equal(signal, null);
        assert.match(stderr, knownFileDescriptorWarnings);
        assert.deepEqual(JSON.parse(stdout), {
          child: {
            argument: "nested-argument",
            environment: "nested-environment",
            line: "nested-input",
            selfProbe: true,
          },
          stderr: "virtual-child-stderr\n",
        });
        resolve();
      } catch (error) {
        reject(error);
      }
    });
  });
}

function validateSimpleShellNodeBin() {
  return new Promise((resolve, reject) => {
    const child = childProcess.spawn(
      "sh",
      ["-c", `${path.basename(binPath)} "shell argument"`],
      {
        env: {
          ...process.env,
          PATH: `${__dirname}${path.delimiter}${process.env.PATH || ""}`,
          VIRTUAL_NODE_SHELL_VALUE: "shell-environment",
        },
        stdio: ["ignore", "pipe", "pipe"],
      }
    );
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.once("error", reject);
    child.once("close", (code, signal) => {
      try {
        assert.equal(code, 0);
        assert.equal(signal, null);
        assert.deepEqual(JSON.parse(stdout), {
          argument: "shell argument",
          environment: "shell-environment",
        });
        assert.match(stderr, knownFileDescriptorWarnings);
        resolve();
      } catch (error) {
        reject(error);
      }
    });
  });
}

function expectSpawnError(command, arguments_, expectedCode, options) {
  return new Promise((resolve, reject) => {
    const child = childProcess.spawn(command, arguments_, options);
    let emittedExit = false;
    let spawnError = null;
    child.once("exit", () => (emittedExit = true));
    child.once("error", (error) => {
      spawnError = error;
    });
    child.once("close", (code, signal) => {
      try {
        assert.ok(spawnError);
        assert.equal(spawnError.code, expectedCode);
        assert.equal(code, -1);
        assert.equal(signal, null);
        assert.equal(emittedExit, false);
        resolve();
      } catch (error) {
        reject(error);
      }
    });
  });
}

function validateCancellation() {
  return new Promise((resolve, reject) => {
    const child = childProcess.spawn("node", [waitPath], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    child.once("error", reject);
    child.stdout.setEncoding("utf8");
    child.stdout.once("data", (message) => {
      try {
        assert.equal(message, "ready\n");
        assert.equal(child.kill(0), true);
        assert.equal(child.killed, false);
        assert.throws(() => child.kill("SIGUSR1"), /Unknown signal/);
        assert.equal(child.killed, false);
        assert.equal(child.kill("SIGTERM"), true);
        assert.equal(child.killed, true);
      } catch (error) {
        reject(error);
      }
    });
    child.once("close", (code, signal) => {
      try {
        assert.equal(code, null);
        assert.equal(signal, "SIGTERM");
        resolve();
      } catch (error) {
        reject(error);
      }
    });
  });
}

"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const os = require("node:os");
const { Worker, isMainThread, workerData } = require("node:worker_threads");
const missingExecutable = "/nonexistent-localcode-process-policy";
const unsupported = -os.constants.errno.ENOTSUP;

async function validatePolicy() {
  const esmChildProcess = await import("node:child_process");
  for (const api of [childProcess, esmChildProcess]) {
    const result = api.spawnSync(missingExecutable, [], { input: "unread" });
    assert.equal(result.error.code, "ENOTSUP");
    assert.equal(result.status, null);
    assert.equal(result.signal, null);
    assert.equal(result.pid, 0);
    for (const call of [
      () => api.exec(missingExecutable),
      () => api.execFile(missingExecutable),
      () => api.execSync(missingExecutable),
      () => api.execFileSync(missingExecutable),
      () => api.fork(__filename),
    ]) {
      assert.throws(call, { code: "ENOTSUP" });
    }
    await new Promise((resolve, reject) => {
      // The virtual spawn API emits an error; Node's native API can throw it.
      try {
        const child = api.spawn(missingExecutable);
        child.once("error", (error) => {
          try {
            assert.equal(error.code, "ENOTSUP");
            resolve();
          } catch (failure) { reject(failure); }
        });
        child.once("spawn", () => reject(new Error("Native process started")));
      } catch (error) {
        try {
          assert.equal(error.code, "ENOTSUP");
          resolve();
        } catch (failure) { reject(failure); }
      }
    });
  }

  // Bypassing public exports still reaches the same native rejection.
  const handle = new (process.binding("process_wrap").Process)();
  assert.equal(handle.spawn({}), unsupported);
  assert.equal(handle.kill(0), unsupported);
  handle.close();
  assert.equal(process.binding("spawn_sync").spawn({}).error, unsupported);

  assert.equal(typeof process.execve, "function");
  // Node already rejects execve in Workers before entering the native binding.
  assert.throws(() => process.execve(missingExecutable, ["probe"], {}), {
    code: isMainThread ? "ENOTSUP" : "ERR_WORKER_UNSUPPORTED_OPERATION",
  });
  assert.equal(process.kill(process.pid, 0), true);
  assert.throws(() => process.kill(process.pid, "SIGTERM"), { code: "ENOTSUP" });
  assert.equal(process._kill(process.pid, os.constants.signals.SIGTERM), unsupported);
}

function validateWorker(options) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(__filename, options);
    worker.once("error", reject);
    worker.once("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`Policy worker exited with ${code}`));
    });
  });
}

(async () => {
  await validatePolicy();
  if (isMainThread) {
    await validateWorker({ workerData: { nested: false } });
    await validateWorker({ execArgv: [], workerData: { nested: true } });
    await validateWorker({ execArgv: [], env: {}, workerData: { nested: false } });
    console.log("[StaticInlineNode] native process policy passed");
  } else if (workerData.nested) {
    await validateWorker({ execArgv: [], workerData: { nested: false } });
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

"use strict";

// This file is the entry point for a disposable Node worker. The parent-side
// preload validates the requested script and constructs this worker with
// process-like stdio and a private environment before any project code runs.

const Module = require("node:module");
const fs = require("node:fs");
const os = require("node:os");
const { workerData } = require("node:worker_threads");

if (
  workerData === null ||
  typeof workerData !== "object" ||
  typeof workerData.entryPath !== "string" ||
  !Array.isArray(workerData.arguments) ||
  workerData.environment === null ||
  typeof workerData.environment !== "object"
) {
  throw new TypeError("Invalid virtual Node child worker data");
}

if (workerData.cwd !== process.cwd()) {
  const error = new Error(
    `Virtual Node children cannot change working directory from ${process.cwd()} to ${workerData.cwd}`
  );
  error.code = "ENOTSUP";
  throw error;
}

for (const key of Object.keys(process.env)) delete process.env[key];
Object.assign(process.env, workerData.environment);

// NODE_OPTIONS is deliberately removed from the worker environment by the
// parent. Install the bridge explicitly after restoring the command
// environment so nested Node children inherit the same controlled roots.
require("./virtual-node-child-preload.cjs");

process.argv = [process.execPath, workerData.entryPath, ...workerData.arguments];
installStandardDescriptors();

// A Worker shares the host process ID. Never let child code use that ID to
// signal the app process. Exiting the current virtual child remains safe.
process.kill = (pid, signal = "SIGTERM") => {
  if (pid !== process.pid) {
    const error = new Error(`Virtual Node children cannot signal process ${pid}`);
    error.code = "ENOTSUP";
    error.errno = -45;
    error.syscall = `kill ${pid}`;
    throw error;
  }
  if (signal === 0) return true;

  const signalExitCodes = {
    SIGHUP: 129,
    SIGINT: 130,
    SIGQUIT: 131,
    SIGKILL: 137,
    SIGTERM: 143,
  };
  if (typeof signal === "number") {
    signal = Object.entries(os.constants.signals).find(
      ([, number]) => number === signal
    )?.[0];
  } else if (typeof signal === "string") {
    signal = signal.toUpperCase();
  }
  if (signalExitCodes[signal] === undefined) {
    throw new TypeError(`Unknown signal: ${signal}`);
  }
  process.exit(signalExitCodes[signal]);
};

// runMain preserves Node's CommonJS/ESM and extensionless-bin loading rules.
// The worker event loop then remains alive for the launched program exactly as
// it would for a standalone Node invocation.
Module.runMain();

function installStandardDescriptors() {
  defineFileDescriptor(process.stdin, 0);
  defineFileDescriptor(process.stdout, 1);
  defineFileDescriptor(process.stderr, 2);

  const originalRead = fs.read;
  const originalWrite = fs.write;
  const originalWriteSync = fs.writeSync;
  const chunks = [];
  const reads = [];
  let ended = false;
  let inputError = null;
  let isReading = false;

  fs.read = function virtualStandardInputRead(
    descriptor,
    buffer,
    offset,
    length,
    position,
    callback
  ) {
    if (descriptor !== 0) {
      return originalRead.apply(this, arguments);
    }
    if (typeof callback !== "function") {
      throw new TypeError("fs.read callback must be a function");
    }
    reads.push({ buffer, callback, length, offset });
    startReading();
    drainReads();
  };

  fs.write = function virtualStandardOutputWrite(descriptor, data) {
    if (descriptor !== 1 && descriptor !== 2) {
      return originalWrite.apply(this, arguments);
    }
    const callback = [...arguments]
      .reverse()
      .find((argument) => typeof argument === "function");
    if (callback === undefined) {
      throw new TypeError("fs.write callback must be a function");
    }

    const stream = descriptor === 1 ? process.stdout : process.stderr;
    if (ArrayBuffer.isView(data)) {
      const buffer = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
      const offset = typeof arguments[2] === "number" ? arguments[2] : 0;
      const length =
        typeof arguments[3] === "number" ? arguments[3] : buffer.length - offset;
      const chunk = buffer.subarray(offset, offset + length);
      stream.write(chunk, (error) =>
        callback(error || null, error ? 0 : chunk.length, data)
      );
      return;
    }

    const string = String(data);
    const encoding = [...arguments]
      .slice(2, -1)
      .find((argument) => typeof argument === "string");
    const bytesWritten = Buffer.byteLength(string, encoding);
    stream.write(string, encoding, (error) =>
      callback(error || null, error ? 0 : bytesWritten, string)
    );
  };

  fs.writeSync = function virtualStandardOutputWriteSync(descriptor, data) {
    if (descriptor !== 1 && descriptor !== 2) {
      return originalWriteSync.apply(this, arguments);
    }

    const stream = descriptor === 1 ? process.stdout : process.stderr;
    if (ArrayBuffer.isView(data)) {
      const buffer = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
      const offset = typeof arguments[2] === "number" ? arguments[2] : 0;
      const length =
        typeof arguments[3] === "number" ? arguments[3] : buffer.length - offset;
      const chunk = buffer.subarray(offset, offset + length);
      stream.write(chunk);
      return chunk.length;
    }

    const string = String(data);
    const encoding = [...arguments]
      .slice(2)
      .find((argument) => typeof argument === "string");
    stream.write(string, encoding);
    return Buffer.byteLength(string, encoding);
  };

  function startReading() {
    if (isReading) return;
    isReading = true;
    process.stdin.on("data", (chunk) => {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
      drainReads();
    });
    process.stdin.once("end", () => {
      ended = true;
      drainReads();
      process.stdin.destroy();
    });
    process.stdin.once("error", (error) => {
      inputError = error;
      drainReads();
    });
  }

  function drainReads() {
    while (reads.length > 0) {
      if (inputError !== null) {
        const read = reads.shift();
        process.nextTick(read.callback, inputError, 0, read.buffer);
        continue;
      }
      if (chunks.length === 0) {
        if (ended) {
          const read = reads.shift();
          process.nextTick(read.callback, null, 0, read.buffer);
          continue;
        }
        return;
      }

      const read = reads.shift();
      let bytesRead = 0;
      while (bytesRead < read.length && chunks.length > 0) {
        const chunk = chunks[0];
        const count = Math.min(read.length - bytesRead, chunk.length);
        chunk.copy(read.buffer, read.offset + bytesRead, 0, count);
        bytesRead += count;
        if (count === chunk.length) {
          chunks.shift();
        } else {
          chunks[0] = chunk.subarray(count);
        }
      }
      process.nextTick(read.callback, null, bytesRead, read.buffer);
    }
  }
}

function defineFileDescriptor(stream, descriptor) {
  if (stream.fd !== undefined) return;
  Object.defineProperty(stream, "fd", {
    configurable: true,
    enumerable: true,
    value: descriptor,
  });
}

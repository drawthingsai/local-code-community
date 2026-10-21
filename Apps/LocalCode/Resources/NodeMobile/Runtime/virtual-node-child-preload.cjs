"use strict";

// NodeMobile cannot create OS processes on iOS. This preload implements the
// intentionally smaller operation Local Code needs for frontend tooling:
//
//   spawn("node", [projectLocalScript, ...arguments], options)
//   spawn("npx", [...arguments], options)
//   spawn("sh", ["-c", "projectLocalNodeBin arguments"], options)
//
// Each accepted launch runs in a disposable Worker with piped stdio. It is a
// generic Node-script bridge; package substitutions such as esbuild-wasm live
// in the project's node_modules tree and are not named here. The shell-shaped
// form is parsed without executing a shell and accepts only a verified Node
// shebang entry inside an allowed project root. The npx-shaped form runs the
// exact upstream JavaScript entry configured by ios_system.

const childProcess = require("node:child_process");
const fs = require("node:fs");
const Module = require("node:module");
const os = require("node:os");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const { Worker } = require("node:worker_threads");

const installationMarker = Symbol.for("localcode.virtualNodeChild.installed");
const childMarker = Symbol.for("localcode.virtualNodeChild.child");
const portReferenceStates = new WeakMap();

if (!childProcess[installationMarker]) {
  const bootstrapPath = path.join(
    __dirname,
    "virtual-node-child-bootstrap.cjs"
  );
  const allowedRoots = resolveAllowedRoots();
  const npxCLI = resolveNPXCLI();
  let nextIdentifier = 1;

  class VirtualNodeChild extends EventEmitter {
    constructor(command, spawnArguments, options, launch) {
      super();

      this[childMarker] = true;
      this.channel = null;
      this.connected = false;
      this.exitCode = null;
      this.killed = false;
      this.pid = -nextIdentifier++;
      this.signalCode = null;
      this.spawnargs = [command, ...spawnArguments];
      this.spawnfile = command;
      this.stderr = null;
      this.stdin = null;
      this.stdio = [null, null, null];
      this.stdout = null;
      this._closed = false;
      this._forcedSignal = null;
      this._timeout = null;
      this._worker = null;

      if (launch.error) {
        process.nextTick(() => {
          this.emit("error", launch.error);
          this._close(-1, null, false);
        });
        return;
      }

      let worker;
      try {
        worker = new Worker(bootstrapPath, {
          argv: [],
          stdin: true,
          stdout: true,
          stderr: true,
          workerData: {
            arguments: launch.arguments,
            cwd: launch.cwd,
            entryPath: launch.entryPath,
            environment: workerEnvironment(
              options.env || process.env,
              allowedRoots,
              npxCLI
            ),
          },
        });
      } catch (error) {
        process.nextTick(() => {
          this.emit("error", spawnError(command, error.code || "EIO", error.message));
          this._close(-1, null, false);
        });
        return;
      }

      this._worker = worker;
      this.pid = -worker.threadId;
      this._configureStdio(worker, launch.stdio);

      worker.once("online", () => this.emit("spawn"));
      worker.once("error", (error) => {
        this.emit("error", spawnError(command, error.code || "EIO", error.message));
      });
      worker.once("exit", (code) => {
        const signal = this._forcedSignal;
        this._close(signal === null ? code : null, signal);
      });

      if (options.signal) {
        const abort = () => this.kill("SIGTERM");
        if (options.signal.aborted) {
          process.nextTick(abort);
        } else {
          options.signal.addEventListener("abort", abort, { once: true });
          this.once("close", () =>
            options.signal.removeEventListener("abort", abort)
          );
        }
      }

      if (options.timeout > 0) {
        this._timeout = setTimeout(
          () => this.kill(options.killSignal || "SIGTERM"),
          options.timeout
        );
        this._timeout.unref();
      }
    }

    _configureStdio(worker, stdio) {
      if (stdio[0] === "pipe") {
        this.stdin = addReferenceMethods(worker.stdin);
        this.stdio[0] = this.stdin;
      } else if (stdio[0] === "inherit") {
        addReferenceMethods(worker.stdin);
        process.stdin.pipe(worker.stdin);
        this.once("close", () => process.stdin.unpipe(worker.stdin));
      } else {
        addReferenceMethods(worker.stdin).unref();
        worker.stdin.end();
      }

      if (stdio[1] === "pipe") {
        this.stdout = addReferenceMethods(worker.stdout);
        this.stdio[1] = this.stdout;
      } else if (stdio[1] === "inherit") {
        addReferenceMethods(worker.stdout).unref();
        worker.stdout.pipe(process.stdout, { end: false });
      } else {
        addReferenceMethods(worker.stdout).unref();
        worker.stdout.resume();
      }

      if (stdio[2] === "pipe") {
        this.stderr = addReferenceMethods(worker.stderr);
        this.stdio[2] = this.stderr;
      } else if (stdio[2] === "inherit") {
        addReferenceMethods(worker.stderr).unref();
        worker.stderr.pipe(process.stderr, { end: false });
      } else {
        addReferenceMethods(worker.stderr).unref();
        worker.stderr.resume();
      }
    }

    _close(code, signal, emitExit = true) {
      if (this._closed) return;
      this._closed = true;
      if (this._timeout !== null) clearTimeout(this._timeout);
      this.exitCode = code;
      this.signalCode = signal;
      if (emitExit) this.emit("exit", code, signal);
      process.nextTick(() => this.emit("close", code, signal));
    }

    kill(signal = "SIGTERM") {
      if (this._closed || this._worker === null) return false;
      if (signal === 0) return true;
      const normalizedSignal = normalizeSignal(signal);
      this.killed = true;
      this._forcedSignal = normalizedSignal;
      void this._worker.terminate();
      return true;
    }

    ref() {
      if (this._worker !== null) this._worker.ref();
      return this;
    }

    unref() {
      if (this._worker !== null) this._worker.unref();
      return this;
    }
  }

  function virtualSpawn(command, argumentsOrOptions, maybeOptions) {
    let spawnArguments = [];
    let options = {};
    if (Array.isArray(argumentsOrOptions)) {
      spawnArguments = argumentsOrOptions.map(String);
      options = maybeOptions || {};
    } else if (argumentsOrOptions !== undefined) {
      options = argumentsOrOptions || {};
    }

    const launch = validateLaunch(
      command,
      spawnArguments,
      options,
      allowedRoots,
      npxCLI
    );
    return new VirtualNodeChild(String(command), spawnArguments, options, launch);
  }

  Object.defineProperty(virtualSpawn, "name", { value: "spawn" });
  childProcess.spawn = virtualSpawn;
  childProcess[installationMarker] = Object.freeze({
    allowedRoots: [...allowedRoots],
    bootstrapPath,
    childMarker,
  });

  // Update named exports already materialized by node:child_process ESM.
  Module.syncBuiltinESMExports();
}

module.exports = childProcess[installationMarker];

function resolveAllowedRoots() {
  const configured = process.env.NODE_MOBILE_VIRTUAL_NODE_ROOTS;
  const roots = configured ? configured.split(path.delimiter) : [process.cwd()];
  const resolved = [];
  for (const root of roots) {
    if (!root) continue;
    try {
      const candidate = fs.realpathSync(path.resolve(root));
      if (!resolved.includes(candidate)) resolved.push(candidate);
    } catch {
      // A missing root grants no access.
    }
  }
  return resolved;
}

function resolveNPXCLI() {
  const configured = process.env.NODE_MOBILE_NPX_CLI;
  if (!configured) return null;
  try {
    const candidate = fs.realpathSync(path.resolve(configured));
    if (!fs.statSync(candidate).isFile() || isNativeExecutable(candidate)) {
      return null;
    }
    return candidate;
  } catch {
    return null;
  }
}

function workerEnvironment(environment, allowedRoots, npxCLI) {
  const result = {};
  for (const [key, value] of Object.entries(environment)) {
    if (
      key !== "NODE_OPTIONS" &&
      key !== "NODE_MOBILE_NPX_CLI" &&
      key !== "NODE_MOBILE_VIRTUAL_NODE_ROOTS" &&
      value !== undefined
    ) {
      result[key] = String(value);
    }
  }
  result.NODE_MOBILE_VIRTUAL_NODE_ROOTS = allowedRoots.join(path.delimiter);
  if (npxCLI !== null) result.NODE_MOBILE_NPX_CLI = npxCLI;
  return result;
}

function addReferenceMethods(stream) {
  const portSymbol = Object.getOwnPropertySymbols(stream).find(
    (symbol) => symbol.description === "kPort"
  );
  const port = portSymbol === undefined ? null : stream[portSymbol];
  if (port === null || typeof port.ref !== "function") return stream;

  let state = portReferenceStates.get(port);
  if (state === undefined) {
    const originalRef = port.ref.bind(port);
    state = { originalRef, streams: new Set() };
    portReferenceStates.set(port, state);
    port.ref = function virtualStdioPortRef() {
      if ([...state.streams].some((item) => item.referenced)) originalRef();
      return this;
    };
  }
  const streamState = { referenced: true };
  state.streams.add(streamState);

  Object.defineProperties(stream, {
    ref: {
      configurable: true,
      value() {
        streamState.referenced = true;
        state.originalRef();
        return this;
      },
    },
    unref: {
      configurable: true,
      value() {
        streamState.referenced = false;
        if (![...state.streams].some((item) => item.referenced)) port.unref();
        return this;
      },
    },
  });
  return stream;
}

function validateLaunch(
  command,
  spawnArguments,
  options,
  allowedRoots,
  npxCLI
) {
  const commandString = String(command);
  let effectiveArguments = spawnArguments;
  const isNodeCommand =
    commandString === "node" || commandString === process.execPath;
  const isNPXCommand = commandString === "npx";
  const isShellCommand =
    commandString === "sh" ||
    commandString === "/bin/sh" ||
    commandString === "/usr/bin/sh";
  if (!isNodeCommand && !isNPXCommand && !isShellCommand) {
    return {
      error: spawnError(
        commandString,
        "ENOTSUP",
        "only direct Node script children are supported"
      ),
    };
  }

  const unsupportedOption = ["detached", "gid", "shell", "uid"].find(
    (key) => options[key] !== undefined && options[key] !== false
  );
  if (unsupportedOption) {
    return {
      error: spawnError(
        commandString,
        "ENOTSUP",
        `spawn option ${unsupportedOption} is not supported`
      ),
    };
  }

  let cwd;
  try {
    cwd = fs.realpathSync(path.resolve(options.cwd || process.cwd()));
  } catch (error) {
    return { error: spawnError(commandString, error.code || "ENOENT", error.message) };
  }
  if (cwd !== process.cwd()) {
    return {
      error: spawnError(
        commandString,
        "ENOTSUP",
        "virtual Node children currently require the parent working directory"
      ),
    };
  }

  if (isNPXCommand) {
    if (npxCLI === null) {
      return {
        error: spawnError(
          commandString,
          "ENOTSUP",
          "the bundled npx JavaScript entry is not configured"
        ),
      };
    }
    effectiveArguments = [npxCLI, ...spawnArguments];
  } else if (isShellCommand) {
    if (spawnArguments.length !== 2 || spawnArguments[0] !== "-c") {
      return {
        error: spawnError(
          commandString,
          "ENOTSUP",
          "only a simple shell command resolving to a Node script is supported"
        ),
      };
    }
    let shellArguments;
    try {
      shellArguments = parseSimpleShellCommand(spawnArguments[1]);
    } catch (error) {
      return { error: spawnError(commandString, "ENOTSUP", error.message) };
    }
    if (
      shellArguments[0] === "node" ||
      shellArguments[0] === process.execPath
    ) {
      effectiveArguments = shellArguments.slice(1);
    } else {
      let executablePath;
      try {
        executablePath = resolveNodeShebangCommand(
          shellArguments[0],
          cwd,
          options.env || process.env,
          allowedRoots
        );
      } catch (error) {
        return {
          error: spawnError(
            commandString,
            error.code || "ENOTSUP",
            error.message
          ),
        };
      }
      effectiveArguments = [executablePath, ...shellArguments.slice(1)];
    }
  }

  if (
    effectiveArguments.length === 0 ||
    effectiveArguments[0].startsWith("-")
  ) {
    return {
      error: spawnError(
        commandString,
        "ENOTSUP",
        "a direct JavaScript entry path must be the first argument"
      ),
    };
  }

  let entryPath;
  try {
    entryPath = fs.realpathSync(path.resolve(cwd, effectiveArguments[0]));
    if (!fs.statSync(entryPath).isFile()) {
      return {
        error: spawnError(commandString, "EACCES", "entry path is not a file"),
      };
    }
  } catch (error) {
    return { error: spawnError(commandString, error.code || "ENOENT", error.message) };
  }

  if (
    entryPath !== npxCLI &&
    !allowedRoots.some((root) => isWithin(root, entryPath))
  ) {
    return {
      error: spawnError(
        commandString,
        "EACCES",
        `entry path is outside NODE_MOBILE_VIRTUAL_NODE_ROOTS: ${entryPath}`
      ),
    };
  }

  if (isNativeExecutable(entryPath)) {
    return {
      error: spawnError(
        commandString,
        "EACCES",
        `native executable payloads are not supported: ${entryPath}`
      ),
    };
  }

  let stdio;
  try {
    stdio = normalizeStdio(options.stdio);
  } catch (error) {
    return { error: spawnError(commandString, "ENOTSUP", error.message) };
  }

  return {
    arguments: effectiveArguments.slice(1),
    cwd,
    entryPath,
    stdio,
  };
}

function parseSimpleShellCommand(source) {
  const words = [];
  let current = "";
  let quote = null;
  let escaped = false;
  let started = false;
  const push = () => {
    if (!started) return;
    words.push(current);
    current = "";
    started = false;
  };

  for (const character of String(source)) {
    if (escaped) {
      current += character;
      escaped = false;
      started = true;
      continue;
    }
    if (quote === "'") {
      if (character === "'") quote = null;
      else current += character;
      started = true;
      continue;
    }
    if (quote === '"') {
      if (character === '"') {
        quote = null;
      } else if (character === "\\") {
        escaped = true;
      } else {
        if (character === "$" || character === "`") {
          throw new Error("shell expansion is not supported");
        }
        current += character;
      }
      started = true;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      started = true;
    } else if (character === "'" || character === '"') {
      quote = character;
      started = true;
    } else if (/\s/u.test(character)) {
      push();
    } else {
      if (";&|<>()$`".includes(character)) {
        throw new Error("shell operators and expansion are not supported");
      }
      current += character;
      started = true;
    }
  }
  if (escaped || quote !== null) {
    throw new Error("unterminated shell quoting is not supported");
  }
  push();
  if (words.length === 0) {
    throw new Error("an empty shell command is not supported");
  }
  if (/^[A-Za-z_][A-Za-z0-9_]*=/u.test(words[0])) {
    throw new Error("shell environment assignments are not supported");
  }
  return words;
}

function resolveNodeShebangCommand(command, cwd, environment, allowedRoots) {
  const candidates = [];
  if (command.includes(path.sep)) {
    candidates.push(path.resolve(cwd, command));
  } else {
    const searchPath =
      environment && environment.PATH !== undefined
        ? String(environment.PATH)
        : process.env.PATH || "";
    for (const directory of searchPath.split(path.delimiter)) {
      if (directory) candidates.push(path.resolve(cwd, directory, command));
    }
  }

  for (const candidate of candidates) {
    let entryPath;
    try {
      entryPath = fs.realpathSync(candidate);
      if (!fs.statSync(entryPath).isFile()) continue;
    } catch {
      continue;
    }
    if (!allowedRoots.some((root) => isWithin(root, entryPath))) {
      const error = new Error(
        `entry path is outside NODE_MOBILE_VIRTUAL_NODE_ROOTS: ${entryPath}`
      );
      error.code = "EACCES";
      throw error;
    }
    if (isNativeExecutable(entryPath)) {
      const error = new Error(
        `native executable payloads are not supported: ${entryPath}`
      );
      error.code = "EACCES";
      throw error;
    }
    const firstLine = fs
      .readFileSync(entryPath, { encoding: "utf8" })
      .split(/\r?\n/u, 1)[0];
    if (
      !/^#!\s*(?:(?:\/usr\/bin\/env)(?:\s+-S)?\s+|(?:\S*\/))?node(?:\s|$)/u.test(
        firstLine
      )
    ) {
      const error = new Error(
        `shell command is not a Node shebang entry: ${entryPath}`
      );
      error.code = "ENOTSUP";
      throw error;
    }
    return entryPath;
  }

  const error = new Error(`command was not found on PATH: ${command}`);
  error.code = "ENOENT";
  throw error;
}

function normalizeStdio(value) {
  const stdio = value === undefined ? ["pipe", "pipe", "pipe"] :
    typeof value === "string" ? [value, value, value] : [...value];
  while (stdio.length < 3) stdio.push("ignore");
  for (let index = 0; index < 3; ++index) {
    if (stdio[index] === index) stdio[index] = "inherit";
    if (!["ignore", "inherit", "pipe"].includes(stdio[index])) {
      throw new TypeError(`stdio[${index}] must be pipe, inherit, or ignore`);
    }
  }
  return stdio.slice(0, 3);
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative === "" ||
    (relative !== ".." &&
      !relative.startsWith(`..${path.sep}`) &&
      !path.isAbsolute(relative))
  );
}

function isNativeExecutable(filename) {
  if (path.extname(filename) === ".node") return true;
  const descriptor = fs.openSync(filename, "r");
  const magic = Buffer.alloc(4);
  try {
    fs.readSync(descriptor, magic, 0, magic.length, 0);
  } finally {
    fs.closeSync(descriptor);
  }

  const value = magic.readUInt32BE(0);
  return (
    value === 0x7f454c46 || // ELF
    value === 0xfeedface ||
    value === 0xfeedfacf ||
    value === 0xcefaedfe ||
    value === 0xcffaedfe ||
    value === 0xcafebabe ||
    value === 0xcafebabf ||
    value === 0xbebafeca ||
    value === 0xbfbafeca ||
    (magic[0] === 0x4d && magic[1] === 0x5a) // PE
  );
}

function normalizeSignal(signal) {
  const supportedSignals = new Set([
    "SIGHUP",
    "SIGINT",
    "SIGKILL",
    "SIGQUIT",
    "SIGTERM",
  ]);
  if (typeof signal === "number") {
    signal = Object.entries(os.constants.signals).find(
      ([, number]) => number === signal
    )?.[0];
  } else if (typeof signal === "string") {
    signal = signal.toUpperCase();
  }
  if (!supportedSignals.has(signal)) {
    throw new TypeError(`Unknown signal: ${signal}`);
  }
  return signal;
}

function spawnError(command, code, detail) {
  const error = new Error(`spawn ${command} ${code}: ${detail}`);
  error.code = code;
  error.path = command;
  error.spawnargs = [];
  error.syscall = `spawn ${command}`;
  return error;
}

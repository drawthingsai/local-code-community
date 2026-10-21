# ccv explicit-fork integration

The implementation is now pinned to s4nnc
`e93b9ae39bd73ad90a0877950800d90152f8e433` and ccv
`3d0edb047483a5f99dc67659e1ffcf26e28e81e8`. Both SwiftPM and Bazel use
these committed dependencies; the local checkout overrides have been removed.

Ordinary MPS callers continue to use the global pending command buffer, MFA
context, and MPSGraph executable cache. `ccv_nnc_fork()` explicitly detaches the
calling thread, giving it fresh command-buffer state and its own MFA context and
MPSGraph cache. That includes scratch, shader caches, indirect command buffers,
and ANE execution buffers. No pending commands or mutable buffers are copied.

The existing command-packing thresholds, `buffer_lock`, and checked-out TLS
remain. The Metal device, Metal queue, and global in-flight throttling remain
shared. A detached thread retains its own completion fence so another caller's
wait cannot discard its completion tracking.

## Lifetime and threading contract

- Call `ccv_nnc_fork()` before independent GPU execution, outside active encoding.
- It returns 1 for a new fork, 0 if already detached (or MPS is unavailable).
- A fork belongs to its native thread. It does not propagate through Dispatch,
  child threads, or work transferred to another execution owner.
- Synchronize any tensor dependencies before transferring them between owners.
- Dedicated threads can rely on the pthread destructor: it flushes pending work,
  waits for completion, and releases private buffers and caches.
- `ccv_nnc_join()` performs the same cleanup explicitly and restores default
  execution. Balance only a fork that returned 1.
- Default execution retains its existing serialization requirements. This API
  does not make simultaneous non-forked callers independent.

s4nnc exposes `DynamicGraph.fork { ... }` for synchronous scopes. It balances
cleanup on normal return and thrown errors; nested calls preserve the outer
fork. Dedicated C callers can use `ccv_nnc_fork()` with thread-exit cleanup. A Dispatch block must finish its GPU work before returning, rather
than leaving pending commands for a future block on another worker.

## Local Code / CLI integration

`DrawThingsCLI.run` scopes command execution in a fork. The generation
`queue.sync` block scopes its own fork because Dispatch can select a different
worker. If it executes on the existing detached thread, it reuses that fork.
The CLI inputs to generation are CPU tensors; outputs are materialized before
the generation scope returns. Existing text execution uses the default state.
The previous queue-registration API and call sites have been removed.

Bash refresh/timeout behavior and local-versus-remote text model unload policy
remain unchanged. Forking itself does not unload a model.

## Build and validation

From the draw-things checkout, using the committed dependency pins:

```sh
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

In the ccv checkout:

```sh
cd test/int/nnc
make -j8 mps.thread.tests
./mps.thread.tests
```

Focused regressions cover default-versus-forked producer ordering, isolated MFA
scratch/caches, concurrent numerical results across shape changes (MFA and
MPSGraph paths), unchanged default state across queue worker migration,
idempotent fork/default-state restoration, scoped Dispatch execution, and
thread-exit flushing of pending work.

Validation of the committed dependencies passed:

- Nine focused ccv fork regressions, including automatic pthread cleanup and
  callbacks after default execution has already waited for detached work.
- SwiftPM dependency resolution; only the two requested lockfile pins changed.
- `swift build --target NNC --force-resolved-versions`.
- `bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64`, without local
  dependency overrides. The downloaded backend/API sources match the pins.
- `git diff --check`.

The earlier prototype also passed 277 MPS BLAS tests and 126 MPS neural-network
tests. The thread-destructor regression caught native TLS being reset before
pthread cleanup; cleanup restores the explicit registered state before flushing.

The previous queue-owned prototype passed the user's app trial; the committed
explicit-fork version still needs an overlapping text/image generation app trial.

import Darwin
import Foundation
import LLM
import NNC

/// Run with a materialized Qwen 3.5 checkpoint path and optional "9b" argument.
/// Use 4B without MTP and 9B with MTP to cover shared drafter parameters.
/// Checks continuation from
/// the same KV state before/after unloading through a copy of the generator.
@main
private struct TextGeneratorUnloadProbe {
  static func memoryUsage() -> (footprint: UInt64, resident: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    precondition(status == KERN_SUCCESS)
    return (info.phys_footprint, info.resident_size)
  }

  static func main() {
    precondition(
      CommandLine.arguments.count == 2
        || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "9b"),
      "Pass a Qwen 3.5 checkpoint path, optionally followed by 9b")
    let is9B = CommandLine.arguments.count == 3
    var generator = Qwen3_5TextGenerator(
      filePath: CommandLine.arguments[1], configuration: is9B ? .qwen3_5_9B : .qwen3_5_4B,
      tieEmbedding: !is9B,
      chunkedPrefillMaxLength: 2_048)
    let sharedCopy = generator
    let graph = DynamicGraph()
    let stream = StreamContext(.GPU(0))
    var kvCache = [DynamicGraph.AnyTensor]()
    var draftCache = [DynamicGraph.AnyTensor]()
    let contextCache = Qwen3_5ContextCache(projectPath: nil, checkpointStride: 2_048)
    let tokens = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: "<|im_start|>user\nSay hello.<|im_end|>\n<|im_start|>assistant\n",
      truncation: false, maxLength: 0
    ).1

    func decode(
      _ input: [Int32], offset: Int, context: [Int32], onPrefill: (() -> Void)? = nil
    ) -> [Int32] {
      graph.withStream(stream) {
        graph.withNoGrad {
          generator.decode(
            graph: graph, tokens: graph.variable(Tensor<Int32>(input).toGPU(0)),
            tokenOffset: offset, thinkingBudget: 0, kvCache: &kvCache,
            draftCache: &draftCache, contextTokens: context, contextCache: contextCache
          ) { completed, total, _, _ in
            guard completed == total else { return .continue }
            onPrefill?()
            return .pause
          }
        }
      }
    }

    let first = decode(tokens, offset: 0, context: tokens)
    precondition(first.count == 1)
    let snapshot = graph.withNoGrad {
      generator.cacheSnapshot(kvCache: kvCache, draftCache: draftCache)
    }
    let expected = decode(first, offset: tokens.count, context: tokens + first)
    precondition(expected.count == 1)
    kvCache = snapshot.kvCache
    draftCache = snapshot.draftCache
    stream.joined()
    let before = memoryUsage()
    let unloaded = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      sharedCopy.unload()
      unloaded.signal()
    }
    // Keep the same DynamicGraph active on its owner while model-only teardown
    // runs elsewhere. Temporary graph tensors must still be released here.
    graph.withNoGrad {
      for _ in 0..<1_000 {
        let tensor = graph.variable(Tensor<Float>([1, 2, 3]))
        precondition(tensor.rawValue[0] == 1)
      }
    }
    precondition(unloaded.wait(timeout: .now() + 30) == .success)
    let after = memoryUsage()
    print("Footprint before unload: \(before.footprint); after: \(after.footprint) bytes")
    print("Resident memory before unload: \(before.resident); after: \(after.resident) bytes")
    let actual = decode(first, offset: tokens.count, context: tokens + first)
    precondition(
      actual == expected, "Continuation changed after unload/reload: \(actual) vs \(expected)")

    let nextSnapshot = graph.withNoGrad {
      generator.cacheSnapshot(kvCache: kvCache, draftCache: draftCache)
    }
    let nextContext = tokens + first + actual
    let expectedNext = decode(actual, offset: tokens.count + first.count, context: nextContext)
    kvCache = nextSnapshot.kvCache
    draftCache = nextSnapshot.draftCache
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let overlapping = decode(
      actual, offset: tokens.count + first.count, context: nextContext,
      onPrefill: {
        // Match Qwen's early tool launch: the unload request arrives from a
        // worker before the decoder continuation has returned.
        DispatchQueue.global().async {
          started.signal()
          sharedCopy.unload()
          finished.signal()
        }
        precondition(started.wait(timeout: .now() + 30) == .success)
        precondition(finished.wait(timeout: .now() + 0.1) == .timedOut)
      })
    // This is the generation-side tool wait. Unload must complete without
    // dispatching back onto the thread that is waiting for it here.
    precondition(finished.wait(timeout: .now() + 30) == .success)
    precondition(overlapping == expectedNext)
    let resumed = decode(
      overlapping, offset: nextContext.count, context: nextContext + overlapping)
    precondition(resumed.count == 1)
    generator.unload()
    sharedCopy.unload()
    print("Cross-thread reset, decode exclusion, and continuation reload passed: \(actual)")
  }
}

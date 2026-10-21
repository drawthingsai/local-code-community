import LLM
import NNC

/// Caller-owned decoded rows. A worker gets a value copy for one read batch and
/// returns it after completion; the file reader itself has no mutable cache.
struct DeepSeek4_1EngramCache {
  let capacity: Int
  private var cachedRows = [Int32: Tensor<Float16>]()
  private var order = [Int32]()
  private var nextIndex = 0

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  mutating func read(reader: DeepSeek4_1EngramReader<Float16>, layerIndex: Int, rows: [Int32])
    -> Tensor<Float16>
  {
    let width = DeepSeek4_1EngramConfiguration.deepSeekV4_1Flash.headDim
    var decoded = [Int32: Tensor<Float16>]()
    var missing = [Int32]()
    var missingIndices = [Int32: Int]()
    var seen = Set<Int32>()
    for row in rows where seen.insert(row).inserted {
      if let cached = cachedRows[row] {
        decoded[row] = cached
      } else {
        missingIndices[row] = missing.count
        missing.append(row)
      }
    }
    let fetched = missing.isEmpty ? nil : reader.read(layerIndex: layerIndex, rows: missing)
    if let fetched = fetched {
      for (index, row) in missing.enumerated() {
        if order.count == capacity {
          cachedRows.removeValue(forKey: order[nextIndex])
          order[nextIndex] = row
          nextIndex = (nextIndex + 1) % capacity
        } else {
          order.append(row)
        }
        // Only the last capacity misses survive this batch. Keep their own rows;
        // copying the earlier misses would allocate tensors just to evict them.
        if index >= missing.count - capacity {
          cachedRows[row] = fetched[index..<(index + 1), 0..<width].copied()
        }
      }
    }
    var output = Tensor<Float16>(.CPU, .WC(rows.count, width))
    output.withUnsafeMutableBytes { destination in
      let rowBytes = width * MemoryLayout<Float16>.stride
      for (index, row) in rows.enumerated() {
        guard let cached = decoded[row] else { continue }
        cached.withUnsafeBytes { source in
          destination.baseAddress!.advanced(by: index * rowBytes).copyMemory(
            from: source.baseAddress!, byteCount: rowBytes)
        }
      }
      if let fetched = fetched {
        fetched.withUnsafeBytes { source in
          for (index, row) in rows.enumerated() {
            guard let fetchedIndex = missingIndices[row] else { continue }
            destination.baseAddress!.advanced(by: index * rowBytes).copyMemory(
              from: source.baseAddress!.advanced(by: fetchedIndex * rowBytes), byteCount: rowBytes)
          }
        }
      }
    }
    return output
  }
}

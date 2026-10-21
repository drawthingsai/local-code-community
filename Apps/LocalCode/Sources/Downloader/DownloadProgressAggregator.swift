import Downloader
import Foundation

struct DownloadProgressAggregate {
  var totalBytesWritten: Int64
  var totalBytesTransferred: Int64
  var totalBytesExpectedToWrite: Int64
}

final class DownloadProgressAggregator {
  struct Item: Equatable {
    var file: String
    var remoteURL: URL
  }

  var onExpectedLengthsChanged: (() -> Void)? {
    didSet {
      dispatchPrecondition(condition: .onQueue(.main))
    }
  }

  private var generation: UInt64 = 0
  private var expectedLengthsByIndex: [Int: Int64] = [:]
  private var observedExpectedLengthsByIndex: [Int: Int64] = [:]
  private var probeTasks: [URLSessionDataTask] = []

  deinit {
    cancelProbes()
  }

  var items: [Item] = [] {
    didSet {
      dispatchPrecondition(condition: .onQueue(.main))
      guard items != oldValue else { return }
      generation += 1
      cancelProbes()
      expectedLengthsByIndex.removeAll()
      observedExpectedLengthsByIndex.removeAll()
      let token = generation
      probeTasks = items.enumerated().map { index, item in
        ResumableDownloader.probe(remoteUrl: item.remoteURL) { [weak self] result in
          DispatchQueue.main.async {
            guard let self = self, self.generation == token else { return }
            guard case .success(let probe) = result else { return }
            self.expectedLengthsByIndex[index] = probe.expectedLength
            self.onExpectedLengthsChanged?()
          }
        }
      }
    }
  }

  func cancel() {
    dispatchPrecondition(condition: .onQueue(.main))
    generation += 1
    cancelProbes()
    items.removeAll()
    expectedLengthsByIndex.removeAll()
    observedExpectedLengthsByIndex.removeAll()
  }

  func aggregate(
    totalBytesWritten: Int64,
    totalBytesTransferred: Int64,
    totalBytesExpectedToWrite: Int64,
    index: Int,
    currentFile: String?
  ) -> DownloadProgressAggregate {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !items.isEmpty else {
      return DownloadProgressAggregate(
        totalBytesWritten: totalBytesWritten,
        totalBytesTransferred: totalBytesTransferred,
        totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }

    let effectiveIndex = self.effectiveIndex(index: index, currentFile: currentFile)
    if totalBytesExpectedToWrite > 0 {
      observedExpectedLengthsByIndex[effectiveIndex] = max(
        observedExpectedLengthsByIndex[effectiveIndex] ?? 0, totalBytesExpectedToWrite)
    }

    guard hasExpectedLengthsForAllItems else {
      return DownloadProgressAggregate(
        totalBytesWritten: totalBytesWritten,
        totalBytesTransferred: totalBytesTransferred,
        totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }

    var completedBytes: Int64 = 0
    var expectedBytes: Int64 = 0
    for fileIndex in items.indices {
      let fileExpectedBytes = expectedLengthForFile(at: fileIndex)
      expectedBytes += fileExpectedBytes
      if fileIndex < effectiveIndex {
        completedBytes += fileExpectedBytes
      }
    }
    guard expectedBytes > 0 else {
      return DownloadProgressAggregate(
        totalBytesWritten: totalBytesWritten,
        totalBytesTransferred: totalBytesTransferred,
        totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }
    return DownloadProgressAggregate(
      totalBytesWritten: min(expectedBytes, completedBytes + max(0, totalBytesWritten)),
      totalBytesTransferred: completedBytes + max(0, totalBytesTransferred),
      totalBytesExpectedToWrite: expectedBytes)
  }

  static func internalDownloadable(files: [String]) -> [Item] {
    files.map { file in
      Item(file: file, remoteURL: internalDownloadableURL(file: file))
    }
  }

  private var hasExpectedLengthsForAllItems: Bool {
    items.indices.allSatisfy { expectedLengthForFile(at: $0) > 0 }
  }

  private func expectedLengthForFile(at index: Int) -> Int64 {
    max(expectedLengthsByIndex[index] ?? 0, observedExpectedLengthsByIndex[index] ?? 0)
  }

  private func effectiveIndex(index: Int, currentFile: String?) -> Int {
    guard let currentFile, let fileIndex = items.firstIndex(where: { $0.file == currentFile })
    else {
      return max(0, index)
    }
    return max(0, fileIndex)
  }

  private func cancelProbes() {
    for task in probeTasks {
      task.cancel()
    }
    probeTasks.removeAll()
  }
}

private func internalDownloadableURL(file: String) -> URL {
  let encodedFile = file.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? file
  return URL(string: "https://static.libnnc.org/\(encodedFile)")!
}

import Darwin
import Dispatch
import Foundation

// Signal handling belongs to the CLI process, outside the shared agent utilities.
final class AgentCLIInterrupt {
  private let lock = NSLock()
  private var receivedSignal: Int32?
  private var sources = [DispatchSourceSignal]()
  private var previousHandlers = [(Int32, sig_t?)]()

  init(onInterrupt: @escaping () -> Void = {}) {
    let queue = DispatchQueue(label: "LocalCodeCLI.signals")
    for number in [SIGINT, SIGTERM] {
      previousHandlers.append((number, signal(number, SIG_IGN)))
      let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
      source.setEventHandler { [weak self] in
        guard let self else { return }
        self.lock.lock()
        self.receivedSignal = number
        self.lock.unlock()
        onInterrupt()
      }
      source.resume()
      sources.append(source)
    }
  }

  var signalNumber: Int32? {
    lock.lock()
    defer { lock.unlock() }
    return receivedSignal
  }

  deinit {
    for source in sources { source.cancel() }
    for (number, handler) in previousHandlers { _ = signal(number, handler) }
  }
}

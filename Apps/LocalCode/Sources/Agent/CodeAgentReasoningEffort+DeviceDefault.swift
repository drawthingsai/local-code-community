import DataModels
import Foundation

extension CodeAgentReasoningEffort {
  /// The Reasoning Effort until one is picked: medium on an iPhone, an iPad, and a Mac whose GPU
  /// has fewer than 20 cores, high on any other Mac, including one whose core count can't be read.
  static let deviceDefault: CodeAgentReasoningEffort = {
    #if os(macOS)
      let isMac = true
    #else
      let isMac = ProcessInfo.processInfo.isMacCatalystApp
    #endif
    guard isMac else { return .medium }
    if let numberOfGPUCores = DeviceCapability.numberOfGPUCores, numberOfGPUCores < 20 {
      return .medium
    }
    return .high
  }()
}

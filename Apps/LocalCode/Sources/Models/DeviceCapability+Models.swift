import DataModels
import LLM
import ModelZoo
import UIKit

extension DeviceCapability {
  /// An iPhone downloads only Inkling 2 Mini, which streams its experts to fit there; the other
  /// local models are too large for it. iPads and Macs download any.
  static func canDownloadLocalModel(
    _ specification: LLMZoo.Specification, userInterfaceIdiom: UIUserInterfaceIdiom
  ) -> Bool {
    userInterfaceIdiom != .phone || specification.version == .inkling_2_mini
  }

  /// A local model this device can pick: one it downloads, otherwise one whose required files are
  /// downloaded, as a missing drafter doesn't hold it back.
  static func canRunLocalModel(_ file: String, userInterfaceIdiom: UIUserInterfaceIdiom) -> Bool {
    guard let specification = LLMZoo.specificationForModel(file) else { return false }
    return canDownloadLocalModel(specification, userInterfaceIdiom: userInterfaceIdiom)
      || LLMZoo.isModelDownloaded(specification, required: true)
  }
}

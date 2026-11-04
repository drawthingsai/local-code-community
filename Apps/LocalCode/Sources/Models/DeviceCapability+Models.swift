import DataModels
import ModelZoo
import UIKit

extension DeviceCapability {
  /// iPhones don't download local models, which are too large for them: they use the cloud.
  static func canDownloadLocalModels(userInterfaceIdiom: UIUserInterfaceIdiom) -> Bool {
    userInterfaceIdiom != .phone
  }

  /// A local model this device can pick: any where models download, otherwise one whose required
  /// files are downloaded, as a missing drafter doesn't hold it back.
  static func canRunLocalModel(_ file: String, userInterfaceIdiom: UIUserInterfaceIdiom) -> Bool {
    guard let specification = LLMZoo.specificationForModel(file) else { return false }
    return canDownloadLocalModels(userInterfaceIdiom: userInterfaceIdiom)
      || LLMZoo.isModelDownloaded(specification, required: true)
  }
}

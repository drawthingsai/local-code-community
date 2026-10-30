import DeviceLink
import Localization
import ModelZoo
import RemoteAPI
import UIKit

/// One of a Mac's own models in the model selector, for the Mac thread open on this device.
struct MacModelChoice: Hashable {
  let id: String
}

/// Threads on the account's Macs, open in the chat in place of a project (MacThreadController).
extension ChatWorkflow: MacThreadControllerDelegate {
  /// The thread's Mac, as the account's room lists it.
  private func mac(of macThread: MacThreadController) -> RoomDevice? {
    deviceLink.state.value?.devices.first { $0.device.id == macThread.project.deviceID }
  }

  /// The account's online Macs, each with its models this device's own threads can run on with
  /// Remote Access.
  private static func remoteAccessMacs(_ state: RoomState?) -> [(
    mac: RoomDevice, models: [HostModel]
  )] {
    (state?.devices ?? []).compactMap { mac in
      let models = (mac.status?.models ?? []).filter {
        inferenceContextWindow(forModel: $0.id) > 0
      }
      return mac.online && !models.isEmpty ? (mac, models) : nil
    }
  }

  /// A Mac as the model selector titles its models, saying when it's answering so a thread can go
  /// to another one.
  private static func macSectionTitle(name: String, isBusy: Bool) -> String {
    isBusy ? name + " · " + LocalizedString.forKey("device_link_status_busy") : name
  }

  /// A Mac's own model as a row of the model selector.
  private static func macModelItem(identifier: AnyHashable, id: String, name: String)
    -> ItemDisplayCollectionViewCellViewModel
  {
    .itemAcronymViewModel(
      ItemAcronymViewModel(
        itemIdentifier: .identifier(identifier), title: .title(name),
        backgroundColor: .secondaryFill,
        detail: LLMZoo.specificationForModel(id)?.note ?? "",
        thumbnail: .image(modelImage(for: id)), isList: true))
  }

  /// The thread's Mac and its own models, for the model selector to pick the one the thread's next
  /// message runs on. The Mac's cloud providers aren't offered here.
  func macModelSection(for macThread: MacThreadController) -> ItemDisplaySectionModel {
    let models = macThread.models?.providers.first { $0.id.isEmpty }?.models ?? []
    return ItemDisplaySectionModel(
      identifier: .section(
        name: .title(
          Self.macSectionTitle(
            name: macThread.macName, isBusy: mac(of: macThread)?.status?.busy == true)),
        image: nil),
      items: models.map {
        Self.macModelItem(identifier: MacModelChoice(id: $0.modelID), id: $0.modelID, name: $0.name)
      })
  }

  /// Remote Access in the model selector: a section for each online Mac with the models it can run
  /// for this device's own threads, so one that's answering can be passed over for another.
  func remoteAccessModelSections() -> [ItemDisplaySectionModel] {
    Self.remoteAccessMacs(deviceLink.state.value).map { mac, models in
      ItemDisplaySectionModel(
        identifier: .section(
          name: .title(
            Self.macSectionTitle(
              name: mac.device.record.name, isBusy: mac.status?.busy == true)), image: nil),
        items: models.map {
          Self.macModelItem(
            identifier: remoteThreadModelIdentifier(
              provider: .deviceLink, model: MacModel(file: $0.id, deviceID: mac.device.id).model),
            id: $0.id, name: $0.name)
        })
    }
  }

  /// The composer's model: the Mac's, with the Mac's status on the icon.
  func updateMacThreadModel() {
    guard let macThread else { return }
    let mac = mac(of: macThread)
    let model = macThread.model?.name ?? LocalizedString.forKey("unspecified")
    let status: HostStatusIconView.Status
    // A link that dropped means the Mac stopped answering, even while the room still lists it.
    if mac?.online != true || deviceLink.macLinks.value[macThread.project.deviceID] == .lost {
      status = .offline
    } else if mac?.status?.busy == true {
      status = .busy
    } else {
      status = .available
    }
    chatInputController.setModel(
      name: String(
        format: LocalizedString.forKey("device_link_model_name"), model, macThread.macName),
      hostStatus: status)
    settingsWorkflow.isMacThreadOpen = true
  }

  /// On a phone or iPad: the models the account's online Macs can run for this device's own
  /// threads, which Remote Access lists as a provider's models (`RemoteProvider.deviceLink`), with
  /// their names, "model on Mac".
  func updateMacModels(_ state: RoomState?) {
    var models = [String]()
    var names = [String: String]()
    for (mac, macModels) in Self.remoteAccessMacs(state) {
      for model in macModels {
        let id = MacModel(file: model.id, deviceID: mac.device.id).model
        models.append(id)
        names[id] = String(
          format: LocalizedString.forKey("device_link_model_name"), model.name,
          mac.device.record.name)
      }
    }
    if workspace.dictionary["devicelink_models", [String].self] != models {
      workspace.dictionary["devicelink_models", [String].self] = models
    }
    if workspace.dictionary["devicelink_model_names", [String: String].self] != names {
      workspace.dictionary["devicelink_model_names", [String: String].self] = names
    }
  }

  func macThreadControllerDidChangeModel(_ controller: MacThreadController) {
    guard controller === macThread else { return }
    updateMacThreadModel()
    // An open model selector lists the Mac's models.
    if let modelSelectWorkflow {
      modelSelectWorkflow.setViewModels([macModelSection(for: controller)], flag: nil)
    }
  }

  func macThreadController(_ controller: MacThreadController, didStartThread ref: ThreadRef) {
    guard controller === macThread else { return }
    settingsWorkflow.openMacThread = ProjectController.Thread(
      projectPath: controller.project.path, threadId: ref.threadID)
  }

  func macThreadControllerDidEnd(_ controller: MacThreadController) {
    guard controller === macThread else { return }
    leaveMacThread()
    presentMacThreadAlert(LocalizedString.forKey("device_link_thread_gone"))
  }

  func macThreadController(_ controller: MacThreadController, didUpdate metrics: Metrics) {
    guard controller === macThread else { return }
    settingsWorkflow.setPrefillTokensPerSecond(
      metrics.prefillTokensPerSecond, tokenGeneratedPerSecond: metrics.generatedTokensPerSecond)
    settingsWorkflow.setContextUsed(
      Int(metrics.contextUsedTokens), contextWindowTokens: Int(metrics.contextWindowTokens))
  }

  func macThreadController(_ controller: MacThreadController, didFailWith message: String) {
    guard controller === macThread else { return }
    presentMacThreadAlert(message)
  }

  func presentMacThreadAlert(_ message: String) {
    let alertController = UIAlertController(
      title: LocalizedString.forKey("device_link"), message: message, preferredStyle: .alert)
    alertController.addAction(UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
    presentedViewController.present(alertController, animated: true)
  }
}

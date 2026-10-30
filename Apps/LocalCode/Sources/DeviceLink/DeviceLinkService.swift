import Combine
import DeviceLink
import Dflat
import Foundation
import Localization
import ModelZoo
import OSLog
import SQLiteDflat
import UIKit
import UserAccount

protocol DeviceLinkServiceDelegate: AnyObject {
  /// On a Mac that serves: a phone or iPad new to the account is waiting for a device to allow
  /// it. Asked once per device; Activities can still allow it later.
  func deviceLinkService(
    _ service: DeviceLinkService, didSeeWaitingDevice deviceID: String, named name: String)
}

/// This device's links: its keys, its connection to the account's room, and either the
/// Mac's threads served to the account's devices (the app running on a Mac, while Serve is on) or
/// the phone's connections to its Macs. Main-thread only.
final class DeviceLinkService {
  /// States, counts and candidate types only: never device or account IDs, addresses, or
  /// contents.
  static let logger = Logger(subsystem: "com.liuliu.local-code", category: "DeviceLink")

  /// Debug builds use the staging room, so they can be tested against a branch's Worker.
  static let roomURL: URL = {
    #if DEBUG
      return URL(string: "wss://room-staging.getlocalcode.app/v1/room")!
    #else
      return URL(string: "wss://room.getlocalcode.app/v1/room")!
    #endif
  }()

  /// For testing the relayed path: a debug build launched with `-DeviceLinkRelayOnly YES` links
  /// through TURN alone.
  private static var isRelayOnly: Bool {
    #if DEBUG
      UserDefaults.standard.bool(forKey: "DeviceLinkRelayOnly")
    #else
      false
    #endif
  }

  /// Only Macs serve, as the Mac app or the iPad app on a Mac: iPhones and iPads suspend apps in
  /// the background.
  static var canServe: Bool {
    ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac
  }

  /// The room's state, sent whole on every change; nil while not connected to a room.
  let state = CurrentValueSubject<RoomState?, Never>(nil)
  /// On a phone: each Mac's projects, by device ID, from its Threads service. Sent on the main
  /// queue.
  let macProjects = CurrentValueSubject<[String: [ProjectSummary]], Never>([:])
  /// On a phone: the link to each Mac, by device ID. Sent on the main queue.
  let macLinks = CurrentValueSubject<[String: MacConnection.LinkState], Never>([:])
  /// On a Mac: its threads as other devices' Threads services see them; the chat workflow is the
  /// backend.
  let threadsHub = ThreadsHub()
  /// On a Mac: its own models, run for other devices' threads.
  let inferenceHub = InferenceHub()
  weak var delegate: DeviceLinkServiceDelegate?

  /// What other devices call this one. An app on a Mac may only see "iPad" or "Mac" as its device
  /// name, so a Mac uses its host name.
  static var deviceName: String {
    guard canServe else { return UIDevice.current.name }
    let host = ProcessInfo.processInfo.hostName
    let name = host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host
    return name.replacingOccurrences(of: "-", with: " ")
  }

  private let accountManager: AccountManager
  private let workspace: SQLiteWorkspace
  private var room: RoomClient?
  private var linkHost: LinkHost?
  private var connector: Connector?
  private var macConnections = [String: MacConnection]()
  private var projectWatches = [String: MacWatch]()
  private var linkSubscriptions = [String: AnyCancellable]()
  private var roomSubscription: AnyCancellable?
  private var busySubscription: AnyCancellable?
  private var appObservers = [NSObjectProtocol]()
  private var activity: NSObjectProtocol?

  init(accountManager: AccountManager, workspace: SQLiteWorkspace) {
    self.accountManager = accountManager
    self.workspace = workspace
    let center = NotificationCenter.default
    appObservers = [
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        guard let self, !Self.canServe else { return }
        // Turns keep going on the Mac; watches pick up where they left off when the app is back.
        self.macConnections.values.forEach { $0.suspend() }
      },
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        // Signing in happens elsewhere in the app; coming back is the moment to join. A Mac never
        // left: its connection stays up until it dies, and clicking into its window activates the
        // app.
        if self.room == nil {
          self.start()
        } else if !Self.canServe {
          self.room?.reconnect()
        }
        self.macConnections.values.forEach { $0.resume() }
      },
    ]
  }

  deinit {
    appObservers.forEach(NotificationCenter.default.removeObserver)
  }

  /// Whether this Mac serves its threads to the account's phones.
  var isServing: Bool {
    get { Self.canServe && UserDefaults.standard.bool(forKey: "device_link_serving") }
    set {
      UserDefaults.standard.set(newValue, forKey: "device_link_serving")
      stop()
      start()
    }
  }

  /// Connects to the room when signed in: as a host on a Mac that serves, otherwise as a client.
  func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard room == nil else { return }
    guard accountManager.isSignedIn else {
      Self.logger.info("not joining the room: signed out of Local Code")
      return
    }
    guard !Self.canServe || isServing else {
      Self.logger.info("not joining the room: this Mac isn't serving")
      return
    }
    let identity: DeviceIdentity
    do {
      identity = try DeviceIdentity.load(from: KeychainKeyStore())
    } catch {
      Self.logger.error(
        "not joining the room: no device keys (\(String(describing: error), privacy: .public))")
      return
    }
    let isHost = Self.canServe
    let device = UIDevice.current
    let accountManager = accountManager
    let room = RoomClient(
      url: Self.roomURL, identity: identity,
      info: .init(
        name: Self.deviceName,
        platform: isHost ? .mac : (device.userInterfaceIdiom == .pad ? .ipad : .iphone),
        role: isHost ? .host : .client),
      accessToken: { completion in
        _ = accountManager.fetchShortTermToken { completion(try? $0.get()) }
      })
    let connector = Connector(room: room, acceptsIncoming: isHost, relayOnly: Self.isRelayOnly)
    if isHost {
      let hub = threadsHub
      let inferenceHub = inferenceHub
      // Every call checks the device is still on the list: not disconnected, not waiting.
      linkHost = LinkHost(room: room, connector: connector) { [weak room] device in
        [
          hub.service(for: device.id) { room?.device(device.id) != nil },
          inferenceHub.service(for: device.id) { room?.device(device.id) != nil },
        ]
      }
      busySubscription = hub.isBusy.sink { [weak self] _ in self?.publishStatus() }
      // Keep serving while the app is in the background.
      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Serving threads to your devices")
    }
    self.connector = connector
    self.room = room
    roomSubscription = room.state.receive(on: DispatchQueue.main).sink { [weak self] state in
      if state.connection != self?.state.value?.connection
        || state.devices.count != self?.state.value?.devices.count
      {
        Self.logger.info(
          "room \(String(describing: state.connection), privacy: .public), \(state.devices.count) other devices, \(state.devices.filter(\.online).count) online"
        )
      }
      self?.state.send(state)
      if isHost { self?.noticeWaitingDevices(state) } else { self?.updateMacs(state) }
    }
    Self.logger.info("joining the room as \(isHost ? "host" : "client", privacy: .public)")
    room.start()
    publishStatus()
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    linkHost?.stop()
    linkHost = nil
    busySubscription = nil
    for deviceID in macConnections.keys { forgetMac(deviceID) }
    room?.stop()
    room = nil
    connector = nil
    roomSubscription = nil
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    state.send(nil)
  }

  /// The Mac's models changed: one was selected, downloaded or removed.
  func modelsDidChange() {
    dispatchPrecondition(condition: .onQueue(.main))
    publishStatus()
  }

  /// On a Mac that serves: its downloaded models and the one its threads run on, and whether a
  /// turn is running, for the account's phones.
  private func publishStatus() {
    guard Self.canServe, let room else { return }
    room.publish(
      HostStatus.with {
        $0.models = LLMZoo.builtinSpecifications.filter { LLMZoo.isModelDownloaded($0) }.map {
          specification in
          HostModel.with {
            $0.id = specification.file
            $0.name = specification.name
          }
        }
        $0.selectedModelID = workspace.dictionary["llm_model", String.self] ?? ""
        $0.busy = threadsHub.isBusy.value
      })
  }

  /// Asks the delegate about each phone or iPad waiting to be allowed, once per device.
  private func noticeWaitingDevices(_ state: RoomState) {
    var asked = Set(UserDefaults.standard.stringArray(forKey: "device_link_asked_devices") ?? [])
    let waiting = state.devices.filter { $0.waiting && !asked.contains($0.device.id) }
    guard !waiting.isEmpty else { return }
    asked.formUnion(waiting.map(\.device.id))
    UserDefaults.standard.set(Array(asked), forKey: "device_link_asked_devices")
    for device in waiting {
      delegate?.deviceLinkService(
        self, didSeeWaitingDevice: device.device.id, named: device.device.record.name)
    }
  }

  // MARK: - A phone's Macs

  /// Watches the projects of each Mac on the list, and lets go of Macs no longer on it. A watch
  /// waits while its Mac is offline, and picks up when the room shows it back.
  private func updateMacs(_ state: RoomState) {
    let macs = Set(
      state.devices.filter { $0.device.record.role == .host && !$0.disconnected && !$0.waiting }
        .map(\.device.id))
    for deviceID in macConnections.keys where !macs.contains(deviceID) { forgetMac(deviceID) }
    for deviceID in macs where projectWatches[deviceID] == nil {
      guard let connection = macConnection(for: deviceID) else { continue }
      projectWatches[deviceID] = connection.watchProjects { [weak self] list in
        DispatchQueue.main.async { self?.macProjects.value[deviceID] = list.projects }
      } ended: { [weak self] status in
        Self.logger.error(
          "a Mac ended the project watch: \(String(describing: status.code), privacy: .public)")
        DispatchQueue.main.async {
          guard let self else { return }
          self.projectWatches[deviceID] = nil
          self.macProjects.value[deviceID] = nil
        }
      }
    }
  }

  /// The connection to a Mac on the account, if it's on the list.
  func macConnection(for deviceID: String) -> MacConnection? {
    dispatchPrecondition(condition: .onQueue(.main))
    if let connection = macConnections[deviceID] { return connection }
    guard let connector, let device = room?.device(deviceID) else { return nil }
    let connection = MacConnection(connector: connector, device: device)
    macConnections[deviceID] = connection
    linkSubscriptions[deviceID] = connection.linkState.removeDuplicates()
      .receive(on: DispatchQueue.main).sink { [weak self] linkState in
        self?.macLinks.value[deviceID] = linkState
      }
    return connection
  }

  private func forgetMac(_ deviceID: String) {
    projectWatches.removeValue(forKey: deviceID)?.cancel()
    macConnections.removeValue(forKey: deviceID)?.close()
    linkSubscriptions[deviceID] = nil
    macLinks.value[deviceID] = nil
    macProjects.value[deviceID] = nil
  }

  // MARK: - Device access

  /// Lets a waiting device in, or a disconnected one back. A disconnected device connects again
  /// when its own user asks (`rejoin()`).
  func allow(_ deviceID: String) {
    room?.allowDevice(deviceID)
  }

  /// On a device another one disconnected: tries to connect again, which works once another
  /// device has allowed it.
  func rejoin() {
    room?.rejoin()
  }

  /// Refuses a device, waiting or not, until one of the account's devices allows it.
  func disconnect(_ deviceID: String) {
    room?.disconnectDevice(deviceID)
    forgetMac(deviceID)
  }
}

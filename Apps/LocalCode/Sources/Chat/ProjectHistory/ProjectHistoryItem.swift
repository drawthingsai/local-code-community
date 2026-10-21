import BashToolContext
import Foundation

private let elapsedTimeFormatter: DateComponentsFormatter = {
  let formatter = DateComponentsFormatter()
  formatter.calendar = .autoupdatingCurrent
  formatter.unitsStyle = .abbreviated
  formatter.allowedUnits = [.hour, .minute, .second]
  formatter.zeroFormattingBehavior = [.dropLeading]
  return formatter
}()

func formatElapsedTime(_ elapsedTime: TimeInterval) -> String {
  elapsedTimeFormatter.string(from: max(elapsedTime, 0))!
}

func formatDatetime(_ datetime: Date) -> String {
  let calendar = Calendar.autoupdatingCurrent
  let now = Date()
  if calendar.isDate(datetime, inSameDayAs: now) {
    return datetime.formatted(date: .omitted, time: .shortened)
  }
  if calendar.isDate(datetime, equalTo: now, toGranularity: .year) {
    return datetime.formatted(
      .dateTime
        .month(.abbreviated)
        .day()
        .hour()
        .minute())
  }
  return datetime.formatted(
    .dateTime
      .year()
      .month(.abbreviated)
      .day()
      .hour()
      .minute())
}

enum ProjectHistoryItem {
  final class ActionableMessage {
    enum MessageType {
      case warning, success, error, loading
    }

    let title: String
    let subtitle: String
    let ctaText: String?
    let messageType: MessageType
    var ctaHandler: (() -> Void)?

    init(
      title: String, subtitle: String, ctaText: String? = nil,
      ctaHandler: (() -> Void)? = nil, messageType: MessageType
    ) {
      self.title = title
      self.subtitle = subtitle
      self.ctaText = ctaText
      self.ctaHandler = ctaHandler
      self.messageType = messageType
    }
  }

  enum Mode: Equatable {
    case bringup(startTime: CFTimeInterval, bashUserInteraction: BashUserInteraction? = nil)
    case reading(
      Int, Int, startTime: CFTimeInterval, bashUserInteraction: BashUserInteraction? = nil)
    case thinking(Int, startTime: CFTimeInterval, bashUserInteraction: BashUserInteraction? = nil)
    case working(Int, startTime: CFTimeInterval, bashUserInteraction: BashUserInteraction? = nil)
    case compacting(
      Int, Int, startTime: CFTimeInterval, bashUserInteraction: BashUserInteraction? = nil)
    case none
  }

  case assistant(id: Int, text: String, datetime: Date, duration: TimeInterval)
  case assistantIncomplete(id: Int, text: String, datetime: Date)
  case assistantThink(id: Int, text: String, thinking: String, output: String, mode: Mode)
  case user(id: Int, text: String, datetime: Date)
  case actionableMessageItem(id: Int, message: ActionableMessage)

  var identifier: ItemIdentifier {
    switch self {
    case .assistant(let id, _, _, _):
      return ItemIdentifier(id: id, type: .assistant)
    case .assistantIncomplete(let id, _, _):
      return ItemIdentifier(id: id, type: .assistant)
    case .assistantThink(let id, _, _, _, _):
      return ItemIdentifier(id: id, type: .assistantThink)
    case .user(let id, _, _):
      return ItemIdentifier(id: id, type: .user)
    case .actionableMessageItem(let id, _):
      return ItemIdentifier(id: id, type: .actionableMessageItem)
    }
  }
}

extension ProjectHistoryItem {
  enum ItemType: Hashable {
    case assistant
    case assistantThink
    case user
    case actionableMessageItem
  }
  struct ItemIdentifier: Hashable {
    var id: Int
    var type: ItemType
  }
}

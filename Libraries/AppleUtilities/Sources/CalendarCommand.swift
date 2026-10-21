import ArgumentParser
import BashToolContext
import EventKit
import Foundation

enum CalendarError: LocalizedError {
  case calendarNotFound(String)
  case eventNotFound(String)
  case noDefaultCalendar
  case readOnlyCalendar
  case recurringEvent

  var errorDescription: String? {
    switch self {
    case .calendarNotFound(let id):
      return "No calendar has ID \(id). Run `calendar calendars` for calendar IDs."
    case .eventNotFound(let id):
      return "No event has ID \(id). Run `calendar events list` for current event IDs."
    case .noDefaultCalendar: return "There is no default calendar. Pass --calendar."
    case .readOnlyCalendar: return "The calendar is read-only."
    case .recurringEvent:
      return "Recurring events cannot be changed with this command. Edit them in Calendar."
    }
  }
}

struct CalendarCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "calendar",
    abstract: "Read and edit calendar events.",
    discussion: """
      Results are JSON. Dates are ISO 8601, such as 2026-10-03, 2026-10-03T19:00, or \
      2026-10-03T19:00:00-04:00. Dates without a time zone are local time. The first command \
      asks for calendar access.
      """,
    subcommands: [Status.self, Calendars.self, Events.self])

  /// Asks Local Code whether the calendar command may run, which asks the user on first use when
  /// `prompt` is true. Only an event store created after access is granted reliably sees
  /// calendars, so this returns a new one.
  static func authorizedStore(prompt: Bool = true) throws -> EKEventStore {
    guard let context = BashToolContext.current, let accessCalendar = context.accessCalendar
    else { throw AppleUtilityError.unavailable }
    // ios_system needs a synchronous exit status. The system prompt cannot be dismissed, so a
    // cancelled command still waits for the answer.
    let group = DispatchGroup()
    var result: Result<Void, Error> = .failure(AppleUtilityError.cancelled)
    group.enter()
    accessCalendar(prompt, context.bashUserInteraction) {
      result = $0
      group.leave()
    }
    group.wait()
    try result.get()
    return EKEventStore()
  }

  struct EventRecord: Encodable {
    var id: String
    var calendarID: String
    var calendar: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var notes: String?
    var recurring: Bool

    init(_ event: EKEvent) {
      id = event.eventIdentifier ?? ""
      calendarID = event.calendar.calendarIdentifier
      calendar = event.calendar.title
      title = event.title ?? ""
      start = event.startDate
      end = event.endDate
      allDay = event.isAllDay
      location = event.location
      notes = event.notes
      recurring = event.hasRecurrenceRules || event.isDetached
    }
  }
}

extension CalendarCommand {
  struct Status: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Show calendar access without asking for it.")

    struct Access: Encodable {
      var authorized: Bool
      var reason: String?
    }

    func result() throws -> any Encodable {
      do {
        _ = try CalendarCommand.authorizedStore(prompt: false)
        return Access(authorized: true)
      } catch {
        return Access(authorized: false, reason: error.localizedDescription)
      }
    }
  }

  struct Calendars: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(abstract: "List calendars and their IDs.")

    struct CalendarRecord: Encodable {
      var id: String
      var title: String
      var account: String
      var writable: Bool
    }

    func result() throws -> any Encodable {
      try CalendarCommand.authorizedStore().calendars(for: .event).map {
        CalendarRecord(
          id: $0.calendarIdentifier, title: $0.title, account: $0.source.title,
          writable: $0.allowsContentModifications)
      }
    }
  }

  struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List, show, create, update, or delete events.",
      subcommands: [List.self, Show.self, Create.self, Update.self, Delete.self])
  }
}

extension CalendarCommand.Events {
  struct List: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List events that overlap a date range, in start order.",
      discussion: "Each occurrence of a recurring event is listed separately.")

    @Option(
      help: ArgumentHelp("Range start. Defaults to the start of today.", valueName: "date"),
      transform: parseDate)
    var from: Date?
    @Option(
      help: ArgumentHelp("Range end. Defaults to 7 days after the range start.", valueName: "date"),
      transform: parseDate)
    var to: Date?
    @Option(
      help: ArgumentHelp(
        "Only events in this calendar ID. Repeat for several calendars.", valueName: "id"))
    var calendar: [String] = []
    @Option(
      parsing: .unconditional,
      help: "Only events whose title, location, or notes contain this text."
    )
    var query: String?
    @OptionGroup var pagination: Pagination

    private var range: (start: Date, end: Date) {
      let start = from ?? Calendar.current.startOfDay(for: Date())
      return (start, to ?? Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start)
    }

    func validate() throws {
      let (start, end) = range
      guard end > start else { throw ValidationError("--to must be after --from.") }
      // EventKit silently ignores events beyond four years from the start.
      guard let limit = Calendar.current.date(byAdding: .year, value: 4, to: start), end <= limit
      else { throw ValidationError("The range must not exceed four years.") }
    }

    func result() throws -> any Encodable {
      struct Page: Encodable {
        var events: [CalendarCommand.EventRecord]
        var nextOffset: Int?
      }
      let store = try CalendarCommand.authorizedStore()
      let calendars = try calendar.isEmpty ? nil : calendar.map(store.existingCalendar)
      let predicate = store.predicateForEvents(
        withStart: range.start, end: range.end, calendars: calendars)
      let events = store.events(matching: predicate).filter { event in
        guard let query else { return true }
        return [event.title, event.location, event.notes].contains {
          $0?.localizedCaseInsensitiveContains(query) == true
        }
      }.sorted {
        ($0.startDate, $0.eventIdentifier ?? "") < ($1.startDate, $1.eventIdentifier ?? "")
      }
      let remaining = events.dropFirst(pagination.offset)
      return Page(
        events: remaining.prefix(pagination.limit).map(CalendarCommand.EventRecord.init),
        nextOffset: remaining.count > pagination.limit
          ? pagination.offset + pagination.limit : nil)
    }
  }

  struct Show: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Show an event.",
      discussion: "For a recurring event, this shows its first occurrence.")

    @Argument(help: "An event ID from `calendar events list`.") var id: String

    func result() throws -> any Encodable {
      CalendarCommand.EventRecord(
        try CalendarCommand.authorizedStore().existingEvent(id))
    }
  }

  struct Create: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(abstract: "Create an event.")

    @Option(parsing: .unconditional, help: "Event title.") var title: String
    @Option(help: ArgumentHelp("Event start.", valueName: "date"), transform: parseDate)
    var start: Date
    @Option(
      help: ArgumentHelp(
        "Event end. Defaults to an hour after the start, or the same day for --all-day.",
        valueName: "date"), transform: parseDate)
    var end: Date?
    @Flag(help: "Create an all-day event.") var allDay = false
    @Option(
      help: ArgumentHelp(
        "Calendar ID. Defaults to the default calendar for new events.", valueName: "id"))
    var calendar: String?
    @Option(parsing: .unconditional, help: "Event location.") var location: String?
    @Option(parsing: .unconditional, help: "Event notes.") var notes: String?

    func result() throws -> any Encodable {
      let store = try CalendarCommand.authorizedStore()
      guard
        let target = try calendar.map(store.existingCalendar) ?? store.defaultCalendarForNewEvents
      else { throw CalendarError.noDefaultCalendar }
      guard target.allowsContentModifications else { throw CalendarError.readOnlyCalendar }
      let event = EKEvent(eventStore: store)
      event.calendar = target
      event.title = title
      event.isAllDay = allDay
      event.startDate = start
      event.endDate = end ?? (allDay ? start : start.addingTimeInterval(60 * 60))
      event.location = location
      event.notes = notes
      try checkCancellation()
      try store.save(event, span: .thisEvent, commit: true)
      return CalendarCommand.EventRecord(event)
    }
  }

  struct Update: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Change an event.",
      discussion: "Pass an empty --location or --notes to clear it.")

    @Argument(help: "An event ID from `calendar events list`.") var id: String
    @Option(parsing: .unconditional, help: "New title.") var title: String?
    @Option(help: ArgumentHelp("New start.", valueName: "date"), transform: parseDate)
    var start: Date?
    @Option(help: ArgumentHelp("New end.", valueName: "date"), transform: parseDate)
    var end: Date?
    @Flag(inversion: .prefixedNo, help: "Make the event all-day, or not.") var allDay: Bool?
    @Option(parsing: .unconditional, help: "New location.") var location: String?
    @Option(parsing: .unconditional, help: "New notes.") var notes: String?

    func validate() throws {
      guard
        title != nil || start != nil || end != nil || allDay != nil || location != nil
          || notes != nil
      else { throw ValidationError("Pass at least one change.") }
    }

    func result() throws -> any Encodable {
      let store = try CalendarCommand.authorizedStore()
      let event = try store.editableEvent(id)
      if let title { event.title = title }
      if let allDay { event.isAllDay = allDay }
      if let start { event.startDate = start }
      if let end { event.endDate = end }
      if let location { event.location = location.isEmpty ? nil : location }
      if let notes { event.notes = notes.isEmpty ? nil : notes }
      try checkCancellation()
      try store.save(event, span: .thisEvent, commit: true)
      return CalendarCommand.EventRecord(event)
    }
  }

  struct Delete: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(abstract: "Delete an event.")

    @Argument(help: "An event ID from `calendar events list`.") var id: String

    func result() throws -> any Encodable {
      struct Deleted: Encodable {
        var deleted: String
      }
      let store = try CalendarCommand.authorizedStore()
      let event = try store.editableEvent(id)
      try checkCancellation()
      try store.remove(event, span: .thisEvent, commit: true)
      return Deleted(deleted: id)
    }
  }
}

extension EKEventStore {
  fileprivate func existingCalendar(_ id: String) throws -> EKCalendar {
    guard let calendar = calendar(withIdentifier: id) else {
      throw CalendarError.calendarNotFound(id)
    }
    return calendar
  }

  fileprivate func existingEvent(_ id: String) throws -> EKEvent {
    guard let event = event(withIdentifier: id) else { throw CalendarError.eventNotFound(id) }
    return event
  }

  /// Recurring events are refused because an ID only identifies their first occurrence.
  fileprivate func editableEvent(_ id: String) throws -> EKEvent {
    let event = try existingEvent(id)
    guard event.calendar.allowsContentModifications else { throw CalendarError.readOnlyCalendar }
    guard !event.hasRecurrenceRules, !event.isDetached else { throw CalendarError.recurringEvent }
    return event
  }
}

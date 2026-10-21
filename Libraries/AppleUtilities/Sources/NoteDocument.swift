import Foundation

/// The protobuf messages Notes keeps notes in: a note's text and styles, gzipped in
/// ZICNOTEDATA.ZDATA, and a table or scan, gzipped in an attachment's ZMERGEABLEDATA1. Apple does
/// not document them; the field numbers follow Ciofeca Forensics' Apple Notes parser, which the
/// Obsidian Importer also uses. Decoding reads only the fields it knows, and malformed data ends
/// a message early instead of failing.
enum NoteDocument {
  struct Note: Equatable {
    var text = ""
    var runs = [AttributeRun]()
  }

  /// Styles for `length` UTF-16 code units of the text.
  struct AttributeRun: Equatable {
    var length = 0
    var style: ParagraphStyle?
    var fontWeight = FontWeight.regular
    var strikethrough = false
    var link: String?
    var attachment: AttachmentInfo?

    /// Equal apart from the length, so the runs format as one.
    func hasSameStyle(as other: AttributeRun) -> Bool {
      var other = other
      other.length = length
      return self == other
    }
  }

  enum FontWeight: Int {
    case regular = 0
    case bold = 1
    case italic = 2
    case boldItalic = 3
  }

  struct ParagraphStyle: Equatable {
    var type = StyleType.body
    var indent = 0
    /// Whether a checklist item is checked; nil for other paragraphs.
    var isChecked: Bool?
    var isBlockQuote = false
  }

  enum StyleType: Int {
    case body = -1
    case title = 0
    case heading = 1
    case subheading = 2
    case monospaced = 4
    case dottedList = 100
    case dashedList = 101
    case numberedList = 102
    case checklist = 103

    var isList: Bool {
      [.dottedList, .dashedList, .numberedList, .checklist].contains(self)
    }
  }

  /// A U+FFFC character in the text stands for an attachment, which these identify.
  struct AttachmentInfo: Equatable {
    var identifier: String
    var type: String
  }

  /// A note's text, from ZICNOTEDATA.ZDATA.
  static func note(fromData data: Data) -> Note? {
    guard let bytes = inflate(data) else { return nil }
    // NoteStoreProto.document, then Document.note.
    guard let document = message(2, in: bytes[...]), let note = message(3, in: document) else {
      return nil
    }
    return Self.note(note)
  }

  /// Notes gzips its protobufs; anything else is read as it is.
  static func inflate(_ data: Data) -> [UInt8]? {
    let bytes = [UInt8](data)
    guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
      return bytes
    }
    // Skip the gzip header and its optional fields. The 8-byte trailer is left after the deflate
    // stream, which ends on its own.
    let flags = bytes[3]
    var index = 10
    if flags & 0x04 != 0 {
      guard index + 2 <= bytes.count else { return nil }
      index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
    }
    for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
      while index < bytes.count, bytes[index] != 0 { index += 1 }
      index += 1
    }
    if flags & 0x02 != 0 { index += 2 }
    guard index < bytes.count,
      let inflated = try? (Data(bytes[index...]) as NSData).decompressed(using: .zlib)
    else { return nil }
    return [UInt8](inflated as Data)
  }

  static func note(_ bytes: ArraySlice<UInt8>) -> Note {
    var note = Note()
    for (number, value) in ProtobufFields(bytes) {
      switch (number, value) {
      case (2, .bytes(let text)): note.text = String(decoding: text, as: UTF8.self)
      case (5, .bytes(let run)): note.runs.append(attributeRun(run))
      default: break
      }
    }
    return note
  }

  private static func attributeRun(_ bytes: ArraySlice<UInt8>) -> AttributeRun {
    var run = AttributeRun()
    for (number, value) in ProtobufFields(bytes) {
      switch (number, value) {
      case (1, .varint(let length)): run.length = Int(Int32(truncatingIfNeeded: length))
      case (2, .bytes(let style)): run.style = paragraphStyle(style)
      case (5, .varint(let weight)):
        run.fontWeight = FontWeight(rawValue: Int(Int32(truncatingIfNeeded: weight))) ?? .regular
      case (7, .varint(let strikethrough)): run.strikethrough = strikethrough != 0
      case (9, .bytes(let link)): run.link = String(decoding: link, as: UTF8.self)
      case (12, .bytes(let info)):
        var identifier = ""
        var type = ""
        for (number, value) in ProtobufFields(info) {
          switch (number, value) {
          case (1, .bytes(let value)): identifier = String(decoding: value, as: UTF8.self)
          case (2, .bytes(let value)): type = String(decoding: value, as: UTF8.self)
          default: break
          }
        }
        run.attachment = AttachmentInfo(identifier: identifier, type: type)
      default: break
      }
    }
    return run
  }

  private static func paragraphStyle(_ bytes: ArraySlice<UInt8>) -> ParagraphStyle {
    var style = ParagraphStyle()
    for (number, value) in ProtobufFields(bytes) {
      switch (number, value) {
      case (1, .varint(let type)):
        style.type = StyleType(rawValue: Int(Int32(truncatingIfNeeded: type))) ?? .body
      case (4, .varint(let indent)): style.indent = max(0, Int(Int32(truncatingIfNeeded: indent)))
      case (5, .bytes(let checklist)):
        style.isChecked = false
        for case (2, .varint(let done)) in ProtobufFields(checklist) { style.isChecked = done != 0 }
      case (8, .varint(let blockQuote)): style.isBlockQuote = blockQuote != 0
      default: break
      }
    }
    return style
  }

  /// The last field `number` in `bytes` that holds a message.
  fileprivate static func message(_ number: Int, in bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>?
  {
    var message: ArraySlice<UInt8>?
    for case (number, .bytes(let value)) in ProtobufFields(bytes) { message = value }
    return message
  }
}

// MARK: - Tables and scans

extension NoteDocument {
  /// A CRDT document, such as a table or a scan, whose objects refer to each other by index.
  struct MergeableData {
    var entries = [Entry]()
    var keys = [String]()
    var types = [String]()
    var uuids = [[UInt8]]()

    /// A reference to an entry, a number, or a string.
    struct ObjectID: Equatable {
      var number: UInt64?
      var string: String?
      var index: Int?
    }

    struct Entry {
      var note: Note?
      var customMap: CustomMap?
      var dictionary = [(key: ObjectID, value: ObjectID)]()
      var orderedSet: OrderedSet?
    }

    struct CustomMap {
      var type: Int
      var entries: [(key: Int, value: ObjectID)]
    }

    /// The UUIDs of an ordered set's items, in order, and its mapping between item UUIDs.
    struct OrderedSet {
      var order = [[UInt8]]()
      var contents = [(key: ObjectID, value: ObjectID)]()
    }

    init?(data: Data) {
      // MergableDataProto.mergable_data_object, then MergableDataObject.mergeable_data_object_data.
      guard let bytes = NoteDocument.inflate(data),
        let object = NoteDocument.message(2, in: bytes[...]),
        let data = NoteDocument.message(3, in: object)
      else { return nil }
      for (number, value) in ProtobufFields(data) {
        guard case .bytes(let value) = value else { continue }
        switch number {
        case 3: entries.append(Self.entry(value))
        case 4: keys.append(String(decoding: value, as: UTF8.self))
        case 5: types.append(String(decoding: value, as: UTF8.self))
        case 6: uuids.append(Array(value))
        default: break
        }
      }
    }

    /// The cells of a table, by row, or nil when this is not a table.
    func tableCells() -> [[Note?]]? {
      guard
        let root = entries.lazy.compactMap(\.customMap).first(where: {
          types.indices.contains($0.type) && types[$0.type] == "com.apple.notes.ICTable"
        })
      else { return nil }
      var rows: (positions: [[UInt8]: Int], count: Int)?
      var columns: (positions: [[UInt8]: Int], count: Int)?
      var cellColumns: Entry?
      for (key, value) in root.entries {
        guard keys.indices.contains(key), let object = entry(value) else { continue }
        switch keys[key] {
        case "crRows": rows = positions(object)
        case "crColumns": columns = positions(object)
        case "cellColumns": cellColumns = object
        default: break
        }
      }
      guard let rows, let columns, let cellColumns else { return nil }
      var cells = [[Note?]](
        repeating: [Note?](repeating: nil, count: columns.count), count: rows.count)
      for (columnKey, columnValue) in cellColumns.dictionary {
        guard let column = uuid(columnKey).flatMap({ columns.positions[$0] }),
          let cellRows = entry(columnValue)
        else { continue }
        for (rowKey, rowValue) in cellRows.dictionary {
          guard let row = uuid(rowKey).flatMap({ rows.positions[$0] }),
            let note = entry(rowValue)?.note
          else { continue }
          cells[row][column] = note
        }
      }
      return cells
    }

    /// The identifiers of a scan's pages, in order.
    func scanPageIdentifiers() -> [String] {
      entries.compactMap { $0.customMap?.entries.first?.value.string }
    }

    /// Where each item of an ordered set, such as a table's rows, is, and how many there are.
    private func positions(_ object: Entry) -> (positions: [[UInt8]: Int], count: Int) {
      guard let set = object.orderedSet else { return ([:], 0) }
      var positions = [[UInt8]: Int]()
      for (key, value) in set.contents {
        guard let key = uuid(key), let value = uuid(value),
          let position = set.order.firstIndex(of: key)
        else { continue }
        positions[value] = position
      }
      return (positions, set.order.count)
    }

    private func entry(_ id: ObjectID) -> Entry? {
      guard let index = id.index, entries.indices.contains(index) else { return nil }
      return entries[index]
    }

    /// An entry that holds the index of a UUID.
    private func uuid(_ id: ObjectID) -> [UInt8]? {
      guard let number = entry(id)?.customMap?.entries.first?.value.number,
        number < UInt64(uuids.count)
      else { return nil }
      return uuids[Int(number)]
    }

    private static func entry(_ bytes: ArraySlice<UInt8>) -> Entry {
      var entry = Entry()
      for (number, value) in ProtobufFields(bytes) {
        guard case .bytes(let value) = value else { continue }
        switch number {
        case 6: entry.dictionary = dictionary(value)
        case 10: entry.note = NoteDocument.note(value)
        case 13:
          var type = -1
          var entries = [(key: Int, value: ObjectID)]()
          for (number, field) in ProtobufFields(value) {
            switch (number, field) {
            case (1, .varint(let value)): type = Int(Int32(truncatingIfNeeded: value))
            case (3, .bytes(let mapEntry)):
              var key = -1
              var id = ObjectID()
              for (number, field) in ProtobufFields(mapEntry) {
                switch (number, field) {
                case (1, .varint(let value)): key = Int(Int32(truncatingIfNeeded: value))
                case (2, .bytes(let value)): id = objectID(value)
                default: break
                }
              }
              entries.append((key, id))
            default: break
            }
          }
          entry.customMap = CustomMap(type: type, entries: entries)
        case 16:
          var set = OrderedSet()
          if let ordering = NoteDocument.message(1, in: value) {
            if let array = NoteDocument.message(1, in: ordering) {
              for case (2, .bytes(let item)) in ProtobufFields(array) {
                for case (2, .bytes(let uuid)) in ProtobufFields(item) {
                  set.order.append(Array(uuid))
                }
              }
            }
            if let contents = NoteDocument.message(2, in: ordering) {
              set.contents = dictionary(contents)
            }
          }
          entry.orderedSet = set
        default: break
        }
      }
      return entry
    }

    private static func dictionary(_ bytes: ArraySlice<UInt8>) -> [(key: ObjectID, value: ObjectID)]
    {
      var elements = [(key: ObjectID, value: ObjectID)]()
      for case (1, .bytes(let element)) in ProtobufFields(bytes) {
        var key = ObjectID()
        var value = ObjectID()
        for (number, field) in ProtobufFields(element) {
          switch (number, field) {
          case (1, .bytes(let id)): key = objectID(id)
          case (2, .bytes(let id)): value = objectID(id)
          default: break
          }
        }
        elements.append((key, value))
      }
      return elements
    }

    private static func objectID(_ bytes: ArraySlice<UInt8>) -> ObjectID {
      var id = ObjectID()
      for (number, value) in ProtobufFields(bytes) {
        switch (number, value) {
        case (2, .varint(let number)): id.number = number
        case (4, .bytes(let string)): id.string = String(decoding: string, as: UTF8.self)
        case (6, .varint(let index)): id.index = Int(Int32(truncatingIfNeeded: index))
        default: break
        }
      }
      return id
    }
  }
}

// MARK: - Protobuf

/// The fields of a protobuf message, read without a schema. Reading stops at malformed data.
struct ProtobufFields: Sequence, IteratorProtocol {
  enum Value {
    case varint(UInt64)
    case bytes(ArraySlice<UInt8>)
    /// A 32-bit or 64-bit value, which nothing here reads.
    case fixed
  }

  private var bytes: ArraySlice<UInt8>

  init(_ bytes: ArraySlice<UInt8>) {
    self.bytes = bytes
  }

  mutating func next() -> (Int, Value)? {
    guard let key = varint(), key >> 3 > 0 else { return nil }
    let number = Int(key >> 3)
    switch key & 7 {
    case 0:
      guard let value = varint() else { return nil }
      return (number, .varint(value))
    case 1, 5:
      let size = key & 7 == 1 ? 8 : 4
      guard bytes.count >= size else { return nil }
      bytes = bytes.dropFirst(size)
      return (number, .fixed)
    case 2:
      guard let length = varint(), length <= UInt64(bytes.count) else { return nil }
      let value = bytes.prefix(Int(length))
      bytes = bytes.dropFirst(Int(length))
      return (number, .bytes(value))
    default:
      // Groups are deprecated, and Notes does not use them.
      return nil
    }
  }

  private mutating func varint() -> UInt64? {
    var value: UInt64 = 0
    for shift in stride(from: 0, to: 70, by: 7) {
      guard let byte = bytes.first else { return nil }
      bytes = bytes.dropFirst()
      if shift < 64 { value |= UInt64(byte & 0x7f) << UInt64(shift) }
      if byte & 0x80 == 0 { return value }
    }
    return nil
  }
}

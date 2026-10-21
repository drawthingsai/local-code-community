import Foundation

extension Data {
  /// Appends a fixed-width integer to the data in big-endian byte order.
  mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
    var bigEndianValue = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndianValue) {
      self.append(contentsOf: $0)
    }
  }

  /// Converts data into a fixed-width integer, assuming big-endian byte order.
  func toInteger<T: FixedWidthInteger>() -> T {
    // Ensure data is not larger than the integer type
    let size = MemoryLayout<T>.size
    guard self.count >= size else { return 0 }

    // Read bytes into the integer type
    let value = self.prefix(size).withUnsafeBytes {
      $0.load(as: T.self)
    }

    // Convert from big-endian (network order) to the host's byte order
    return T(bigEndian: value)
  }
}

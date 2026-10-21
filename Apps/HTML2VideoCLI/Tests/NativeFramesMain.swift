import AVFoundation
import Foundation

// FFmpeg may decode only the HEVC base layer. Read through AVFoundation to verify
// the auxiliary alpha layer and write tightly packed BGRA pixels for the test.
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let track = asset.tracks(withMediaType: .video).first!
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(
  track: track,
  outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ])
reader.add(output)
precondition(reader.startReading())
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
FileManager.default.createFile(atPath: destination.path, contents: nil)
let file = try FileHandle(forWritingTo: destination)
var times = [Double]()
var width = 0
var height = 0
while let sample = output.copyNextSampleBuffer() {
  let buffer = CMSampleBufferGetImageBuffer(sample)!
  CVPixelBufferLockBaseAddress(buffer, .readOnly)
  width = CVPixelBufferGetWidth(buffer)
  height = CVPixelBufferGetHeight(buffer)
  let stride = CVPixelBufferGetBytesPerRow(buffer)
  let base = CVPixelBufferGetBaseAddress(buffer)!
  for row in 0..<height {
    try file.write(contentsOf: Data(bytes: base + row * stride, count: width * 4))
  }
  CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
  times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
}
try file.close()
precondition(reader.status == .completed, String(describing: reader.error))
print(
  String(
    decoding: try JSONSerialization.data(withJSONObject: [
      "width": width, "height": height, "times": times,
    ]), as: UTF8.self))

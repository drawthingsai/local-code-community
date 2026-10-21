import AVFoundation
import Accelerate
import Localization
import Speech

protocol DictationSessionDelegate: AnyObject {
  /// The whole transcript so far; each one replaces the previous.
  func dictationSession(_ session: DictationSession, didTranscribe transcript: String)
  /// How loud the microphone is, from 0 for silence to 1 for loud speech, about 40 times a second.
  func dictationSession(_ session: DictationSession, didUpdateLevel level: Float)
  /// Called once when listening ends, with the error if it failed.
  func dictationSessionDidFinish(_ session: DictationSession, error: Swift.Error?)
}

/// One dictation, from tapping the mic to the final transcript: speech to text from the
/// microphone, on device when the recognizer supports it. Delegate calls arrive on the
/// recognizer's queue, the main queue by default; levels always arrive on the main queue.
final class DictationSession {
  enum Error: Swift.Error, LocalizedError {
    case notAuthorized
    case unavailable

    var errorDescription: String? {
      switch self {
      case .notAuthorized:
        return LocalizedString.forKey("dictation_not_authorized")
      case .unavailable:
        return LocalizedString.forKey("dictation_unavailable")
      }
    }
  }

  weak var delegate: DictationSessionDelegate?

  /// Whether the dictated language puts spaces between words. Chinese, Japanese, Thai, Lao, Khmer
  /// and Burmese don't, and their transcripts come without them.
  var separatesWordsWithSpaces: Bool {
    guard let languageCode = recognizer?.locale.language.languageCode?.identifier else {
      return true
    }
    return !["zh", "yue", "ja", "th", "lo", "km", "my"].contains(languageCode)
  }

  private let recognizer = SFSpeechRecognizer()
  private let audioEngine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  /// The utterances recognized so far, with when each started in the audio.
  private var utterances: [(start: TimeInterval, text: String)] = []

  /// Asks for microphone and speech recognition access once; `completion` gets whether both
  /// are allowed.
  static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { status in
      guard status == .authorized else { return completion(false) }
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission { completion($0) }
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission { completion($0) }
      }
    }
  }

  /// Starts listening. If a step fails, what the earlier steps set up (the audio session and the
  /// microphone tap) is undone before it throws.
  func start() throws {
    guard task == nil else { return }
    guard let recognizer, recognizer.isAvailable else { throw Error.unavailable }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    self.request = request
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      // Without a microphone to record from, installTap raises an exception rather than throwing.
      guard format.sampleRate > 0, format.channelCount > 0 else { throw Error.unavailable }
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
        request.append(buffer)
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        // .measurement turns off gain control, so speech mostly lands between -50 and -15 dBFS.
        let level = min(max((20 * log10(max(rms, 1e-6)) + 50) / 35, 0), 1)
        DispatchQueue.main.async {
          guard let self else { return }
          self.delegate?.dictationSession(self, didUpdateLevel: level)
        }
      }
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      tearDown()
      throw error
    }
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let result {
        // On device, the recognizer starts over after a pause: a result with metadata ends an
        // utterance, and the results after it hold only the next one. The final result can repeat
        // the last utterance, which is told apart by when it started.
        let text = result.bestTranscription.formattedString
        let endsUtterance = result.speechRecognitionMetadata != nil || result.isFinal
        if endsUtterance {
          let start = result.bestTranscription.segments.first?.timestamp ?? 0
          if utterances.last?.start == start { utterances.removeLast() }
          utterances.append((start, text))
        }
        let texts = utterances.map(\.text) + (endsUtterance ? [] : [text])
        delegate?.dictationSession(
          self,
          didTranscribe: texts.filter { !$0.isEmpty }.joined(
            separator: separatesWordsWithSpaces ? " " : ""))
      }
      guard error != nil || result?.isFinal == true else { return }
      tearDown()
      delegate?.dictationSessionDidFinish(self, error: error)
    }
  }

  /// Done talking: the final transcript and dictationSessionDidFinish still arrive.
  func stop() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    request?.endAudio()
  }

  /// Stops listening and drops what isn't transcribed yet; the delegate hears nothing more.
  func cancel() {
    delegate = nil
    task?.cancel()
    tearDown()
  }

  private func tearDown() {
    stop()
    request = nil
    task = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

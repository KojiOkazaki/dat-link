import Foundation
import AVFoundation
import Combine

@MainActor
class SpeechService: ObservableObject {
    static let shared = SpeechService()
    @Published var isSpeaking: Bool = false
    @Published var autoSpeak: Bool = true

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeechDelegate()

    private init() {
        synthesizer.delegate = delegate
        delegate.onFinish = { [weak self] in self?.isSpeaking = false }
    }

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    func toggle(_ text: String) {
        if isSpeaking { stop() } else { speak(text) }
    }
}

private class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in onFinish?() }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in onFinish?() }
    }
}

import FluidAudio
import Foundation
import HerdrVoiceLocal

/// Speech on the Neural Engine through FluidAudio: Parakeet TDT v2 for speech-to-text and Kokoro (ANE v3) for the
/// voice. Chosen in docs/speech-engine-spike.md because it leaves the GPU to the brain.
actor SpeechEngines {
    static let defaultVoice = "af_heart"

    private let asr: AsrManager
    private let kokoro: KokoroAneManager

    private init(asr: AsrManager, kokoro: KokoroAneManager) {
        self.asr = asr
        self.kokoro = kokoro
    }

    /// Loads both models. With `download` false, FluidAudio's offline mode is on, so missing files fail startup
    /// instead of being fetched: only setup downloads.
    static func load(download: Bool, voices: Set<String>) async throws -> SpeechEngines {
        ModelHub.offlineMode = !download
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        let kokoro = KokoroAneManager(version: .v3)
        try await kokoro.initialize(preloadVoices: voices.union([defaultVoice]))
        return SpeechEngines(asr: asr, kokoro: kokoro)
    }

    /// 16 kHz mono in, transcript out. Parakeet refuses clips under 0.3 s, so a short one is padded with silence.
    func transcribe(_ audio: [Float]) async throws -> String {
        var state = try TdtDecoderState(decoderLayers: 2)
        let padded = audio.count < 8_000 ? audio + [Float](repeating: 0, count: 8_000 - audio.count) : audio
        return try await asr.transcribe(padded, decoderState: &state).text
    }

    func synthesize(_ text: String, voice: String) async throws -> Speech {
        try Task.checkCancellation()
        let result = try await kokoro.synthesizeDetailed(text: text, voice: voice)
        return Speech(samples: result.samples, sampleRate: Int(result.sampleRate))
    }

    /// A real round trip before the helper says it's ready: speak a sentence, then hear it back.
    func probe() async throws -> [String: Any] {
        let start = Date()
        let speech = try await synthesize("Herdr voice is ready to list your agents.", voice: Self.defaultVoice)
        let ttsMs = Date().timeIntervalSince(start) * 1000
        guard speech.samples.contains(where: { abs($0) > 0.01 }), speech.samples.allSatisfy(\.isFinite) else {
            throw ProbeError("text-to-speech produced silent or non-finite audio")
        }
        let pcm = try PCM.toPCM24(speech.samples[...], sampleRate: speech.sampleRate)
        let heardStart = Date()
        let text = try await transcribe(PCM.resampleInt16(pcm, from: 24_000, to: 16_000))
        let sttMs = Date().timeIntervalSince(heardStart) * 1000
        guard text.lowercased().contains("agents") else { throw ProbeError("speech-to-text did not hear the probe sentence") }
        return ["engine": "fluidaudio", "stt": "parakeet-tdt-0.6b-v2", "tts": "kokoro-ane-v3",
                "ttsMs": Int(ttsMs), "sttMs": Int(sttMs), "inference": "ok"]
    }
}

struct ProbeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

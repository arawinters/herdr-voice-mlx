import Foundation

/// Which helper runs Local mode. Both speak LocalWire, so the session doesn't care which one is behind the socket.
/// Native is `herdr-voice-local`: FluidAudio speech on the Neural Engine and an OpenAI-compatible brain (Splash by
/// default). OpenLive is the Electron WebGPU helper with an Ollama brain.
public enum LocalBackend: String, CaseIterable {
    case native, openlive

    /// As listed in the orb's menu, in this order.
    public static let menuOrder: [LocalBackend] = [.native, .openlive]

    public var menuTitle: String {
        switch self {
        case .native: "Local native"
        case .openlive: "Local OpenLive"
        }
    }

    /// The brain each one uses when HERDR_VOICE_LOCAL_BRAIN_URL and _MODEL don't say: Splash's default port for
    /// native (same defaults as BrainConfig in HerdrVoiceLocal), loopback Ollama for OpenLive.
    public var defaultBrainURL: String {
        switch self {
        case .native: "http://127.0.0.1:8000/v1"
        case .openlive: "http://127.0.0.1:11434/v1"
        }
    }

    public var defaultBrainModel: String {
        switch self {
        case .native: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M"
        case .openlive: "qwen3.5:4b"
        }
    }

    public var setupScript: String {
        switch self {
        case .native: "scripts/native-setup"
        case .openlive: "scripts/local-openlive-setup"
        }
    }

    public enum ConfigError: LocalizedError {
        case unknown(String)
        public var errorDescription: String? {
            guard case .unknown(let name) = self else { return nil }
            return "unknown local backend \(name); use native or openlive"
        }
    }

    /// HERDR_VOICE_LOCAL_BACKEND when set (HERDR_VOICE_LOCAL_HELPER=native is the older spelling); otherwise native
    /// once it's set up, OpenLive if only that is, and native when neither is (so setup points at it).
    public static func choose(environment: [String: String], isReady: (LocalBackend) -> Bool) throws -> LocalBackend {
        if let name = environment["HERDR_VOICE_LOCAL_BACKEND"], !name.isEmpty {
            guard let named = LocalBackend(rawValue: name.lowercased()) else { throw ConfigError.unknown(name) }
            return named
        }
        if environment["HERDR_VOICE_LOCAL_HELPER"] == "native" { return .native }
        return !isReady(.native) && isReady(.openlive) ? .openlive : .native
    }
}

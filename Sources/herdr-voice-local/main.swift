// herdr-voice-local: the native local speech helper. It replaces the Electron OpenLive helper with FluidAudio
// speech and a direct OpenAI-compatible brain, and speaks the same LocalWire protocol to the app.
//
// Startup matches the Electron helper: the app writes one boot JSON line on stdin (session token, state directory,
// brain), never argv. The helper loads its models offline, runs a real speech round trip and a brain probe, binds
// 127.0.0.1 on an ephemeral port, and prints one `ready` JSON line on stdout. It exits when stdin closes.
//
// `herdr-voice-local setup` downloads the models (the only time it goes online), runs the same probes, and records that
// setup finished. `herdr-voice-local check` runs the probes offline against what's already there.
import Foundation
import HerdrVoiceLocal

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("herdr-voice-local failed: \(message)\n".utf8))
    exit(1)
}

func writeReady(_ fields: [String: Any]) {
    var record = fields
    record["type"] = "ready"
    FileHandle.standardOutput.write(Data((jsonLine(record) + "\n").utf8))
}

/// One newline-terminated JSON line from stdin, at most 64 KiB.
func readBootLine() throws -> JSONValue {
    var line = Data()
    while true {
        let byte = FileHandle.standardInput.readData(ofLength: 1)
        guard let first = byte.first else { throw ProbeError("stdin closed before the boot configuration") }
        if first == 10 { break }
        line.append(first)
        if line.count > 64 * 1024 { throw ProbeError("boot configuration too large") }
    }
    return try JSONValue.parse(line)
}

/// Opt-in stage timing (HERDR_VOICE_LOCAL_TRACE=1), in the Electron helper's format so the demo lines it up the same
/// way. Marks are wall-clock milliseconds. No text, audio or tool data is logged.
let tracing = ProcessInfo.processInfo.environment["HERDR_VOICE_LOCAL_TRACE"] == "1"
@Sendable func mark(_ stage: String, _ detail: [String: Any] = [:]) {
    guard tracing else { return }
    var record = detail
    record["type"] = "trace"
    record["stage"] = stage
    record["at"] = Date().timeIntervalSince1970 * 1000
    FileHandle.standardError.write(Data((jsonLine(record) + "\n").utf8))
}

/// For `setup` from a terminal: the same brain variables the app and the other setup scripts read. A keyed brain's
/// key lives in Keychain and only the app passes it, so setup can't probe one.
func brainFromEnvironment() -> JSONValue {
    let environment = ProcessInfo.processInfo.environment
    var brain: [String: JSONValue] = [:]
    for (variable, key) in [("KIND", "kind"), ("MODEL", "model"), ("URL", "baseURL"), ("PROTOCOL", "protocol"),
                            ("REASONING", "reasoningEffort"), ("LABEL", "label")] {
        if let value = environment["HERDR_VOICE_LOCAL_BRAIN_\(variable)"] ?? environment["HERDR_LOCAL_BRAIN_\(variable)"],
           !value.isEmpty { brain[key] = .string(value) }
    }
    return .object(brain)
}

@MainActor
func run() async {
    let command = CommandLine.arguments.dropFirst().first
    guard command == nil || command == "setup" || command == "check" else {
        fail("unknown command \(command!); use setup or check, or no arguments when the app starts it")
    }
    let fromTerminal = command != nil
    let boot: JSONValue
    do {
        boot = fromTerminal ? .object(["setup": .bool(true), "brain": brainFromEnvironment()]) : try readBootLine()
    } catch { fail(error.localizedDescription) }
    let setup = boot["setup"]?.bool == true
    let download = command == "setup" || (!fromTerminal && setup)
    let token = boot["token"]?.string ?? ""
    let tokenCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    if !setup, !(32...200).contains(token.count) || !token.unicodeScalars.allSatisfy(tokenCharacters.contains) {
        fail("invalid session token")
    }

    let brain: BrainConfig
    do { brain = try BrainConfig.validate(boot["brain"]) } catch { fail(error.localizedDescription) }
    let client = BrainClient(config: brain)

    let engines: SpeechEngines
    let probe: [String: Any]
    let brainProbe: [String: Any]
    do {
        let voice = ProcessInfo.processInfo.environment["HERDR_VOICE_VOICE"].flatMap { $0.isEmpty ? nil : $0 }
        engines = try await SpeechEngines.load(download: download, voices: voice.map { [$0] } ?? [])
        probe = try await engines.probe()
        brainProbe = try await client.preflight()
    } catch { fail(error.localizedDescription) }

    if setup {
        if download {
            let record = NativeState.setupRecord()
            do {
                try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fields: [String: Any] = ["setupAt": ISO8601DateFormatter().string(from: Date()), "probe": probe]
                try Data((jsonLine(fields) + "\n").utf8).write(to: record, options: .atomic)
            } catch { fail("could not record setup in \(record.path): \(error.localizedDescription)") }
        }
        writeReady(["setup": true, "offline": !download, "brain": brain.displayLabel, "brainProbe": brainProbe, "probe": probe])
        exit(0)
    }

    let server = LoopbackServer(token: token) { emit in
        BridgeSession(BridgeDependencies(
            transcribe: { audio, _ in
                mark("stt.start", ["audioMs": Double(audio.count) / 16])
                defer { mark("stt.done") }
                return try await engines.transcribe(audio)
            },
            synthesize: { text, voice, _, _ in
                mark("tts.start", ["chars": text.count])
                defer { mark("tts.done") }
                return try await engines.synthesize(text, voice: voice)
            },
            stream: { request in
                guard tracing else { return client.stream(request) }
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        mark("brain.request")
                        var first = true
                        do {
                            for try await event in client.stream(request) {
                                if first {
                                    if case .text = event { first = false; mark("brain.first_text") }
                                    if case .toolStart = event { first = false; mark("brain.first_tool") }
                                }
                                continuation.yield(event)
                            }
                            mark("brain.done")
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            emit: emit,
            model: brain.model,
            reasoningEffort: brain.reasoningEffort))
    }
    let port: UInt16
    do { port = try await server.start() } catch { fail("loopback server did not bind: \(error.localizedDescription)") }
    writeReady(["protocol": 1, "host": "127.0.0.1", "port": Int(port), "brain": brain.displayLabel,
                "brainProbe": brainProbe, "probe": probe])

    // The app closes stdin to stop the helper.
    Thread.detachNewThread {
        while !FileHandle.standardInput.availableData.isEmpty {}
        DispatchQueue.main.async {
            server.stop()
            exit(0)
        }
    }
}

Task { @MainActor in await run() }
// Not dispatchMain(): that exits the main thread, and the socket callbacks assume the main actor.
RunLoop.main.run()

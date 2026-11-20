import Foundation
import Testing
@testable import HerdrVoiceLocal

// Ported from local-openlive/tests/session.test.ts, so the native helper keeps the Electron helper's behavior.

private let tools: JSONValue = .array([
    .object(["name": .string("list_agents"), "description": .string("List agents"),
             "parameters": .object(["type": .string("object"), "properties": .object([:])])]),
])

private func setup(tools: JSONValue = tools, names: [String] = ["list_agents"]) -> JSONValue {
    .object(["type": .string("session.update"), "session": .object([
        "protocol_version": .number(1),
        "instructions": .string("Be concise"),
        "voice": .string("af_heart"),
        "tools": tools,
        "tool_manifest": .object(["profile": .string("test1"), "count": .number(Double(names.count)),
                                  "names": .array(names.map(JSONValue.string)), "digest": .string("test-digest")]),
    ])])
}

private func message(_ type: String, _ fields: [String: Any] = [:]) -> JSONValue {
    var object = fields
    object["type"] = type
    return try! JSONValue(object)
}

/// 20 ms mic packets (PCM16 24 kHz, like the app sends): `speechMs` of a 200 Hz tone at `level`, then quiet.
private func packets(speechMs: Int, level: Double = 0.2, quietMs: Int = 460) -> [String] {
    (0..<((speechMs + quietMs) / 20)).map { frame in
        var data = Data(count: 960)
        let amplitude = frame * 20 < speechMs ? level : 0.0005
        data.withUnsafeMutableBytes { raw in
            for i in 0..<480 {
                let value = Int16((sin(2 * .pi * 200 * Double(frame * 480 + i) / 24_000) * amplitude * 32767).rounded())
                raw.storeBytes(of: value.littleEndian, toByteOffset: i * 2, as: Int16.self)
            }
        }
        return data.base64EncodedString()
    }
}

private func replay(_ list: [ProviderEvent]) -> AsyncThrowingStream<ProviderEvent, Error> {
    AsyncThrowingStream { continuation in
        list.forEach { continuation.yield($0) }
        continuation.finish()
    }
}

private func failing(_ error: Error) -> AsyncThrowingStream<ProviderEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: error) }
}

private let toolCall: [ProviderEvent] = [
    .toolStart(index: 0, id: "c1", name: "list_agents"), .toolDelta(index: 0, arguments: "{}"), .toolStop(index: 0),
    .done(stopReason: "tool_calls"),
]

/// A value tests can hand to a fake and resolve later.
private final class Gate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value { lock.unlock(); continuation.resume(returning: value); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open(_ value: Value) {
        lock.lock()
        self.value = value
        let ready = waiters
        waiters = []
        lock.unlock()
        ready.forEach { $0.resume(returning: value) }
    }
}

/// Fake timers for the held-turn timeout: sleeps finish only when the test advances time.
private final class Timers: @unchecked Sendable {
    private let gate = Gate<Bool>()
    func sleep(_: Int) async throws {
        _ = await gate.wait()
        try Task.checkCancellation()
    }
    func advance() { gate.open(true) }
}

/// Lets queued main-actor tasks run.
@MainActor private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

@MainActor
private final class Harness {
    var events: [[String: Any]] = []
    var session: BridgeSession!

    init(transcribe: @escaping @Sendable ([Float], Int) async throws -> String = { _, _ in "List my agents." },
         synthesize: @escaping @Sendable (String, String, Int, Int) async throws -> Speech = { _, _, _, _ in
             Speech(samples: [Float](repeating: 0.2, count: 2400), sampleRate: 24_000)
         },
         cancelSynthesis: @escaping @MainActor (Int, Int) -> Void = { _, _ in },
         stream: @escaping @Sendable (ChatRequest) -> AsyncThrowingStream<ProviderEvent, Error> = { _ in
             replay([.done(stopReason: "stop")])
         },
         validateManifest: @escaping (JSONValue, JSONValue) -> Bool = { _, _ in true },
         sleep: @escaping @Sendable (Int) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }) {
        session = BridgeSession(BridgeDependencies(
            transcribe: transcribe, synthesize: synthesize, cancelSynthesis: cancelSynthesis, stream: stream,
            emit: { [unowned self] in self.events.append($0) }, now: { 100 }, validateManifest: validateManifest,
            sleep: sleep))
    }

    func run(_ message: JSONValue) async throws {
        try await session.handle(message)?.value
    }

    func say(_ epoch: Int, _ id: String, speechMs: Int = 600, level: Double = 0.2) async throws {
        try await run(HerdrVoiceLocalTests.message("input.begin", ["epoch": epoch, "utterance_id": id]))
        for audio in packets(speechMs: speechMs, level: level) {
            try await run(HerdrVoiceLocalTests.message("input.append", ["epoch": epoch, "utterance_id": id, "audio": audio]))
        }
        try await run(HerdrVoiceLocalTests.message("input.commit", ["epoch": epoch, "utterance_id": id]))
    }

    func ask(_ text: String, epoch: Int = 0) async throws {
        try await run(message("conversation.text", ["epoch": epoch, "text": text, "expects_reply": true]))
        try await run(message("response.create", ["epoch": epoch]))
    }

    var types: [String] { events.map { $0["type"] as! String } }
    var heard: [String] {
        events.filter { $0["type"] as? String == "input.transcription.completed" }.map { $0["transcript"] as! String }
    }
    var roles: [String] { session.history.map(\.role.rawValue) }
    func error(_ index: Int) -> String? { (events[index]["error"] as? [String: Any])?["message"] as? String }
}

@MainActor
@Suite struct BridgeSessionTests {
    @Test func rejectsASchemaHandshakeBeforeAcceptingMicrophoneAudio() async {
        let h = Harness(validateManifest: { _, _ in false })
        #expect(throws: BridgeError("tool manifest mismatch")) { try h.session.handle(setup()) }
        #expect(throws: BridgeError("session.update required before commands")) {
            try h.session.handle(message("input.begin", ["epoch": 1, "utterance_id": "u1"]))
        }
    }

    @Test func createsAMicrophoneTranscriptOnlyAfterCommittedPCM() async throws {
        let h = Harness()
        try await h.run(setup())
        try await h.say(1, "u1")
        let transcript = try #require(h.events.last)
        #expect(transcript["type"] as? String == "input.transcription.completed")
        #expect(transcript["epoch"] as? Int == 1)
        #expect(transcript["utterance_id"] as? String == "u1")
        #expect(transcript["source"] as? String == "microphone")
        #expect(transcript["transcript"] as? String == "List my agents.")
    }

    @Test func emitsCreatedThenCompleteToolCallsThenDoneBeforeToolOutputs() async throws {
        let h = Harness(stream: { _ in replay(toolCall) })
        try await h.run(setup())
        try await h.ask("List my agents")
        #expect(h.types == ["session.updated", "response.created", "response.function_call_arguments.done", "response.done"])
        try await h.run(message("tool.outputs", ["epoch": 0, "outputs": [["call_id": "c1", "name": "list_agents", "output": "[]"]]]))
        let last = try #require(h.session.history.last)
        #expect(last.role == .tool && last.callID == "c1" && last.name == "list_agents")
    }

    @Test func keepsEveryToolCallAnsweredNextToItsCallWhenTheUserSpeaksWhileAToolRuns() async throws {
        let turn = Counter()
        let h = Harness(stream: { _ in
            let n = turn.next()
            return replay(n == 1 ? toolCall : [.text("Complete response number \(n)."), .done(stopReason: "stop")])
        })
        try await h.run(setup())
        try await h.ask("list")
        try await h.say(1, "u1")
        try await h.run(message("response.create", ["epoch": 1]))
        #expect(h.roles == ["system", "user", "assistant", "tool", "user", "assistant"])
        #expect(h.session.history[3].callID == "c1")
        #expect(h.session.history[3].text?.contains("No result yet") == true)

        let wrong = message("tool.outputs", ["epoch": 1, "outputs": [["call_id": "c1", "name": "list_agents", "output": "wrong"]]])
        #expect(throws: BridgeError("unknown or replayed tool output")) { try h.session.handle(wrong) }
        try await h.run(message("tool.outputs", ["epoch": 0, "outputs": [["call_id": "c1", "name": "list_agents", "output": "[]"]]]))
        #expect(h.roles == ["system", "user", "assistant", "tool", "user", "assistant"])
        #expect(h.session.history[3].text == "[]")
        let again = message("tool.outputs", ["epoch": 1, "outputs": [["call_id": "c1", "name": "list_agents", "output": "again"]]])
        #expect(throws: BridgeError("unknown or replayed tool output")) { try h.session.handle(again) }
    }

    @Test func rejectsInvalidModelArgumentsBeforeTheyCanReachTheApp() async throws {
        let focus: JSONValue = .array([.object([
            "name": .string("focus"), "description": .string("Focus"),
            "parameters": try JSONValue(["type": "object", "properties": ["target": ["type": "string"]], "required": ["target"]]),
        ])])
        let h = Harness(stream: { _ in replay([
            .toolStart(index: 0, id: "c1", name: "focus"), .toolDelta(index: 0, arguments: "{}"), .toolStop(index: 0),
            .done(stopReason: "tool_calls"),
        ]) })
        try await h.run(setup(tools: focus, names: ["focus"]))
        try await h.ask("focus")
        #expect(!h.types.contains("response.function_call_arguments.done"))
        #expect(Array(h.types.suffix(2)) == ["error", "response.done"])
        #expect(h.error(h.events.count - 2) == "missing required focus.target")
        #expect(h.events[h.events.count - 2]["epoch"] as? Int == 0)
    }

    @Test func dropsATranscriptionThatCompletesAfterANewerMicrophoneEpoch() async throws {
        let pending = Gate<String>()
        let h = Harness(transcribe: { _, _ in await pending.wait() })
        try await h.run(setup())
        try await h.run(message("input.begin", ["epoch": 1, "utterance_id": "old"]))
        for audio in packets(speechMs: 600) {
            try await h.run(message("input.append", ["epoch": 1, "utterance_id": "old", "audio": audio]))
        }
        let old = try h.session.handle(message("input.commit", ["epoch": 1, "utterance_id": "old"]))
        try await h.run(message("input.begin", ["epoch": 2, "utterance_id": "new"]))
        pending.open("yes")
        try await old?.value
        #expect(!h.types.contains("input.transcription.completed"))
    }

    @Test func dropsATranscriptionThatCompletesAfterInputClearAtTheSameMuteBoundary() async throws {
        let pending = Gate<String>()
        let h = Harness(transcribe: { _, _ in await pending.wait() })
        try await h.run(setup())
        try await h.run(message("input.begin", ["epoch": 1, "utterance_id": "muted"]))
        for audio in packets(speechMs: 600) {
            try await h.run(message("input.append", ["epoch": 1, "utterance_id": "muted", "audio": audio]))
        }
        let old = try h.session.handle(message("input.commit", ["epoch": 1, "utterance_id": "muted"]))
        try await h.run(message("input.clear", ["epoch": 2]))
        pending.open("yes")
        try await old?.value
        #expect(!h.types.contains("input.transcription.completed"))
        #expect(!h.session.history.contains { $0.role == .user && $0.text == "yes" })
    }

    @Test func rejectsNonFiniteSynthesizedSamplesInsteadOfEmittingCorruptPCM() async throws {
        let h = Harness(synthesize: { _, _, _, _ in Speech(samples: [.nan, 0.2], sampleRate: 24_000) },
                        stream: { _ in replay([.text("This is a complete spoken response."), .done(stopReason: "stop")]) })
        try await h.run(setup())
        try await h.ask("hello")
        #expect(Array(h.types.suffix(2)) == ["error", "response.done"])
        #expect(h.error(h.events.count - 2) == "non-finite synthesized audio sample")
    }

    @Test func terminatesAStartedResponseWhenTheBrainStreamFails() async throws {
        let h = Harness(stream: { _ in failing(BridgeError("brain unavailable")) })
        try await h.run(setup())
        try await h.ask("hello")
        #expect(Array(h.types.suffix(3)) == ["response.created", "error", "response.done"])
        #expect((h.events[h.events.count - 3]["response"] as? [String: Any])?["id"] as? String == "local-0-100-1")
        #expect(h.error(h.events.count - 2) == "brain unavailable")
    }

    @Test func dropsSameEpochSpeechThatFinishesAfterResponseCancel() async throws {
        let delayed = Gate<Bool>()
        var cancelled: [[Int]] = []
        let h = Harness(
            synthesize: { _, _, _, _ in
                _ = await delayed.wait()
                return Speech(samples: [Float](repeating: 0.2, count: 2400), sampleRate: 24_000)
            },
            cancelSynthesis: { cancelled.append([$0, $1]) },
            stream: { _ in replay([.text("This response is long enough to synthesize."), .done(stopReason: "stop")]) })
        try await h.run(setup())
        try await h.run(message("conversation.text", ["epoch": 0, "text": "hello", "expects_reply": true]))
        let response = try h.session.handle(message("response.create", ["epoch": 0]))
        await settle()
        try await h.run(message("response.cancel", ["epoch": 0]))
        delayed.open(true)
        _ = await response?.result
        await settle()
        #expect(!h.types.contains("response.audio.delta"))
        #expect(cancelled.contains([0, 1]))
    }

    @Test func treatsSynthesisCancelledMidStreamAsExpectedNotAnError() async throws {
        let h = Harness(
            synthesize: { _, _, _, _ in
                try await Task.sleep(nanoseconds: 60_000_000_000) // until cancelled
                return Speech(samples: [0.2], sampleRate: 24_000)
            },
            stream: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.text("This sentence is being spoken now. "))
                    // Never finishes on its own: only the cancel ends it.
                }
            })
        try await h.run(setup())
        try await h.run(message("conversation.text", ["epoch": 0, "text": "hello", "expects_reply": true]))
        let response = try h.session.handle(message("response.create", ["epoch": 0]))
        await settle()
        try await h.run(message("response.cancel", ["epoch": 0]))
        _ = await response?.result
        await settle()
        #expect(!h.types.contains("error"))
        #expect(!h.types.contains("response.audio.delta"))
    }

    @Test func truncatesTheHistoryEntryBoundToThatAudioItem() async throws {
        let answer = Box("First complete response for playback.")
        let h = Harness(stream: { _ in replay([.text(answer.value), .done(stopReason: "stop")]) })
        try await h.run(setup())
        try await h.ask("one")
        let first = try #require((h.events.first { $0["type"] as? String == "response.created" }?["response"] as? [String: Any])?["id"] as? String)
        answer.value = "Second complete response stays intact."
        try await h.ask("two")
        try await h.run(message("response.truncate", ["epoch": 0, "item_id": first, "audio_end_ms": 0]))
        // Nothing of the first reply was heard and it called no tool: it leaves the history entirely.
        let assistants = h.session.history.filter { $0.role == .assistant }
        #expect(assistants.map(\.text) == ["Second complete response stays intact."])
        #expect(assistants.allSatisfy { $0.toolCalls.isEmpty })
    }

    @Test func trimsOnlyCompleteHistoryGroupsSoToolResultsAreNeverOrphaned() async throws {
        let turn = Counter()
        let h = Harness(stream: { _ in
            let n = turn.next()
            return replay(n == 1 ? toolCall : [.text("Complete response number \(n)."), .done(stopReason: "stop")])
        })
        try await h.run(setup())
        try await h.ask("tools")
        try await h.run(message("tool.outputs", ["epoch": 0, "outputs": [["call_id": "c1", "name": "list_agents", "output": "[]"]]]))
        for index in 0..<45 { try await h.ask("turn \(index)") }
        #expect(h.session.history.count <= BridgeSession.maxHistory)
        var known: Set<String> = []
        for entry in h.session.history {
            entry.toolCalls.forEach { known.insert($0.id) }
            if entry.role == .tool { #expect(known.contains(entry.callID ?? "")) }
        }
    }

    @Test func sendsTheHistoryAndToolsInTheChatRequest() async throws {
        let seen = Box<ChatRequest?>(nil)
        let h = Harness(stream: { request in seen.value = request; return replay([.done(stopReason: "stop")]) })
        try await h.run(setup())
        try await h.ask("hello")
        let request = try #require(seen.value)
        #expect(request.messages.map { $0["role"]?.string } == ["system", "user"])
        #expect(request.tools == tools.array)
        #expect(request.reasoningEffort == "none")
        #expect(request.maxTokens == 300)
    }
}

@MainActor
@Suite struct PhantomMicrophoneTurnTests {
    @Test func dropsABlipTooShortToBeSpeechWithoutTranscribingIt() async throws {
        let calls = Counter()
        let h = Harness(transcribe: { _, _ in _ = calls.next(); return "for you." })
        try await h.run(setup())
        try await h.say(1, "blip", speechMs: 100)
        #expect(calls.count == 0)
        #expect(h.heard.isEmpty)
    }

    @Test func dropsNearSilenceThatOpenedTheGate() async throws {
        let calls = Counter()
        let h = Harness(transcribe: { _, _ in _ = calls.next(); return "through." })
        try await h.run(setup())
        try await h.say(1, "hiss", speechMs: 600, level: 0.003)
        #expect(calls.count == 0)
        #expect(h.heard.isEmpty)
    }

    @Test func stillHearsAShortRealAnswer() async throws {
        let h = Harness(transcribe: { _, _ in "Yes." })
        try await h.run(setup())
        try await h.say(1, "yes", speechMs: 280)
        #expect(h.heard == ["Yes."])
    }

    @Test func holdsATurnThatTrailsOffAndTranscribesItTogetherWithTheNextOne() async throws {
        let lengths = Lengths()
        let texts = ["Tell claude to", "Tell claude to run the tests."]
        let h = Harness(transcribe: { audio, _ in texts[lengths.add(audio.count) - 1] })
        try await h.run(setup())
        try await h.say(1, "a")
        #expect(h.heard.isEmpty)
        try await h.say(2, "b")
        #expect(Double(lengths.values[1]) > Double(lengths.values[0]) * 1.9)
        let completed = h.events.filter { $0["type"] as? String == "input.transcription.completed" }
        #expect(completed.count == 1)
        #expect(completed.first?["epoch"] as? Int == 2)
        #expect(completed.first?["utterance_id"] as? String == "b")
        #expect(h.heard == ["Tell claude to run the tests."])
        #expect(h.session.history.filter { $0.role == .user }.map(\.text) == ["Tell claude to run the tests."])
    }

    @Test func sendsAHeldTurnOnceNobodyContinuesIt() async throws {
        let timers = Timers()
        let h = Harness(transcribe: { _, _ in "Close the build pane and" }, sleep: { try await timers.sleep($0) })
        try await h.run(setup())
        try await h.say(1, "a")
        #expect(h.heard.isEmpty)
        timers.advance()
        await settle()
        #expect(h.heard == ["Close the build pane and"])
    }

    @Test func joinsASegmentStillBeingTranscribedIntoTheNextOneInsteadOfDroppingIt() async throws {
        let first = Gate<String>()
        let lengths = Lengths()
        let h = Harness(transcribe: { audio, _ in
            lengths.add(audio.count) == 1 ? await first.wait() : "Open another worktree under herdr-voice."
        })
        try await h.run(setup())
        try await h.run(message("input.begin", ["epoch": 1, "utterance_id": "a"]))
        for audio in packets(speechMs: 600) { try await h.run(message("input.append", ["epoch": 1, "utterance_id": "a", "audio": audio])) }
        let earlier = try h.session.handle(message("input.commit", ["epoch": 1, "utterance_id": "a"]))
        await settle()
        try await h.run(message("input.begin", ["epoch": 2, "utterance_id": "b"]))
        first.open("Open another worktree")
        try await earlier?.value
        for audio in packets(speechMs: 600) { try await h.run(message("input.append", ["epoch": 2, "utterance_id": "b", "audio": audio])) }
        try await h.run(message("input.commit", ["epoch": 2, "utterance_id": "b"]))
        #expect(Double(lengths.values[1]) > Double(lengths.values[0]) * 1.9)
        #expect(h.heard == ["Open another worktree under herdr-voice."])
    }

    @Test func doesNotCarryASegmentAcrossAMute() async throws {
        let first = Gate<String>()
        let lengths = Lengths()
        let h = Harness(transcribe: { audio, _ in lengths.add(audio.count) == 1 ? await first.wait() : "Hello there." })
        try await h.run(setup())
        try await h.run(message("input.begin", ["epoch": 1, "utterance_id": "a"]))
        for audio in packets(speechMs: 600) { try await h.run(message("input.append", ["epoch": 1, "utterance_id": "a", "audio": audio])) }
        let earlier = try h.session.handle(message("input.commit", ["epoch": 1, "utterance_id": "a"]))
        await settle()
        try await h.run(message("input.clear", ["epoch": 2]))
        first.open("secret")
        try await earlier?.value
        try await h.say(3, "b")
        #expect(lengths.values[1] == lengths.values[0])
        #expect(h.heard == ["Hello there."])
    }

    @Test func dropsAHeldTurnWhenTheMicIsMuted() async throws {
        let timers = Timers()
        let h = Harness(transcribe: { _, _ in "Close the build pane and" }, sleep: { try await timers.sleep($0) })
        try await h.run(setup())
        try await h.say(1, "a")
        try await h.run(message("input.clear", ["epoch": 2]))
        timers.advance()
        await settle()
        #expect(h.heard.isEmpty)
    }
}

@MainActor
@Suite struct SmoothLocalSpeechTests {
    @Test func trimsTheSilenceKokoroPadsAroundEachSentence() async throws {
        let rate = 24_000
        var padded = [Float](repeating: 0, count: rate * 2) // 500 ms silence, 1 s of voice, 500 ms silence
        for i in (rate / 2)..<(rate * 3 / 2) { padded[i] = 0.3 * Float(sin(2 * .pi * 220 * Double(i) / Double(rate))) }
        let audio = padded
        let h = Harness(synthesize: { _, _, _, _ in Speech(samples: audio, sampleRate: rate) },
                        stream: { _ in replay([.text("This is one complete sentence to speak aloud now."), .done(stopReason: "stop")]) })
        try await h.run(setup())
        try await h.ask("hi")
        let bytes = h.events.filter { $0["type"] as? String == "response.audio.delta" }
            .reduce(0) { $0 + Data(base64Encoded: $1["delta"] as! String)!.count }
        let ms = Double(bytes) / 2 / 24
        #expect(ms >= 1_000)
        #expect(ms <= 1_000 + 40 + 150 + 20)
    }

    @Test func keepsASentenceThatIsAllQuietRatherThanDroppingIt() async throws {
        let h = Harness(synthesize: { _, _, _, _ in Speech(samples: [Float](repeating: 0, count: 2400), sampleRate: 24_000) },
                        stream: { _ in replay([.text("This is one complete sentence to speak aloud now."), .done(stopReason: "stop")]) })
        try await h.run(setup())
        try await h.ask("hi")
        #expect(h.types.contains("response.audio.delta"))
    }

    // A live session filled the history with replies cut mid-sentence ("I'm ready to help. Would"); Qwen then
    // copied that and ended 2 of 6 replies mid-sentence, against 0 of 6 with the same history in full sentences.
    @Test func keepsOnlyTheCompleteSentencesTheUserHeard() {
        #expect(VoiceText.heardSentences("Yes, I'm ready to help. Would") == "Yes, I'm ready to help.")
        #expect(VoiceText.heardSentences("I've started a new agent in the \"herdr") == "")
        #expect(VoiceText.heardSentences("Done! It passed. Next I'll") == "Done! It passed.")
        #expect(VoiceText.heardSentences("Is that it? Yes.") == "Is that it? Yes.")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

final class Lengths: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Int] = []
    @discardableResult func add(_ n: Int) -> Int { lock.withLock { list.append(n); return list.count } }
    var values: [Int] { lock.withLock { list } }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

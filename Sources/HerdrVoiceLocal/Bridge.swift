import Foundation

/// Synthesized speech: mono float samples.
public struct Speech: Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// What the session needs from the speech engines, the brain and the socket. Tests pass fakes.
public struct BridgeDependencies {
    public var transcribe: @Sendable (_ audio16k: [Float], _ epoch: Int) async throws -> String
    public var synthesize: @Sendable (_ text: String, _ voice: String, _ epoch: Int, _ generation: Int) async throws -> Speech
    public var cancelSynthesis: @MainActor (_ epoch: Int, _ generation: Int) -> Void
    public var stream: @Sendable (ChatRequest) -> AsyncThrowingStream<ProviderEvent, Error>
    public var emit: @MainActor ([String: Any]) -> Void
    public var now: () -> Double
    public var validateManifest: (_ manifest: JSONValue, _ tools: JSONValue) -> Bool
    /// Waits for the held-turn timeout. Throws when cancelled.
    public var sleep: @Sendable (_ milliseconds: Int) async throws -> Void
    public var model: String
    public var reasoningEffort: String?

    public init(
        transcribe: @escaping @Sendable ([Float], Int) async throws -> String,
        synthesize: @escaping @Sendable (String, String, Int, Int) async throws -> Speech,
        cancelSynthesis: @escaping @MainActor (Int, Int) -> Void = { _, _ in },
        stream: @escaping @Sendable (ChatRequest) -> AsyncThrowingStream<ProviderEvent, Error>,
        emit: @escaping @MainActor ([String: Any]) -> Void,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
        validateManifest: @escaping (JSONValue, JSONValue) -> Bool = LocalSecurity.validateManifest,
        sleep: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) },
        model: String = "qwen3.5:4b",
        reasoningEffort: String? = nil
    ) {
        self.transcribe = transcribe
        self.synthesize = synthesize
        self.cancelSynthesis = cancelSynthesis
        self.stream = stream
        self.emit = emit
        self.now = now
        self.validateManifest = validateManifest
        self.sleep = sleep
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public struct BridgeError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The helper's side of LocalWire protocol v1, ported from `local-openlive/src/session.ts`. It turns committed
/// microphone audio into transcripts, streams brain replies into speech, and hands tool calls to the app, which
/// runs them. Every turn event carries the app's epoch, and work from an older epoch or a cancelled response is
/// dropped instead of emitted.
///
/// Main-actor isolated, like the JavaScript event loop it replaces: `handle` applies each message's state change
/// synchronously in arrival order, and returns the task for any work that has to wait on a model.
@MainActor
public final class BridgeSession {
    nonisolated public static let maxHistory = 80
    nonisolated static let maxInputBytes = 24_000 * 2 * 30
    nonisolated static let maxSpeechChunks = 12
    nonisolated static let maxSpokenItems = 20
    /// Turn-taking thresholds from upstream OpenLive's voice engine (minSpeechMs, balanced holdMs).
    nonisolated static let minVoicedMs = 200
    nonisolated static let holdMs = 4_000
    nonisolated static let maxHeldSamples = 16_000 * 20
    nonisolated static let unfinishedTool = "No result yet: the user spoke before this call finished. Its result may still arrive."

    private struct Config {
        let instructions: String
        let voice: String
        let tools: [JSONValue]
    }

    private struct Utterance {
        let id: String
        let epoch: Int
        var audio = Data()
    }

    private struct Pending {
        let callID: String
        let name: String
        let epoch: Int
    }

    private struct SpokenChunk {
        let text: String
        let endMs: Double
    }

    private final class SpokenItem {
        var chunks: [SpokenChunk] = []
        var message: HistoryEntry?
    }

    /// A transcript that trailed off mid-thought, waiting to be joined with what the user says next.
    private final class Held {
        let audio: [Float]
        let text: String
        let epoch: Int
        let id: String
        var timer: Task<Void, Never>?
        init(audio: [Float], text: String, epoch: Int, id: String) {
            self.audio = audio
            self.text = text
            self.epoch = epoch
            self.id = id
        }
    }

    /// One reply in progress. Aborting it stops the brain stream and drops its speech.
    private final class Response {
        var aborted = false
        var tasks: [Task<Void, Error>] = []
        func abort() {
            aborted = true
            tasks.forEach { $0.cancel() }
        }
    }

    public private(set) var history: [HistoryEntry] = []
    private let deps: BridgeDependencies
    private var config: Config?
    private var epoch = 0
    private var utterance: Utterance?
    private var response: Response?
    /// Calls the app has not answered yet, in the order they were made.
    private var unanswered: [Pending] = []
    /// Placeholder results whose real result may still replace them (call ID -> originating epoch).
    private var placeholders: [String: Int] = [:]
    private var spoken: [String: SpokenItem] = [:]
    private var spokenOrder: [String] = []
    private var responseItem: String?
    private var responseGeneration = 0
    private var responseSequence = 0
    private var inputGeneration = 0
    /// Bumped by input.clear (mute): speech from before it must never reach a later turn.
    private var clears = 0
    private var lastUtterance: (epoch: Int, id: String)?
    private var held: Held?

    public init(_ deps: BridgeDependencies) {
        self.deps = deps
    }

    /// Applies one wire message. Throws for a message that's invalid in the current state; the returned task, if
    /// any, throws for a failure while waiting on a model. Both are reported to the app as `error` events.
    @discardableResult
    public func handle(_ message: JSONValue) throws -> Task<Void, Error>? {
        guard let type = message["type"]?.string else { throw BridgeError("message type required") }
        if type == "session.update" {
            try update(message["session"] ?? .null)
            return nil
        }
        guard config != nil else { throw BridgeError("session.update required before commands") }
        let messageEpoch = message["epoch"]?.safeInteger
        switch type {
        case "input.begin":
            guard let messageEpoch, messageEpoch > epoch else { throw BridgeError("input epoch must increase") }
            let id = try Self.requiredID(message["utterance_id"]?.string)
            cancel()
            epoch = messageEpoch
            inputGeneration += 1
            utterance = Utterance(id: id, epoch: messageEpoch)
            lastUtterance = (messageEpoch, id)
            held?.timer?.cancel() // the user is continuing; this utterance's commit decides
            return nil
        case "input.append":
            try requireUtterance(messageEpoch, message["utterance_id"]?.string)
            try append(message["audio"]?.string)
            return nil
        case "input.commit":
            try requireUtterance(messageEpoch, message["utterance_id"]?.string)
            return commit()
        case "input.clear":
            guard let messageEpoch, messageEpoch >= epoch else { return nil }
            epoch = messageEpoch
            inputGeneration += 1
            clears += 1
            cancel()
            utterance = nil
            held?.timer?.cancel()
            held = nil
            return nil
        case "conversation.text":
            guard messageEpoch == epoch else { return nil }
            pushHistory(.user(try Self.boundedText(message["text"]?.string)))
            return nil
        case "response.create":
            guard messageEpoch == epoch else { return nil }
            return try respond(epoch: epoch)
        case "response.cancel":
            if messageEpoch == epoch { cancel() }
            return nil
        case "tool.outputs":
            guard let messageEpoch else { throw BridgeError("unknown or replayed tool output") }
            try acceptToolOutputs(epoch: messageEpoch, outputs: message["outputs"]?.array ?? [])
            return nil
        case "response.truncate":
            guard messageEpoch == epoch else { return nil }
            truncate(item: message["item_id"]?.string ?? "", heardMs: message["audio_end_ms"]?.number ?? 0)
            return nil
        default:
            throw BridgeError("unknown message type")
        }
    }

    private func update(_ session: JSONValue) throws {
        guard session["protocol_version"]?.safeInteger == 1 else { throw BridgeError("unsupported protocol version") }
        let tools = session["tools"] ?? .null
        guard deps.validateManifest(session["tool_manifest"] ?? .null, tools), let list = tools.array else {
            throw BridgeError("tool manifest mismatch")
        }
        guard let instructions = session["instructions"]?.string, !instructions.isEmpty,
              let voice = session["voice"]?.string, !voice.isEmpty
        else { throw BridgeError("instructions and voice are required") }
        config = Config(instructions: instructions, voice: voice, tools: list)
        history = [.system(instructions)]
        deps.emit(["type": "session.updated"])
    }

    private func requireUtterance(_ messageEpoch: Int?, _ id: String?) throws {
        guard let utterance, utterance.epoch == messageEpoch, utterance.id == id, messageEpoch == epoch else {
            throw BridgeError("unknown microphone utterance")
        }
    }

    private func append(_ base64: String?) throws {
        guard let base64, let data = Data(base64Encoded: base64), (1...4096).contains(data.count) else {
            throw BridgeError("invalid microphone packet")
        }
        guard utterance!.audio.count + data.count <= Self.maxInputBytes else {
            throw BridgeError("microphone utterance exceeds 30 seconds")
        }
        utterance!.audio.append(data)
    }

    private func commit() -> Task<Void, Error>? {
        let current = utterance!
        let generation = inputGeneration
        let clearsAtCommit = clears
        utterance = nil
        let audio16 = PCM.resampleInt16(current.audio, from: 24_000, to: 16_000)
        let previous = held
        if PCM.voicedMs(audio16) < Self.minVoicedMs {
            // A click, cough or hiss that opened the gate: the speech model would invent words for it. Not a turn.
            if let previous, current.epoch == epoch {
                hold(audio: previous.audio, text: previous.text, epoch: current.epoch, id: current.id)
            }
            return nil
        }
        let audio = previous.map { $0.audio + audio16 } ?? audio16
        return Task {
            let text = try await deps.transcribe(audio, current.epoch).trimmingCharacters(in: .whitespacesAndNewlines)
            if clearsAtCommit != clears { return }
            if current.epoch != epoch || generation != inputGeneration {
                // The gate reopened while this was transcribing: it's the start of the same sentence, so the newer
                // segment's commit transcribes both together. Nothing newer still open means that commit already ran.
                if utterance != nil {
                    held = Held(audio: audio, text: text, epoch: current.epoch, id: current.id)
                } else if let last = lastUtterance {
                    hold(audio: audio, text: text, epoch: last.epoch, id: last.id)
                }
                return
            }
            held = nil
            if VoiceText.isJunk(text) { return }
            if VoiceText.endsMidThought(text), audio.count < Self.maxHeldSamples {
                hold(audio: audio, text: text, epoch: current.epoch, id: current.id)
                return
            }
            acceptTranscript(epoch: current.epoch, utteranceID: current.id, text: text)
        }
    }

    private func hold(audio: [Float], text: String, epoch heldEpoch: Int, id: String) {
        held?.timer?.cancel()
        let turn = Held(audio: audio, text: text, epoch: heldEpoch, id: id)
        let sleep = deps.sleep
        turn.timer = Task { [weak self, weak turn] in
            do { try await sleep(Self.holdMs) } catch { return }
            guard let self, let turn, self.held === turn else { return }
            self.held = nil
            if turn.epoch == self.epoch, self.utterance == nil {
                self.acceptTranscript(epoch: turn.epoch, utteranceID: turn.id, text: turn.text)
            }
        }
        held = turn
    }

    private func acceptTranscript(epoch: Int, utteranceID: String, text: String) {
        pushHistory(.user(text))
        deps.emit(["type": "input.transcription.completed", "epoch": epoch, "utterance_id": utteranceID,
                   "source": "microphone", "transcript": text])
    }

    private func respond(epoch: Int) throws -> Task<Void, Error> {
        guard response == nil else { throw BridgeError("response already active") }
        let config = config!
        let run = Response()
        responseGeneration += 1
        let generation = responseGeneration
        response = run
        responseSequence += 1
        let item = "local-\(epoch)-\(Int(deps.now()))-\(responseSequence)"
        responseItem = item
        let record = SpokenItem()
        spoken[item] = record
        spokenOrder.append(item)
        if spokenOrder.count > Self.maxSpokenItems { spoken[spokenOrder.removeFirst()] = nil }
        // Every tool call needs a result before the next model request; a later real result replaces this one.
        for pending in unanswered where insertToolResult(.tool(callID: pending.callID, name: pending.name,
                                                               result: Self.unfinishedTool)) {
            placeholders[pending.callID] = pending.epoch
        }
        unanswered.removeAll()
        deps.emit(["type": "response.created", "epoch": epoch, "response": ["id": item]])

        let request = ChatRequest(model: deps.model, history: history, tools: config.tools,
                                  reasoningEffort: deps.reasoningEffort ?? "none", maxTokens: 300)
        let task = Task<Void, Error> {
            defer { if self.response === run { self.response = nil } }
            var calls: [Int: HistoryEntry.ToolCall] = [:]
            var callOrder: [Int] = []
            var chunker = SentenceChunker()
            var fullText = ""
            var speechCount = 0
            var speech: Task<Void, Error>?
            func queueSpeech(_ raw: String) {
                let text = VoiceText.stripMarkdown(raw)
                guard !text.isEmpty, speechCount < Self.maxSpeechChunks else { return }
                speechCount += 1
                let previous = speech
                let next = Task<Void, Error> {
                    try await previous?.value
                    try await self.speak(text, voice: config.voice, item: item, epoch: epoch, generation: generation, run: run)
                }
                run.tasks.append(next)
                speech = next
            }
            do {
                for try await event in deps.stream(request) {
                    if epoch != self.epoch || run.aborted { return }
                    switch event {
                    case .text(let delta):
                        fullText += delta
                        chunker.push(delta).forEach(queueSpeech)
                    case .toolStart(let index, let id, let name):
                        guard calls.count < 32 else { throw BridgeError("too many tool calls in one response") }
                        calls[index] = .init(id: try Self.requiredID(id), name: try Self.requiredID(name), arguments: "")
                        callOrder.append(index)
                    case .toolDelta(let index, let arguments):
                        guard calls[index] != nil else { throw BridgeError("tool arguments arrived before tool start") }
                        calls[index]!.arguments += arguments
                        guard calls[index]!.arguments.utf8.count <= 100_000 else { throw BridgeError("tool arguments too large") }
                    case .reasoning, .toolStop, .usage, .done: break
                    }
                }
                queueSpeech(chunker.flush())
                try await speech?.value
                if epoch != self.epoch || run.aborted { return }

                let toolCalls = callOrder.compactMap { calls[$0] }
                for call in toolCalls { try Self.validate(call, tools: config.tools) }
                let assistant = HistoryEntry.assistant(fullText.isEmpty ? nil : fullText, calls: toolCalls)
                pushHistory(assistant)
                record.message = assistant
                let spokenText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !spokenText.isEmpty {
                    deps.emit(["type": "response.audio_transcript.done", "epoch": epoch, "item_id": item,
                               "transcript": spokenText])
                }
                for call in toolCalls {
                    unanswered.append(Pending(callID: call.id, name: call.name, epoch: epoch))
                    deps.emit(["type": "response.function_call_arguments.done", "epoch": epoch, "call_id": call.id,
                               "name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments])
                }
                deps.emit(["type": "response.done", "epoch": epoch])
            } catch {
                if epoch == self.epoch, generation == responseGeneration, !run.aborted {
                    deps.emit(["type": "error", "epoch": epoch, "error": ["message": error.localizedDescription]])
                    deps.emit(["type": "response.done", "epoch": epoch])
                }
            }
        }
        run.tasks.append(task)
        return task
    }

    private func speak(_ text: String, voice: String, item: String, epoch: Int, generation: Int, run: Response) async throws {
        func current() -> Bool { epoch == self.epoch && generation == responseGeneration && !run.aborted }
        guard current() else { return }
        let speech = try await deps.synthesize(text, voice, epoch, generation)
        guard current() else { return }
        let pcm = try PCM.toPCM24(PCM.trimSilence(speech.samples, sampleRate: speech.sampleRate), sampleRate: speech.sampleRate)
        guard let record = spoken[item] else { return }
        var endSamples = record.chunks.map { ($0.endMs * 24).rounded() }.max() ?? 0
        var offset = 0
        while offset < pcm.count {
            guard current() else { return }
            let packet = pcm.subdata(in: offset..<min(offset + 960, pcm.count))
            deps.emit(["type": "response.audio.delta", "epoch": epoch, "item_id": item,
                       "delta": packet.base64EncodedString()])
            offset += 960
        }
        endSamples += Double(pcm.count / 2)
        record.chunks.append(SpokenChunk(text: text, endMs: endSamples / 24))
    }

    private func acceptToolOutputs(epoch outputEpoch: Int, outputs: [JSONValue]) throws {
        guard outputs.count <= 32 else { throw BridgeError("too many tool outputs") }
        for output in outputs {
            let result = try Self.boundedText(output["output"]?.string)
            let callID = output["call_id"]?.string ?? ""
            let name = output["name"]?.string ?? ""
            if let index = unanswered.firstIndex(where: { $0.callID == callID }),
               unanswered[index].name == name, unanswered[index].epoch == outputEpoch {
                unanswered.remove(at: index)
                insertToolResult(.tool(callID: callID, name: name, result: result))
                continue
            }
            guard placeholders[callID] == outputEpoch,
                  let placeholder = history.first(where: { $0.role == .tool && $0.callID == callID && $0.name == name })
            else { throw BridgeError("unknown or replayed tool output") }
            placeholders[callID] = nil
            placeholder.text = result
        }
    }

    /// Chat APIs require tool results directly after the assistant message that made the calls.
    @discardableResult
    private func insertToolResult(_ entry: HistoryEntry) -> Bool {
        guard let owner = history.firstIndex(where: { candidate in
            candidate.role == .assistant && candidate.toolCalls.contains { $0.id == entry.callID }
        }) else { return false } // trimmed out of history along with its call
        var index = owner + 1
        while index < history.count, history[index].role == .tool { index += 1 }
        history.insert(entry, at: index)
        trimHistory()
        return history.contains { $0 === entry }
    }

    private func truncate(item: String, heardMs: Double) {
        guard let record = spoken[item] else { return }
        let heard = record.chunks.filter { $0.endMs <= max(0, heardMs) }
        // Speech chunks can end mid-sentence; a small model copies half-sentences it finds in its own history.
        let text = VoiceText.heardSentences(heard.map(\.text).joined(separator: " "))
        if let message = record.message {
            message.text = text.isEmpty ? nil : text
            if text.isEmpty, message.toolCalls.isEmpty { history.removeAll { $0 === message } }
        }
        record.chunks = heard
        if item == responseItem { cancel() }
        deps.emit(["type": "response.transcript.truncated", "epoch": epoch, "item_id": item, "transcript": text])
    }

    /// The app disconnected: stop the reply in progress and any held turn.
    public func close() {
        cancel()
        held?.timer?.cancel()
        held = nil
    }

    private func cancel() {
        let generation = responseGeneration
        responseGeneration += 1
        deps.cancelSynthesis(epoch, generation)
        response?.abort()
        response = nil
    }

    private func pushHistory(_ entry: HistoryEntry) {
        history.append(entry)
        trimHistory()
    }

    private func trimHistory() {
        while history.count > Self.maxHistory {
            guard let nextTurn = history.indices.first(where: { $0 > 1 && history[$0].role == .user }) else { break }
            history.removeSubrange(1..<nextTurn)
        }
        let calls = Set(history.flatMap { $0.toolCalls.map(\.id) })
        let results = Set(history.compactMap { $0.role == .tool ? $0.callID : nil })
        unanswered.removeAll { !calls.contains($0.callID) }
        placeholders = placeholders.filter { results.contains($0.key) }
    }

    static func requiredID(_ value: String?) throws -> String {
        guard let value, value.firstMatch(#"^[A-Za-z0-9._:-]{1,200}$"#) != nil else { throw BridgeError("invalid identifier") }
        return value
    }

    static func boundedText(_ value: String?) throws -> String {
        guard let value, value.count <= 1_000_000 else { throw BridgeError("text too large") }
        return value
    }

    /// Rejects a call the app's schemas don't allow before it can reach the app: unknown tool, bad JSON, a missing
    /// required argument, or an argument of the wrong type or outside its enum.
    static func validate(_ call: HistoryEntry.ToolCall, tools: [JSONValue]) throws {
        guard let tool = tools.first(where: { $0["name"]?.string == call.name }) else {
            throw BridgeError("unknown tool \(call.name)")
        }
        guard let parsed = try? JSONValue.parse(Data((call.arguments.isEmpty ? "{}" : call.arguments).utf8)),
              let args = parsed.object
        else { throw BridgeError("invalid JSON arguments for \(call.name)") }
        let schema = tool["parameters"]
        for key in schema?["required"]?.array?.compactMap(\.string) ?? [] where args[key] == nil {
            throw BridgeError("missing required \(call.name).\(key)")
        }
        for (key, value) in args {
            guard let field = schema?["properties"]?[key] else { continue }
            if let options = field["enum"]?.array, !options.contains(value) {
                throw BridgeError("invalid enum \(call.name).\(key)")
            }
            let valid: Bool
            switch field["type"]?.string {
            case "string": valid = value.string != nil
            case "boolean": valid = value.bool != nil
            case "integer": valid = value.safeInteger != nil
            case "number": valid = value.number != nil
            case "array": valid = value.array != nil
            case "object": valid = value.object != nil
            default: valid = true
            }
            if !valid { throw BridgeError("invalid type \(call.name).\(key)") }
        }
    }
}

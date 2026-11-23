import Testing
@testable import HerdrVoiceCore

@Test func menuListsBothLocalBackendsThenGrokGPTGeminiWithTheCurrentOneChecked() {
    let entries = ModelMenu.entries(current: .gemini, currentBackend: .native, hasKey: { _ in true }, localIsReady: { _ in true })
    #expect(entries.map(\.title) == ["Local native", "Local OpenLive", "Grok", "GPT", "Gemini"])
    #expect(entries.map(\.checked) == [false, false, false, false, true])
    #expect(entries.map(\.backend) == [.native, .openlive, nil, nil, nil])
    #expect(entries.allSatisfy { $0.enabled })
}

@Test func onlyTheRunningLocalBackendIsChecked() {
    let entries = ModelMenu.entries(current: .local, currentBackend: .openlive, hasKey: { _ in true }, localIsReady: { _ in true })
    #expect(entries.map(\.checked) == [false, true, false, false, false])
}

@Test func modelsWithoutAKeyAreShownButDisabled() {
    let entries = ModelMenu.entries(current: .grok, currentBackend: .native, hasKey: { $0 != .openai }, localIsReady: { _ in true })
    #expect(entries[0] == ModelMenu.Entry(provider: .local, backend: .native, title: "Local native", checked: false, enabled: true))
    #expect(entries[3] == ModelMenu.Entry(provider: .openai, title: "GPT (no key)", checked: false, enabled: false))
    #expect(entries[2].enabled && entries[4].enabled)
}

@Test func eachLocalBackendIsShownButDisabledUntilSetUp() {
    let entries = ModelMenu.entries(current: .grok, currentBackend: .native, hasKey: { _ in true }, localIsReady: { $0 == .openlive })
    #expect(entries[0] == ModelMenu.Entry(provider: .local, backend: .native, title: "Local native (not set up)",
                                          checked: false, enabled: false))
    #expect(entries[1] == ModelMenu.Entry(provider: .local, backend: .openlive, title: "Local OpenLive", checked: false, enabled: true))
    #expect(entries.dropFirst(2).allSatisfy { $0.enabled })
}

@Test func theLocalBackendIsTheConfiguredOneElseNativeOnceSetUp() throws {
    let both: (LocalBackend) -> Bool = { _ in true }, onlyOpenLive: (LocalBackend) -> Bool = { $0 == .openlive }
    #expect(try LocalBackend.choose(environment: ["HERDR_VOICE_LOCAL_BACKEND": "openlive"], isReady: both) == .openlive)
    #expect(try LocalBackend.choose(environment: ["HERDR_VOICE_LOCAL_BACKEND": "Native"], isReady: onlyOpenLive) == .native)
    #expect(try LocalBackend.choose(environment: ["HERDR_VOICE_LOCAL_HELPER": "native"], isReady: onlyOpenLive) == .native)
    #expect(try LocalBackend.choose(environment: [:], isReady: both) == .native)
    #expect(try LocalBackend.choose(environment: [:], isReady: onlyOpenLive) == .openlive)
    #expect(try LocalBackend.choose(environment: [:], isReady: { _ in false }) == .native)
    #expect(throws: LocalBackend.ConfigError.self) {
        try LocalBackend.choose(environment: ["HERDR_VOICE_LOCAL_BACKEND": "ollama"], isReady: both)
    }
}

@Test func eachLocalBackendHasItsOwnBrainDefaults() {
    #expect(LocalBackend.native.defaultBrainURL == "http://127.0.0.1:8000/v1")
    #expect(LocalBackend.openlive.defaultBrainURL == "http://127.0.0.1:11434/v1")
    #expect(LocalBackend.openlive.defaultBrainModel == "qwen3.5:4b")
}

@Test func localProviderNeedsNoAPIKey() {
    #expect(!Provider.local.requiresAPIKey)
    #expect(Provider.local.apiKey(environment: [:]) == nil)
    #expect(Provider.local.defaultVoice == "af_heart")
}

@Test func theConfiguredVoiceOnlyAppliesToTheProviderItNamesAVoiceOf() {
    // Started on Grok with HERDR_VOICE_VOICE=rex: Grok keeps Rex; GPT and Gemini use their own defaults,
    // since "rex" isn't one of their voices. Switching back to Grok brings Rex back.
    #expect(Provider.grok.voice(startedWith: .grok, configured: "rex") == "rex")
    #expect(Provider.openai.voice(startedWith: .grok, configured: "rex") == "marin")
    #expect(Provider.gemini.voice(startedWith: .grok, configured: "rex") == "Kore")
    #expect(Provider.grok.voice(startedWith: .grok, configured: nil) == "eve")
    #expect(Provider.gemini.voice(startedWith: .gemini, configured: "Puck") == "Puck")
    #expect(Provider.local.voice(startedWith: .local, configured: "af_bella") == "af_bella")
}

@Test func theDefaultProviderIsLocalOnceSetUpElseGrok() {
    #expect(Provider.defaultChoice(localIsBuilt: true) == .local)
    #expect(Provider.defaultChoice(localIsBuilt: false) == .grok)
}

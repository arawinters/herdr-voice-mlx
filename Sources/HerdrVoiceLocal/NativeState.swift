import Foundation

/// The native backend's setup record. Its presence is how the app's menu knows `herdr-voice-local setup` finished,
/// without loading a model. Same path as LocalState.nativeSetupRecord in HerdrVoiceCore.
public enum NativeState {
    public static func setupRecord(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
            .appendingPathComponent(".local/state/herdr-voice/native/setup.json")
    }
}

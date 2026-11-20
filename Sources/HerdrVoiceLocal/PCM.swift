import Foundation

/// Audio conversions between the app's wire format (PCM16 mono at 24 kHz) and the speech models.
public enum PCM {
    /// Turn-taking thresholds from upstream OpenLive's voice engine: speech-level RMS in 20 ms frames.
    public static let voicedRMS: Float = 0.006

    /// Little-endian PCM16 at `fromRate` to float samples at `toRate`, by linear interpolation.
    public static func resampleInt16(_ data: Data, from fromRate: Int, to toRate: Int) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var input = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count { input[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        let outputCount = count * toRate / fromRate
        var output = [Float](repeating: 0, count: outputCount)
        let step = Double(fromRate) / Double(toRate)
        for i in 0..<outputCount {
            let position = Double(i) * step
            let left = Int(position)
            let fraction = Float(position - Double(left))
            output[i] = input[left] * (1 - fraction) + input[min(left + 1, count - 1)] * fraction
        }
        return output
    }

    /// Milliseconds of 16 kHz audio loud enough to be speech, in 20 ms frames.
    public static func voicedMs(_ audio: [Float]) -> Int {
        var voiced = 0
        var start = 0
        while start + 320 <= audio.count {
            var sum: Float = 0
            for i in start..<(start + 320) { sum += audio[i] * audio[i] }
            if (sum / 320).squareRoot() >= voicedRMS { voiced += 20 }
            start += 320
        }
        return voiced
    }

    /// Kokoro pads every sentence with silence at each end, which plays as long gaps between sentences. Keeps a
    /// 40 ms lead-in and a 150 ms pause instead. All-quiet audio is returned as is.
    public static func trimSilence(_ audio: [Float], sampleRate: Int) -> ArraySlice<Float> {
        let frame = max(1, Int((Double(sampleRate) / 100).rounded()))
        func loud(_ start: Int) -> Bool {
            var peak: Float = 0
            for i in start..<min(start + frame, audio.count) { peak = max(peak, abs(audio[i])) }
            return peak >= 0.01
        }
        var first = 0
        while first < audio.count, !loud(first) { first += frame }
        if first >= audio.count { return audio[...] }
        var last = audio.count - frame
        while last > first, !loud(last) { last -= frame }
        let lead = Int((Double(sampleRate) * 0.04).rounded()), tail = Int((Double(sampleRate) * 0.15).rounded())
        return audio[max(0, first - lead)..<min(audio.count, last + frame + tail)]
    }

    public enum AudioError: LocalizedError, Equatable {
        case invalid, nonFinite
        public var errorDescription: String? {
            switch self {
            case .invalid: "invalid synthesized audio"
            case .nonFinite: "non-finite synthesized audio sample"
            }
        }
    }

    /// Float samples at `sampleRate` to little-endian PCM16 at 24 kHz. Rejects corrupt audio instead of playing it.
    public static func toPCM24(_ audio: ArraySlice<Float>, sampleRate: Int) throws -> Data {
        guard (8_000...192_000).contains(sampleRate), !audio.isEmpty else { throw AudioError.invalid }
        guard audio.allSatisfy(\.isFinite) else { throw AudioError.nonFinite }
        let samples = Array(audio)
        let count = samples.count * 24_000 / sampleRate
        var output = Data(count: count * 2)
        let step = Double(sampleRate) / 24_000
        output.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                let position = Double(i) * step
                let left = Int(position)
                let fraction = Float(position - Double(left))
                let sample = samples[left] * (1 - fraction) + samples[min(left + 1, samples.count - 1)] * fraction
                let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
                raw.storeBytes(of: value.littleEndian, toByteOffset: i * 2, as: Int16.self)
            }
        }
        return output
    }
}

# Speech engine spike: FluidAudio vs mlx-audio-swift

Picks the native speech engine for the Swift local helper (#5). Measured on 2026-11-19 on an Apple M5 Max with 64 GB
and macOS 27.2.1, with Splash 1.7.0 serving Qwen3.6-35B-A3B (`UD-Q4_K_M`) on the GPU.

| | FluidAudio v0.18.3 | mlx-audio-swift v0.2.0 |
|---|---|---|
| Runtime | CoreML, mostly on the Neural Engine | MLX on the GPU |
| License | Apache-2.0 | MIT |

## Method

Two throwaway harnesses, one per engine, use each library's own API. Neither is checked in.

- **Speech-to-text:** 17 short herdr commands, 16 kHz. They are 8 phrases each spoken by two macOS `say` voices, plus
  the demo's public fixture. Five warm runs per file, median reported. These are clean synthetic voices, not live
  microphone audio, so accuracy is only comparable between the two engines.
- **Text-to-speech:** two one-sentence replies (57 and 40 characters), five warm runs each. "First audio" is when the
  first samples are ready.
- **GPU contention:** Splash decode throughput (400-token completions) alone, then while a loop runs speech-to-text and
  Kokoro back to back. Separately, text-to-speech while Splash decodes continuously.

Baseline from the current Electron path (`docs/local-openlive.md`, same machine): Whisper tiny.en 145 ms, Kokoro
first sentence 204 ms.

## Results

### Speech-to-text, batch Parakeet TDT 0.6b (after the end of speech)

| | FluidAudio | mlx-audio-swift |
|---|---|---|
| v2 (English), median | 33–36 ms | 11–15 ms |
| v3 (multilingual), median | 30–35 ms | 11–15 ms |
| Peak memory | 530 MB | 2.8 GB |
| Model download (v2) | 451 MB (int8 encoder) | 2.3 GB |

Same transcripts on both, because it's the same model. v2 had no real errors ("Herdr" → "herder", "claude-2" →
"Claude 2"; the brain resolves both). v3 once heard "claude-2" as "Claw2".

FluidAudio's streaming Parakeet EOU (120M) model decodes while you speak (`finish()` takes 3 ms) and detects the end
of an utterance. It is much less accurate on names ("claude-2" → "lord do", "build" → "bill"), and its endpoint delay
ranged from 160 to 1,920 ms (median about 480 ms), with a miss now and then. At most it is a hint for ending the turn
early. Batch Parakeet should still do the transcription.

### Text-to-speech

| Median ms (57 / 40 chars) | Splash idle | Splash decoding |
|---|---|---|
| FluidAudio Kokoro (ANE v3), whole sentence | 136 / 106 | 156 / 114 |
| FluidAudio PocketTTS, first audio (streaming) | **18 / 18** | **20 / 21** |
| FluidAudio PocketTTS, whole sentence | 656 / 427 | 686 / 468 |
| mlx Kokoro (bf16), whole sentence | **66 / 50** | **94 / 74** |
| mlx PocketTTS, first audio (streaming) | 99 / 99 | 155 / 151 |
| mlx PocketTTS, whole sentence | 242 / 133 | 321 / 230 |

Kokoro produces 4.1 s and 3.1 s of audio for these, so every option generates faster than real time.

### GPU contention with the brain

| Splash decode, warm runs | Alone | With speech loop running |
|---|---|---|
| FluidAudio | 195–209 tok/s | **200–215 tok/s (no change)** |
| mlx-audio-swift | 205–211 tok/s | **151–156 tok/s (−26%)** |

### Footprint

| | FluidAudio | mlx-audio-swift |
|---|---|---|
| Package dependencies | none (one prebuilt text-normalization xcframework, droppable with Swift 6.2 traits) | mlx-swift, swift-transformers, swift-huggingface, zstd, and 7 more transitive |
| Build requirement | Xcode | Xcode plus the Metal Toolchain component (839 MB) |
| Harness binary, stripped | 14 MB | 31 MB, plus a 4.5 MB Metal library |
| Models for Parakeet v2 + Kokoro | ~630 MB | ~2.6 GB |

## Decision

**FluidAudio.** mlx-audio-swift is faster in isolation, about 20 ms on speech-to-text and 40–70 ms on Kokoro. But it
shares the GPU with Splash: the brain loses about a quarter of its speed while speech runs, and in a real turn they
overlap (the first sentence is spoken while the rest is generated, and tool chains run several brain requests). On the
Neural Engine, FluidAudio leaves the brain alone. It also uses about a quarter of the memory and download, has no
package dependencies, and needs no Metal Toolchain to build, which matters for every contributor and the macOS CI
runner.

Both engines put speech far below the current cost. A rough estimate for the native path is speech-to-text 33 ms,
brain about 95 ms, and first audio 20–140 ms (PocketTTS streaming or Kokoro), plus handoffs: 150–300 ms against
today's 531 ms median. The 560 ms of silence that ends a turn is then the largest wait, so endpointing is the next
thing to tune (#7).

**Voice: Kokoro ANE v3**, `af_heart` by default as today. In a listening comparison of the same reply, Kokoro sounded
better than PocketTTS (`alba`, `anna`, `eve`), although PocketTTS starts about 120 ms sooner because it streams. Kokoro
has 28 English voices (American and British, female and male), each downloaded on first use; `HERDR_VOICE_VOICE`
already selects the local voice, and #5 should accept any of them.

Open for #5: whether the EOU model is worth running alongside batch Parakeet, only as an early end-of-turn hint.

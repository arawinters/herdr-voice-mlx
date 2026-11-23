# Local native

Local native runs the voice entirely on your Mac with no Node, pnpm, Electron or Ollama. The app keeps its usual mic
with echo cancellation, orb, confirmation gate, watches, recap and Swift tools. A native helper, `herdr-voice-local`,
does the rest:

- **Speech** runs on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio). Parakeet
  TDT v2 transcribes and Kokoro speaks, with the `af_heart` voice by default. See
  [the speech engine spike](speech-engine-spike.md) for why these were chosen.
- **The brain** is any OpenAI-compatible chat server on loopback. By default that's
  [Splash](https://github.com/incoai/splash) serving Qwen3.6-35B-A3B. Speech stays on the Neural Engine and leaves the
  GPU to the brain.

It sits next to [Local OpenLive](local-openlive.md) rather than replacing it. Both helpers speak the same LocalWire
protocol, so either one can run Local mode, and you can switch between them from the orb.

## Requirements

| | |
|---|---|
| Mac | Apple silicon. Splash needs an M3 or later |
| macOS | Splash needs macOS 26.4 or later |
| Swift | Xcode or the Command Line Tools, the same as for herdr-voice itself |
| Brain | Splash, or another OpenAI-compatible server on `127.0.0.1` |
| Disk | About 630 MB for the speech models, plus the brain's model |

## Setup and run

Start the brain first and leave it running:

```bash
splash serve --model unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M
```

Then, from a checkout:

```bash
./scripts/native-setup
```

`native-setup` builds herdr-voice and `herdr-voice-local`, downloads the speech models, and then checks everything
works. The helper speaks a sentence, transcribes it back, and sends the brain a two-token request. When those pass, it
writes `~/.local/state/herdr-voice/native/setup.json`. That file is what turns **Local native** on in the orb's menu.
Setup is the only step that goes online.

`./scripts/native-check` runs the same checks without going online: it loads the models in offline mode and fails if
any are missing.

After setup, Local mode uses the native helper by default. Start the voice as usual with `herdr-voice`, or with
`herdr-voice --here --provider local` from the checkout.

**From the installed plugin.** The plugin build compiles `herdr-voice-local` alongside `herdr-voice`. The models and the
setup record live outside the plugin folder, so once `native-setup` has run from any checkout, the plugin's copy uses
them too, and updates keep them. The voice pane only reads `config.env`, not your shell, so put any brain settings
there (`herdr plugin config-dir brogrammermw.herdr-voice`).

**Where the models live.** They're in FluidAudio's default folders, `~/Library/Application Support/FluidAudio/Models`
and `~/.cache/fluidaudio/Models`. At runtime FluidAudio's offline mode is on, so a missing model stops startup
instead of starting a download.

## Choosing the backend

The orb's right-click menu lists **Local native** and **Local OpenLive** next to the cloud models. Picking the other
local backend while Local is running replaces its helper, and the conversation carries over. A backend that hasn't
been set up is greyed out with "(not set up)".

`HERDR_VOICE_LOCAL_BACKEND` chooses the backend Local mode starts with:

| Value | Meaning |
|---|---|
| unset | Native once it's set up; OpenLive if only that is set up |
| `native` | The native helper |
| `openlive` | The Electron OpenLive helper |

An unknown value stops Local mode from starting, with an error. `HERDR_VOICE_LOCAL_HELPER=native` still works; it was the name of this
setting before the menu choice existed.

## Brain settings

These are the same variables as [Local OpenLive's](local-openlive.md#brain-settings), with different defaults. The
native helper supports only the `openai-chat` protocol. `native-setup` and `native-check` read them from your shell,
so export them before you run either script.

| Variable | Native default |
|---|---|
| `HERDR_VOICE_LOCAL_BRAIN_URL` | `http://127.0.0.1:8000/v1` (Splash) |
| `HERDR_VOICE_LOCAL_BRAIN_MODEL` | `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M` |
| `HERDR_VOICE_LOCAL_BRAIN_PROTOCOL` | `openai-chat` (the only one supported) |
| `HERDR_VOICE_LOCAL_BRAIN_REASONING` | not sent |

For a local brain, the helper checks before it says ready that `/models` lists that exact model ID, then runs one
inference probe. Hybrid brains (`KIND=keyed` or `custom`) work the same way as with OpenLive, as long as they speak
OpenAI Chat Completions, and skip that check. Speech stays local; only the text goes to the named provider.

## Failure behavior

Every failure is reported. Nothing falls back to the cloud.

- **A model is missing.** The helper exits before it says ready, and herdr-voice logs the error. Run `native-setup`.
- **The brain is down or doesn't list the model.** The brain check fails and startup stops, with the connection
  error or "local brain model … is not served at …".
- **The helper crashes after startup.** herdr-voice relaunches it and reconnects, the same as for OpenLive.

## Demo

The demo replays a recorded question through the native helper and a real `list_agents` call:

```bash
./scripts/local-openlive-demo --helper "$PWD/.build/release/herdr-voice-local"
```

## Latency

The demo measures from the end of the question to the first audible reply. On an Apple M5 Max with Splash 1.7.0
serving Qwen3.6-35B-A3B (`UD-Q4_K_M`), eight warm runs each made one real `list_agents` call. They took 328–381 ms,
with a median of 354 ms, so all eight were under 500 ms. OpenLive on the same setup had a median of 518 ms.

| Stage | Median ms |
|---|---|
| Parakeet speech-to-text | 57 |
| Splash, to the first tool call | 87 |
| Kokoro, first sentence | about 80 |

Splash's prompt-prefix cache matters most. It only hits when the request is byte-identical up to the conversation
history, so the helper serializes requests with sorted keys. Before that fix, every request paid about 900 ms of
prefill.

The demo starts timing when the question ends. It leaves out the 560 ms of silence that marks the end of a turn, and
the time between the first audio sample and the sound actually coming out of the speaker.

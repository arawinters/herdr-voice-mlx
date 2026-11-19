// The local brain that setup and check probe, read the way Swift's LocalRuntime reads it, so they test the brain
// the plugin will actually use. Returns undefined when nothing is set (main.ts then uses its Ollama default) or for a
// hybrid brain, whose Keychain key only the Swift app reads.
export function brainFromEnv(env = process.env) {
  const setting = (name) => env[`HERDR_VOICE_LOCAL_BRAIN_${name}`] ?? env[`HERDR_LOCAL_BRAIN_${name}`];
  if ((setting("KIND") ?? "local") !== "local") return undefined;
  const model = setting("MODEL"), baseURL = setting("URL"), protocol = setting("PROTOCOL"), reasoning = setting("REASONING");
  if (!model && !baseURL && !protocol && !reasoning) return undefined;
  const brain = {
    kind: "local",
    model: model ?? "qwen3.5:4b",
    baseURL: baseURL ?? "http://127.0.0.1:11434/v1",
    protocol: protocol ?? "openai-chat",
  };
  if (reasoning) brain.reasoningEffort = reasoning;
  return brain;
}

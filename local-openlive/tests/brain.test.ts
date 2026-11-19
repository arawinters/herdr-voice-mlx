import { describe, expect, it } from "vitest";
import { brainLabel, listsModel, modelsURL, validateBrain } from "../src/brain.js";

describe("local brain configuration", () => {
  it("defaults the loopback brain to OpenAI Chat without a key", () => {
    const brain = validateBrain({ kind: "local", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3.5:4b" });
    expect(brain.protocol).toBe("openai-chat");
    expect(brainLabel(brain)).toBe("Local OpenLive / qwen3.5:4b");
  });

  it.each([
    [{ kind: "local", baseURL: "https://example.com/v1", model: "qwen3.5:4b" }, "loopback-only"],
    [{ kind: "local", baseURL: "http://127.0.0.1:11434/v1", model: "qwen-cloud" }, "cloud model"],
    [{ kind: "keyed", baseURL: "https://secret@example.com/v1", model: "remote", label: "Example", apiKey: "key" }, "credentials"],
    [{ kind: "keyed", baseURL: "https://example.com/v1", model: "remote", label: "Example" }, "Keychain API key"],
    [{ kind: "custom", baseURL: "https://example.com/v1", model: "remote" }, "hybrid label"],
  ] as const)("rejects unsafe or incomplete settings", (value, message) => {
    expect(() => validateBrain(value as Parameters<typeof validateBrain>[0])).toThrow(message);
  });

  it.each(["openai-chat", "openai", "anthropic"] as const)("accepts the pinned %s protocol", (protocol) => {
    expect(validateBrain({ kind: "custom", baseURL: "https://example.com", model: "model", label: "Example", protocol }).protocol)
      .toBe(protocol);
  });
});

describe("local brain model inventory", () => {
  it.each([
    ["http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1/models"],
    ["http://127.0.0.1:8000/v1/", "http://127.0.0.1:8000/v1/models"],
  ])("lists models under %s", (base, expected) => {
    expect(modelsURL(base).href).toBe(expected);
  });

  it("finds the model by its exact OpenAI model ID", () => {
    const body = { object: "list", data: [{ id: "qwen3.5:4b" }, { id: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M" }] };
    expect(listsModel(body, "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M")).toBe(true);
    expect(listsModel(body, "qwen3.5:4b")).toBe(true);
    expect(listsModel(body, "qwen3.5")).toBe(false);
  });

  it.each([null, {}, { data: "x" }, { models: [{ name: "qwen3.5:4b" }] }])("rejects a malformed list %#", (body) => {
    expect(listsModel(body, "qwen3.5:4b")).toBe(false);
  });
});

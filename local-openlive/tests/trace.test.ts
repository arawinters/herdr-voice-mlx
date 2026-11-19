import { describe, expect, it } from "vitest";
import { timed, timedStream, traceWriter } from "../src/trace.js";

describe("stage trace", () => {
  it("marks start and done around a call, even when it fails", async () => {
    const stages: string[] = [];
    const mark = (stage: string) => { stages.push(stage); };
    const ok = timed("stt", mark, async (n: number) => n * 2);
    expect(await ok(2)).toBe(4);
    const failing = timed("tts", mark, async () => { throw new Error("boom"); });
    await expect(failing()).rejects.toThrow("boom");
    expect(stages).toEqual(["stt.start", "stt.done", "tts.start", "tts.done"]);
  });

  it("marks the request, only the first text or tool event, and the end of a stream", async () => {
    const stages: string[] = [];
    async function* events() {
      yield { type: "reasoning" };
      yield { type: "tool_start" };
      yield { type: "text" };
    }
    const seen: string[] = [];
    for await (const event of timedStream((stage) => { stages.push(stage); }, () => events())({}, new AbortController().signal)) {
      seen.push(event.type);
    }
    expect(seen).toEqual(["reasoning", "tool_start", "text"]);
    expect(stages).toEqual(["brain.request", "brain.first_tool", "brain.done"]);
  });

  it("writes one JSON line per mark with no payload beyond the stage and numbers", () => {
    const lines: string[] = [];
    traceWriter((line) => lines.push(line))("tts.start", { chars: 12 });
    const entry = JSON.parse(lines[0]);
    expect(lines[0].endsWith("\n")).toBe(true);
    expect(Object.keys(entry).sort()).toEqual(["at", "chars", "stage", "type"]);
    expect(entry).toMatchObject({ type: "trace", stage: "tts.start", chars: 12 });
  });
});

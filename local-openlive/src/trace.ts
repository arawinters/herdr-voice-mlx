// Opt-in stage timing (HERDR_VOICE_LOCAL_TRACE=1) for latency breakdowns. Marks are wall-clock milliseconds with
// sub-millisecond precision, so the demo process can line them up with its own. No text, audio or tool data is logged.
export type Mark = (stage: string, detail?: Record<string, number>) => void;

export function traceWriter(write: (line: string) => void): Mark {
  return (stage, detail) => write(`${JSON.stringify({ type: "trace", stage, at: wallClock(), ...detail })}\n`);
}

export function wallClock(): number {
  return performance.timeOrigin + performance.now();
}

type Stages<Args extends unknown[], Result> = (...args: Args) => Promise<Result>;

/** Marks `<name>.start` and `<name>.done` around each call. */
export function timed<Args extends unknown[], Result>(name: string, mark: Mark, call: Stages<Args, Result>,
                                                     detail?: (...args: Args) => Record<string, number>): Stages<Args, Result> {
  return async (...args) => {
    mark(`${name}.start`, detail?.(...args));
    try {
      return await call(...args);
    } finally {
      mark(`${name}.done`);
    }
  };
}

/** Marks the request, the first text or tool event, and the end of a provider stream. */
export function timedStream<Request, Event extends { type: string }>(
  mark: Mark, stream: (request: Request, signal: AbortSignal) => AsyncIterable<Event>,
): (request: Request, signal: AbortSignal) => AsyncIterable<Event> {
  return async function* (request, signal) {
    mark("brain.request");
    let first = true;
    for await (const event of stream(request, signal)) {
      if (first && (event.type === "text" || event.type === "tool_start")) {
        first = false;
        mark(event.type === "text" ? "brain.first_text" : "brain.first_tool");
      }
      yield event;
    }
    mark("brain.done");
  };
}

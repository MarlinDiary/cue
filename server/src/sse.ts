import type { Usage } from './openai';

export interface RelayHooks {
  /** Events sent before the stream's own. */
  head?: object[];
  /** Called as the stream's last event arrives, with everything written and the usage; its events go out first. */
  end(text: string, usage: Usage | undefined): Promise<object[]>;
  /** Called instead when the stream stops before its end: the app went away, or OpenAI stopped. */
  abort(text: string, usage: Usage | undefined): Promise<void>;
}

/** An event stream of `events`, all at once, in the shape OpenAI streams its own. */
export function eventStream(events: object[]): Response {
  const body = events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join('');
  return new Response(body, { headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' } });
}

/**
 * Passes OpenAI's event stream on to the app as it comes, line by line, noting the text written and, at the end, the
 * usage, so the request can be paid for before the app hears it is over.
 */
export function relay(upstream: Response, ctx: ExecutionContext, hooks: RelayHooks): Response {
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();
  const encoder = new TextEncoder();
  const send = (text: string) => writer.write(encoder.encode(text));
  const sendEvent = (event: object) => send(`data: ${JSON.stringify(event)}\n\n`);

  ctx.waitUntil((async () => {
    const reader = upstream.body!.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let text = '';
    let usage: Usage | undefined;
    let ended = false;
    // An `event:` line waits for its `data:` line, so events of our own never land between the two.
    let held = '';
    try {
      for (const event of hooks.head ?? []) await sendEvent(event);
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let newline: number;
        while ((newline = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, newline + 1);
          buffer = buffer.slice(newline + 1);
          if (line.startsWith('event:')) {
            held += line;
            continue;
          }
          if (line.startsWith('data:')) {
            let event: any;
            try {
              event = JSON.parse(line.slice(5));
            } catch {
              event = undefined;
            }
            if (event?.type === 'response.output_text.delta' && typeof event.delta === 'string') text += event.delta;
            if (event?.type === 'response.failed' || event?.type === 'response.incomplete') usage = event.response?.usage;
            if (event?.type === 'response.completed') {
              usage = event.response?.usage;
              ended = true;
              for (const extra of await hooks.end(text, usage)) await sendEvent(extra);
            }
          }
          await send(held + line);
          held = '';
        }
      }
      if (held || buffer) await send(held + buffer);
      await writer.close();
    } catch (error) {
      await reader.cancel().catch(() => {});
      await writer.abort(error).catch(() => {});
    } finally {
      if (!ended) await hooks.abort(text, usage);
    }
  })());

  return new Response(readable, { headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' } });
}

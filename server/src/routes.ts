import type { Account } from './account';
import { SignatureError, verifySigned } from './apple';
import { base64ToBytes, type Env, HttpError, json, sha256Hex } from './env';
import { counted, forIdea, keepPicture, lookup, remember } from './library';
import { credit, LIBRARY_HIT, POINT, points, reserve, settle } from './ledger';
import { imageCost, MODELS, openai, REFUSED_PICTURE_COST, speechCost, textCost, VOICE } from './openai';
import { prompts } from './prompts';
import { eventStream, relay } from './sse';

/** The packs the app sells, and the points each gives. */
export const PRODUCTS: Record<string, number> = {
  'com.chenye.cue.points.20': 20,
  'com.chenye.cue.points.48': 48,
  'com.chenye.cue.points.120': 120,
  'com.chenye.cue.points.240': 240,
};

/** What a new word holds until it is paid for, and what the account must have to start one: enough for its picture
 * too, so a word isn't left without one. */
const ENTRY_HOLD = 20_000;
const NEW_WORD = 40_000;
const PICTURE_HOLD = 20_000;
const BRIEF_HOLD = 10_000;
const CHAT_HOLD = 30_000;
const SPEECH_HOLD = 3_000;
const DECIDE_HOLD = 2_000;
const OFFER_HOLD = 2_000;

const insufficient = () => new HttpError(402, 'insufficient_points', 'Not enough points left.');

function pointsHeader(balance: number): Record<string, string> {
  return { 'X-Cue-Points': String(points(balance)) };
}

function text(value: unknown, name: string, max: number): string {
  if (typeof value !== 'string' || !value.trim() || value.length > max) {
    throw new HttpError(400, 'bad_request', `${name} is missing or too long.`);
  }
  return value;
}

/** An OpenAI error passed on as it came, so the app reads it as it reads OpenAI's own. */
function upstreamError(status: number, body: string, balance: number): Response {
  return new Response(body, { status, headers: { 'Content-Type': 'application/json', ...pointsHeader(balance) } });
}

export async function account(env: Env, account: Account): Promise<Response> {
  return json({ points: points(account.balance) }, 200, pointsHeader(account.balance));
}

/**
 * A word's entry, streamed as OpenAI streams it. A word someone has added before comes whole from the library, for
 * 0.2 points; `fresh` (an entry written again on purpose) always asks.
 */
export async function entry(request: Request, env: Env, ctx: ExecutionContext, account: Account): Promise<Response> {
  const body: any = await request.json();
  const input = text(body.input, 'input', 400);
  const fresh = body.fresh === true;
  if (!fresh) {
    const hit = await lookup(env, input);
    if (hit) {
      if (!(await reserve(env, account.id, LIBRARY_HIT))) throw insufficient();
      const balance = await settle(env, account.id, LIBRARY_HIT, LIBRARY_HIT, 'library', 0);
      ctx.waitUntil(counted(env, hit.key));
      return eventStream([
        { type: 'cue.entry', shared: true },
        { type: 'response.output_text.delta', delta: hit.entry },
        { type: 'cue.points', points: points(balance) },
        { type: 'response.completed', response: { status: 'completed' } },
      ]);
    }
  }
  if (!(await reserve(env, account.id, ENTRY_HOLD, NEW_WORD))) throw insufficient();
  const upstream = await openai(env, 'responses', {
    model: MODELS.entry,
    reasoning: { effort: 'low' },
    store: false,
    stream: true,
    instructions: prompts.entryInstructions,
    input,
    text: { format: { type: 'json_schema', name: 'word_entry', strict: true, schema: prompts.entrySchema } },
  });
  if (!upstream.ok) {
    const balance = await settle(env, account.id, ENTRY_HOLD, 0, 'entry', 0, 'failed');
    return upstreamError(upstream.status, await upstream.text(), balance);
  }
  return relay(upstream, ctx, {
    head: [{ type: 'cue.entry', shared: false }],
    async end(written, usage) {
      const cost = textCost(MODELS.entry, usage);
      const balance = await settle(env, account.id, ENTRY_HOLD, cost, 'entry', cost);
      if (!fresh) ctx.waitUntil(remember(env, input, written));
      return [{ type: 'cue.points', points: points(balance) }];
    },
    async abort(written, usage) {
      // Stopped early (the wall found the card it already had): what was written so far, and the instructions read.
      const cost = usage ? textCost(MODELS.entry, usage) : Math.ceil(2_200 * 2 + (written.length / 3) * 10);
      await settle(env, account.id, ENTRY_HOLD, cost, 'entry', cost, 'stopped');
    },
  });
}

/** A picture for a brief: the library's, when the brief is a library entry's and its picture is drawn, at no cost. */
export async function picture(request: Request, env: Env, ctx: ExecutionContext, account: Account): Promise<Response> {
  const body: any = await request.json();
  const idea = text(body.idea, 'idea', 800);
  const shared = await forIdea(env, idea);
  if (shared?.picture) {
    const object = await env.LIBRARY.get(shared.picture);
    if (object) {
      return new Response(object.body, {
        headers: { 'Content-Type': 'image/png', 'X-Cue-Shared': '1', ...pointsHeader(account.balance) },
      });
    }
  }
  if (!(await reserve(env, account.id, PICTURE_HOLD))) throw insufficient();
  const upstream = await openai(env, 'images/generations', {
    model: MODELS.picture,
    prompt: `${prompts.pictureStyle} Subject: ${idea.endsWith('.') ? idea.slice(0, -1) : idea}.`,
    size: '1024x1024',
    quality: 'medium',
    background: 'transparent',
    output_format: 'png',
  });
  const answer = await upstream.text();
  let parsed: any;
  try {
    parsed = JSON.parse(answer);
  } catch {
    parsed = undefined;
  }
  if (!upstream.ok) {
    // One the safety system turned down was drawn before it was judged.
    const cost = parsed?.error?.code === 'moderation_blocked' ? REFUSED_PICTURE_COST : 0;
    const balance = await settle(env, account.id, PICTURE_HOLD, cost, 'picture', cost, 'refused');
    return upstreamError(upstream.status, answer, balance);
  }
  const base64 = parsed?.data?.[0]?.b64_json;
  if (typeof base64 !== 'string') {
    const balance = await settle(env, account.id, PICTURE_HOLD, 0, 'picture', 0, 'empty');
    return upstreamError(502, JSON.stringify({ error: { message: 'The image service returned an empty picture.' } }), balance);
  }
  const png = base64ToBytes(base64);
  const cost = imageCost(parsed.usage);
  const balance = await settle(env, account.id, PICTURE_HOLD, cost, 'picture', cost);
  if (shared) ctx.waitUntil(keepPicture(env, shared.key, png));
  return new Response(png, { headers: { 'Content-Type': 'image/png', ...pointsHeader(balance) } });
}

/** A new brief for a picture the safety system turned down, answered as OpenAI answers. */
export async function brief(request: Request, env: Env, account: Account): Promise<Response> {
  const body: any = await request.json();
  const idea = text(body.idea, 'idea', 800);
  const headword = text(body.headword, 'headword', 400);
  const refusal = text(body.refusal, 'refusal', 4_000);
  const meaning = typeof body.meaning === 'string' && body.meaning ? ` (${body.meaning.slice(0, 400)})` : '';
  if (!(await reserve(env, account.id, BRIEF_HOLD))) throw insufficient();
  const upstream = await openai(env, 'responses', {
    model: MODELS.brief,
    reasoning: { effort: 'low' },
    store: false,
    instructions: prompts.saferBriefInstructions,
    input: `Word: ${headword}${meaning}\nBrief: ${idea}\nSafety system: ${refusal}`,
    text: { format: { type: 'json_schema', name: 'picture_brief', strict: true, schema: {
      type: 'object', additionalProperties: false, required: ['brief'], properties: { brief: { type: 'string' } },
    } } },
  });
  const answer = await upstream.text();
  let usage;
  try {
    usage = JSON.parse(answer)?.usage;
  } catch {
    usage = undefined;
  }
  const cost = upstream.ok ? textCost(MODELS.brief, usage) : 0;
  const balance = await settle(env, account.id, BRIEF_HOLD, cost, 'brief', cost);
  return upstreamError(upstream.status, answer, balance);
}

/**
 * An answer in a conversation, streamed as OpenAI streams it. The app sends what the conversation is about. In the wall's
 * conversation AI can hand over a deck of the wall's cards (`show_deck`); the decks it handed over come back with the
 * conversation as the calls it made.
 */
export async function chat(request: Request, env: Env, ctx: ExecutionContext, account: Account): Promise<Response> {
  const body: any = await request.json();
  const kind = body.kind === 'wall' ? 'wall' : body.kind === 'word' ? 'word' : null;
  if (!kind || !Array.isArray(body.lines) || body.lines.length > 5_000 || !Array.isArray(body.messages)
    || body.messages.length === 0 || body.messages.length > 180) {
    throw new HttpError(400, 'bad_request', 'The conversation is missing or too long.');
  }
  const lines = body.lines.map((line: unknown) => text(line, 'line', 4_000));
  const messages = body.messages.map((message: any) => {
    if (message?.type === 'function_call' && message.name === 'show_deck') {
      return { type: 'function_call', call_id: text(message.call_id, 'call', 200), name: 'show_deck',
        arguments: text(message.arguments, 'arguments', 20_000) };
    }
    if (message?.type === 'function_call_output') {
      return { type: 'function_call_output', call_id: text(message.call_id, 'call', 200),
        output: text(message.output, 'output', 400) };
    }
    if (message?.role !== 'user' && message?.role !== 'assistant') throw new HttpError(400, 'bad_request', 'Unknown role.');
    return { role: message.role, content: text(message.content, 'message', 12_000) };
  });
  if (!(await reserve(env, account.id, CHAT_HOLD))) throw insufficient();
  const upstream = await openai(env, 'responses', {
    model: MODELS.chat,
    reasoning: { effort: 'low' },
    store: false,
    stream: true,
    instructions: prompts.chat(kind, lines),
    input: messages,
    ...(kind === 'wall' ? { tools: [prompts.deckTool], parallel_tool_calls: false } : {}),
  });
  if (!upstream.ok) {
    const balance = await settle(env, account.id, CHAT_HOLD, 0, 'chat', 0, 'failed');
    return upstreamError(upstream.status, await upstream.text(), balance);
  }
  return relay(upstream, ctx, {
    async end(_written, usage) {
      const cost = textCost(MODELS.chat, usage);
      const balance = await settle(env, account.id, CHAT_HOLD, cost, 'chat', cost, kind);
      return [{ type: 'cue.points', points: points(balance) }];
    },
    async abort(written, usage) {
      const cost = usage ? textCost(MODELS.chat, usage)
        : Math.ceil((JSON.stringify(messages).length / 3) * 2 + (written.length / 2) * 10);
      await settle(env, account.id, CHAT_HOLD, cost, 'chat', cost, 'stopped');
    },
  });
}

/** A text read aloud, kept for everyone: a word anyone has heard plays for the next one at no cost. */
export async function speech(request: Request, env: Env, account: Account): Promise<Response> {
  const body: any = await request.json();
  const input = text(body.text, 'text', 1_000);
  const name = `speech/${await sha256Hex([MODELS.speech, VOICE, prompts.speechInstructions, input].join('\u001f'))}.mp3`;
  const kept = await env.LIBRARY.get(name);
  if (kept) return new Response(kept.body, { headers: { 'Content-Type': 'audio/mpeg', ...pointsHeader(account.balance) } });
  if (!(await reserve(env, account.id, SPEECH_HOLD))) throw insufficient();
  const upstream = await openai(env, 'audio/speech', {
    model: MODELS.speech, voice: VOICE, input, instructions: prompts.speechInstructions, response_format: 'mp3',
  });
  if (!upstream.ok) {
    const balance = await settle(env, account.id, SPEECH_HOLD, 0, 'speech', 0, 'failed');
    return upstreamError(upstream.status, await upstream.text(), balance);
  }
  const audio = new Uint8Array(await upstream.arrayBuffer());
  const cost = speechCost(input);
  const balance = await settle(env, account.id, SPEECH_HOLD, cost, 'speech', cost);
  await env.LIBRARY.put(name, audio, { httpMetadata: { contentType: 'audio/mpeg' } });
  return new Response(audio, { headers: { 'Content-Type': 'audio/mpeg', ...pointsHeader(balance) } });
}

/** Whether what is being typed is a card the wall already has, answered as OpenAI's Decisions API answers. */
export async function decide(request: Request, env: Env, account: Account): Promise<Response> {
  const body: any = await request.json();
  const input = text(body.input, 'input', 400);
  if (!Array.isArray(body.choices) || body.choices.length === 0 || body.choices.length > 5_000) {
    throw new HttpError(400, 'bad_request', 'The choices are missing or too many.');
  }
  const choices = body.choices.map((choice: any) => ({
    value: text(choice?.value, 'choice', 400),
    description: text(choice?.description ?? '-', 'description', 1_000),
  }));
  if (!(await reserve(env, account.id, DECIDE_HOLD))) throw insufficient();
  const upstream = await openai(env, 'decisions', {
    model: MODELS.decide,
    input,
    questions: [{ type: 'choice', name: 'card', instructions: prompts.decideInstructions, choices }],
  });
  const answer = await upstream.text();
  let usage;
  try {
    usage = JSON.parse(answer)?.usage;
  } catch {
    usage = undefined;
  }
  // Only the input is billed.
  const cost = upstream.ok
    ? Math.ceil((usage?.input_tokens ?? (JSON.stringify(choices).length + input.length) / 3) * 0.1)
    : 0;
  const balance = await settle(env, account.id, DECIDE_HOLD, cost, 'decide', cost);
  return upstreamError(upstream.status, answer, balance);
}

/** The words an answer just written offers to keep on the wall, answered as OpenAI answers. */
export async function offer(request: Request, env: Env, account: Account): Promise<Response> {
  const body: any = await request.json();
  const question = text(body.question, 'question', 12_000);
  const answer = text(body.answer, 'answer', 24_000);
  if (!Array.isArray(body.saved) || body.saved.length > 5_000) {
    throw new HttpError(400, 'bad_request', 'The saved words are missing or too many.');
  }
  const saved = body.saved.map((word: unknown) => text(word, 'saved word', 400));
  if (!(await reserve(env, account.id, OFFER_HOLD))) throw insufficient();
  const upstream = await openai(env, 'responses', {
    model: MODELS.offer,
    reasoning: { effort: 'low' },
    store: false,
    instructions: prompts.offer(saved),
    input: `Question:\n${question}\n\nAnswer:\n${answer}`,
    text: { format: { type: 'json_schema', name: 'offers', strict: true, schema: prompts.offerSchema } },
  });
  const reply = await upstream.text();
  let usage;
  try {
    usage = JSON.parse(reply)?.usage;
  } catch {
    usage = undefined;
  }
  const cost = upstream.ok ? textCost(MODELS.offer, usage) : 0;
  const balance = await settle(env, account.id, OFFER_HOLD, cost, 'offer', cost);
  return upstreamError(upstream.status, reply, balance);
}

/** A purchase made in the app, credited once: the app sends the transaction the App Store signed. */
export async function purchase(request: Request, env: Env, account: Account): Promise<Response> {
  const body: any = await request.json();
  let transaction: any;
  try {
    transaction = await verifySigned(text(body.transaction, 'transaction', 20_000), {
      allowXcode: env.ALLOW_XCODE_TRANSACTIONS === '1',
    });
  } catch (error) {
    if (error instanceof SignatureError) throw new HttpError(400, 'bad_transaction', error.message);
    throw error;
  }
  const count = PRODUCTS[transaction.productId];
  if (transaction.bundleId !== env.BUNDLE_ID || !count) throw new HttpError(400, 'bad_transaction', 'Unknown product.');
  if (String(transaction.appAccountToken ?? '').toLowerCase() !== account.id) {
    throw new HttpError(400, 'bad_transaction', 'The purchase was made for another account.');
  }
  if (transaction.revocationDate) throw new HttpError(400, 'bad_transaction', 'The purchase was refunded.');
  const inserted = await env.DB.prepare(`INSERT OR IGNORE INTO purchases
    (transaction_id, account, product, points, environment, revoked, created_at) VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6)`)
    .bind(String(transaction.transactionId), account.id, transaction.productId, count, String(transaction.environment),
      Date.now())
    .run();
  const balance = inserted.meta.changes > 0
    ? await credit(env, account.id, count * POINT, 'purchase', String(transaction.transactionId))
    : account.balance;
  return json({ points: points(balance) }, 200, pointsHeader(balance));
}

/**
 * What the App Store tells about purchases after the fact (App Store Server Notifications V2): a refunded pack takes
 * its points back, down below zero if they were spent.
 */
export async function appleNotification(request: Request, env: Env): Promise<Response> {
  const body: any = await request.json();
  const allowXcode = env.ALLOW_XCODE_TRANSACTIONS === '1';
  let notification: any;
  try {
    notification = await verifySigned(text(body.signedPayload, 'signedPayload', 50_000), { allowXcode });
  } catch (error) {
    if (error instanceof SignatureError) return json({ error: error.message }, 400);
    throw error;
  }
  if ((notification.notificationType === 'REFUND' || notification.notificationType === 'REVOKE')
    && notification.data?.signedTransactionInfo) {
    const transaction = await verifySigned(notification.data.signedTransactionInfo, { allowXcode });
    const row = await env.DB.prepare('SELECT account, points, revoked FROM purchases WHERE transaction_id = ?1')
      .bind(String(transaction.transactionId)).first<{ account: string; points: number; revoked: number }>();
    if (row && !row.revoked) {
      await env.DB.prepare('UPDATE purchases SET revoked = 1 WHERE transaction_id = ?1')
        .bind(String(transaction.transactionId)).run();
      await credit(env, row.account, -row.points * POINT, 'refund', String(transaction.transactionId));
    }
  }
  return json({ ok: true });
}

/** Local development only: points given, to try the app without buying. */
export async function grant(request: Request, env: Env, account: Account): Promise<Response> {
  if (env.DEV_GRANTS !== '1') throw new HttpError(404, 'not_found', 'Not found.');
  const body: any = await request.json();
  const count = Number(body.points);
  if (!Number.isFinite(count) || Math.abs(count) > 10_000) throw new HttpError(400, 'bad_request', 'Bad points.');
  const balance = await credit(env, account.id, Math.round(count * POINT), 'grant', 'development');
  return json({ points: points(balance) }, 200, pointsHeader(balance));
}

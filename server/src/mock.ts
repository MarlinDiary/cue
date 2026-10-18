// Local development only (MOCK_OPENAI=1): OpenAI's endpoints made up, in OpenAI's own shapes and with usage like the
// real one's, so the app and the server can be run end to end without a key and without spending anything. An idea
// with "REFUSE" in it is turned down once, as the safety system turns pictures down.

const PNG = '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';
const MP3 = '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';

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function bytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
}

/** A stream of `text` written a few characters at a time, as OpenAI streams a response, then any `items` done. */
function streamed(text: string, usage: object, items: object[] = []): Response {
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (type: string, event: object) =>
        controller.enqueue(encoder.encode(`event: ${type}\ndata: ${JSON.stringify({ type, ...event })}\n\n`));
      send('response.created', { response: { status: 'in_progress' } });
      await sleep(400);
      for (let i = 0; i < text.length; i += 12) {
        send('response.output_text.delta', { delta: text.slice(i, i + 12) });
        await sleep(25);
      }
      for (const item of items) send('response.output_item.done', { item });
      send('response.completed', { response: { status: 'completed', usage } });
      controller.close();
    },
  });
  return new Response(body, { headers: { 'Content-Type': 'text/event-stream' } });
}

function entryFor(input: string): object {
  const asked = /[㐀-鿿]/.test(input);
  const headword = asked ? 'Let me think about it.' : input.trim();
  return {
    headword,
    phoneticUS: asked || headword.includes(' ') ? '' : 'ˈmɑk',
    summary: asked ? '让我考虑一下。' : 'n. 模拟释义',
    pictureIdea: `A small wooden sign carved with a question mark, standing for ${headword}${input.includes('REFUSE') ? ' REFUSE' : ''}`,
    parts: asked ? [] : [{ pos: 'noun', senses: [{ chinese: '模拟释义', english: 'a made-up meaning for testing',
      example: `This is a sentence with ${headword} in it.`, exampleChinese: '这是一个带这个词的句子。' }] }],
    exchange: asked ? [{ english: 'Do you want it?', chinese: '你要吗？' }, { english: headword, chinese: '让我考虑一下。' }] : [],
    collocations: [],
    note: '模拟的用法说明。',
    etymology: null,
    question: asked ? `「${input}」用英语怎么说？` : null,
  };
}

const refused = new Set<string>();

export async function mock(path: string, body: any): Promise<Response> {
  if (path === 'responses' && body?.text?.format?.name === 'word_entry') {
    const input = String(body.input);
    return streamed(JSON.stringify(entryFor(input)), {
      input_tokens: 2156, input_tokens_details: { cached_tokens: 0 },
      output_tokens: 420, output_tokens_details: { reasoning_tokens: 60 },
    });
  }
  if (path === 'responses' && body?.text?.format?.name === 'picture_brief') {
    await sleep(600);
    return json({
      output: [{ type: 'message', content: [{ type: 'output_text', text: JSON.stringify({ brief: 'A small wooden sign carved with an exclamation mark' }) }] }],
      usage: { input_tokens: 900, input_tokens_details: { cached_tokens: 0 }, output_tokens: 80 },
    });
  }
  if (path === 'responses' && body?.text?.format?.name === 'split') {
    await sleep(400);
    // The English words named in a line, each its own card when there are several; anything else whole.
    const text = String(body.input);
    const named = text.match(/[A-Za-z][A-Za-z' -]*[A-Za-z]/g)?.map((word) => word.trim()) ?? [];
    return json({
      output: [{ type: 'message', content: [{ type: 'output_text', text: JSON.stringify({ items: named.length > 1 ? named : [text] }) }] }],
      usage: { input_tokens: 420, input_tokens_details: { cached_tokens: 0 }, output_tokens: 30 },
    });
  }
  if (path === 'responses' && body?.text?.format?.name === 'note') {
    await sleep(500);
    // Kept unless the question is a greeting-sized one.
    const question = String(body.input).split('\n')[1] ?? '';
    const keep = question.length > 6;
    return json({
      output: [{ type: 'message', content: [{ type: 'output_text', text: JSON.stringify({ keep,
        question: keep ? '这个词能用在正式邮件里吗？' : '', answer: keep ? '可以，这是模拟的要点。比如 Thank you for your candid feedback.' : '' }) }] }],
      usage: { input_tokens: 900, input_tokens_details: { cached_tokens: 0 }, output_tokens: 60 },
    });
  }
  if (path === 'responses' && body?.text?.format?.name === 'offers') {
    await sleep(500);
    const saved = new Set((String(body.instructions).split('Their saved words:\n')[1] ?? '').split('\n').map((word) => word.trim().toLowerCase()));
    const offers = [{ word: 'frank', meaning: 'adj. 直率的' }, { word: 'blunt', meaning: 'adj. 说话生硬的' },
      { word: 'outspoken', meaning: 'adj. 直言不讳的' }, { word: 'forthright', meaning: 'adj. 坦诚的' },
      { word: 'straightforward', meaning: 'adj. 直截了当的' }, { word: 'plain-spoken', meaning: 'adj. 说话直白的' },
      { word: 'upfront', meaning: 'adj. 坦率的' }, { word: 'tactless', meaning: 'adj. 说话不得体的' }]
      .filter((offer) => !saved.has(offer.word)).slice(0, 2);
    return json({
      output: [{ type: 'message', content: [{ type: 'output_text', text: JSON.stringify({ offers }) }] }],
      usage: { input_tokens: 1100, input_tokens_details: { cached_tokens: 0 }, output_tokens: 40 },
    });
  }
  if (path === 'responses') {
    const usage = { input_tokens: 800, input_tokens_details: { cached_tokens: 0 }, output_tokens: 160 };
    // Asked for cards, in the wall's conversation: the first five of the wall's words, as a deck.
    const asked = [...(body.input ?? [])].reverse().find((item: any) => item.role === 'user')?.content ?? '';
    if (body.tools && /卡|单词|deck/i.test(asked)) {
      const saved = (String(body.instructions).match(/\n([^\n—]+) — /g) ?? []).map((line) => line.slice(1, -3).trim());
      return streamed('从你的墙上挑了几张，先刷一遍。', usage, [{ type: 'function_call', name: 'show_deck',
        call_id: `call_mock_${Date.now()}`, arguments: JSON.stringify({ title: '模拟卡片组', words: saved.slice(0, 5) }) }]);
    }
    const answer = '这是模拟的回答。\n\n1. A made-up example. 一个编出来的例子。\n2. Another one. 另一个。';
    return streamed(answer, usage);
  }
  if (path === 'images/generations') {
    await sleep(2000);
    const prompt = String(body?.prompt ?? '');
    if (prompt.includes('REFUSE') && !refused.has(prompt)) {
      refused.add(prompt);
      return json({ error: { message: 'Your request was rejected by the safety system.', type: 'image_generation_user_error',
        code: 'moderation_blocked', moderation_details: { moderation_stage: 'output', categories: ['other'] } } }, 400);
    }
    return json({ data: [{ b64_json: PNG }], usage: { input_tokens: 401, input_tokens_details: { text_tokens: 401, image_tokens: 0 },
      output_tokens: 439 } });
  }
  if (path === 'audio/speech') {
    await sleep(300);
    return new Response(bytes(MP3), { headers: { 'Content-Type': 'audio/mpeg' } });
  }
  if (path === 'decisions' && body?.questions?.[0]?.name === 'count') {
    await sleep(150);
    // Several when it names more than one English word, as the split's mock would list them.
    const named = String(body.input).match(/[A-Za-z][A-Za-z' -]*[A-Za-z]/g) ?? [];
    const choice = named.length > 1 ? 'several' : 'one';
    return json({ answers: [{ name: 'count', choice, confidence: 0.9, probabilities: [{ value: choice, probability: 0.9 }] }],
      usage: { input_tokens: 300 } });
  }
  if (path === 'decisions') {
    await sleep(200);
    return json({ answers: [{ name: 'card', choice: 'new', confidence: 0.97, probabilities: [{ value: 'new', probability: 0.97 }] }],
      usage: { input_tokens: 320 } });
  }
  return json({ error: { message: `No mock for ${path}.` } }, 404);
}

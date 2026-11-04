// Cliente mínimo de la API de Mensajes de Anthropic con streaming (sin SDK, solo fetch).
import { config, log } from './config.js';

export class ApiError extends Error {
  constructor(status, body) {
    super(`Anthropic API ${status}: ${body.slice(0, 400)}`);
    this.status = status;
    this.body = body;
  }
}

async function open(params, signal) {
  const url = `${config.anthropicBase}/v1/messages`;
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(url, {
      method: 'POST',
      signal,
      headers: {
        'x-api-key': config.anthropicKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({ ...params, stream: true }),
    });
    if (res.ok) return res;
    const body = await res.text();
    if ((res.status === 429 || res.status >= 500) && attempt < 2) {
      log('claude: reintento por', res.status);
      await new Promise((r) => setTimeout(r, 700 * (attempt + 1)));
      continue;
    }
    throw new ApiError(res.status, body);
  }
}

// Devuelve el mensaje final armado {content, stop_reason}. onText recibe cada fragmento de texto.
export async function createMessage(params, { signal, onText } = {}) {
  const res = await open(params, signal);
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  const blocks = [];
  const partial = [];
  let stop_reason = null;
  const usage = { input: 0, output: 0 };

  const handle = (ev) => {
    switch (ev.type) {
      case 'content_block_start': {
        const b = { ...ev.content_block };
        if (b.type === 'text') {
          b.text = b.text || '';
          delete b.citations;
        }
        blocks[ev.index] = b;
        partial[ev.index] = '';
        break;
      }
      case 'content_block_delta': {
        const b = blocks[ev.index];
        const d = ev.delta;
        if (!b) break;
        if (d.type === 'text_delta') {
          b.text += d.text;
          onText?.(d.text);
        } else if (d.type === 'input_json_delta') partial[ev.index] += d.partial_json;
        else if (d.type === 'citations_delta') (b.citations ||= []).push(d.citation);
        else if (d.type === 'thinking_delta') b.thinking = (b.thinking || '') + d.thinking;
        else if (d.type === 'signature_delta') b.signature = d.signature;
        break;
      }
      case 'content_block_stop': {
        const b = blocks[ev.index];
        if (b && (b.type === 'tool_use' || b.type === 'server_tool_use')) {
          try {
            b.input = partial[ev.index] ? JSON.parse(partial[ev.index]) : b.input || {};
          } catch {
            b.input = {};
          }
        }
        break;
      }
      case 'message_start': {
        const u = ev.message?.usage || {};
        usage.input += (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
        break;
      }
      case 'message_delta':
        if (ev.delta?.stop_reason) stop_reason = ev.delta.stop_reason;
        if (ev.usage?.output_tokens) usage.output = ev.usage.output_tokens;
        break;
      case 'error':
        throw new ApiError(500, JSON.stringify(ev.error || ev));
    }
  };

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const raw = buf.slice(0, i);
      buf = buf.slice(i + 2);
      const data = raw
        .split('\n')
        .filter((l) => l.startsWith('data:'))
        .map((l) => l.slice(5).trimStart())
        .join('\n');
      if (!data) continue;
      try {
        handle(JSON.parse(data));
      } catch (e) {
        if (e instanceof ApiError) throw e;
      }
    }
  }
  return { content: blocks.filter(Boolean), stop_reason, usage };
}

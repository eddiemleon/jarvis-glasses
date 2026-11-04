// Proveedor de respaldo compatible con la API de OpenAI (Gemini, OpenRouter, Groq, OpenAI, Ollama, etc.).
// Recibe parámetros en formato Anthropic y devuelve el mismo formato que claude.js.
import { ApiError } from './claude.js';

export function toOpenAI(params, provider) {
  const sys =
    params.system.map((b) => b.text).join('\n\n') +
    '\n\nNota técnica: ahora funcionas con un modelo de respaldo; no tienes búsqueda web. Si te piden datos actuales que no tengas, dilo.';
  const messages = [{ role: 'system', content: sys }];
  for (const m of params.messages) {
    if (m.role === 'user') {
      if (typeof m.content === 'string') {
        messages.push({ role: 'user', content: m.content });
        continue;
      }
      const imgs = [];
      // Mensaje del usuario con texto e imágenes directas (vigilancia, memoria visual).
      const direct = m.content.filter((b) => b.type === 'text' || b.type === 'image');
      if (direct.length) {
        messages.push({
          role: 'user',
          content: direct.map((b) =>
            b.type === 'text'
              ? { type: 'text', text: b.text }
              : { type: 'image_url', image_url: { url: `data:${b.source.media_type};base64,${b.source.data}` } }
          ),
        });
      }
      for (const b of m.content) {
        if (b.type !== 'tool_result') continue;
        let text = '';
        if (typeof b.content === 'string') text = b.content;
        else for (const c of b.content || []) {
          if (c.type === 'text') text += c.text + '\n';
          else if (c.type === 'image') imgs.push(c);
        }
        messages.push({ role: 'tool', tool_call_id: b.tool_use_id, content: text.trim() || '(ok)' });
      }
      if (imgs.length)
        messages.push({
          role: 'user',
          content: [
            { type: 'text', text: 'Imagen capturada ahora por las gafas del usuario:' },
            ...imgs.map((i) => ({ type: 'image_url', image_url: { url: `data:${i.source.media_type};base64,${i.source.data}` } })),
          ],
        });
    } else {
      let text = '';
      const calls = [];
      for (const b of m.content) {
        if (b.type === 'text') text += b.text;
        else if (b.type === 'tool_use')
          calls.push({ id: b.id, type: 'function', function: { name: b.name, arguments: JSON.stringify(b.input || {}) } });
      }
      const msg = { role: 'assistant', content: text };
      if (calls.length) msg.tool_calls = calls;
      messages.push(msg);
    }
  }
  const tools = (params.tools || [])
    .filter((t) => t.input_schema)
    .map((t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.input_schema } }));
  const body = { model: provider.model, messages, stream: true, max_tokens: params.max_tokens };
  if (tools.length) body.tools = tools;
  return body;
}

export async function createOpenAI(provider, params, { signal, onText } = {}) {
  const res = await fetch(`${provider.base}/chat/completions`, {
    method: 'POST',
    signal,
    headers: { 'content-type': 'application/json', ...(provider.key ? { authorization: `Bearer ${provider.key}` } : {}) },
    body: JSON.stringify(toOpenAI(params, provider)),
  });
  if (!res.ok) throw new ApiError(res.status, await res.text());

  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  let text = '';
  const calls = [];
  let finish = null;
  const usage = { input: 0, output: 0 };

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (!data || data === '[DONE]') continue;
      let ev;
      try {
        ev = JSON.parse(data);
      } catch {
        continue;
      }
      if (ev.usage) {
        usage.input = ev.usage.prompt_tokens || usage.input;
        usage.output = ev.usage.completion_tokens || usage.output;
      }
      const ch = ev.choices?.[0];
      if (!ch) continue;
      const d = ch.delta || {};
      if (d.content) {
        text += d.content;
        onText?.(d.content);
      }
      for (const tc of d.tool_calls || []) {
        const c = (calls[tc.index ?? 0] ||= { id: '', name: '', args: '' });
        if (tc.id) c.id = tc.id;
        if (tc.function?.name) c.name += tc.function.name;
        if (tc.function?.arguments) c.args += tc.function.arguments;
      }
      if (ch.finish_reason) finish = ch.finish_reason;
    }
  }

  const content = [];
  if (text) content.push({ type: 'text', text });
  let n = 0;
  for (const c of calls.filter(Boolean)) {
    let input = {};
    try {
      input = c.args ? JSON.parse(c.args) : {};
    } catch {}
    content.push({ type: 'tool_use', id: c.id || `call_${Date.now()}_${n++}`, name: c.name, input });
  }
  const hasTools = content.some((b) => b.type === 'tool_use');
  return { content, stop_reason: hasTools ? 'tool_use' : finish === 'length' ? 'max_tokens' : 'end_turn', usage };
}

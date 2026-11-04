// Cliente mínimo de la Messages API de Anthropic con streaming (sin SDK, cero dependencias).

export async function streamMessage({ body, signal, onText }) {
  const base = process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com';
  const res = await fetch(`${base}/v1/messages`, {
    method: 'POST',
    signal,
    headers: {
      'content-type': 'application/json',
      'x-api-key': process.env.ANTHROPIC_API_KEY || '',
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({ ...body, stream: true }),
  });
  if (!res.ok) {
    const t = await res.text().catch(() => '');
    throw new Error(`Anthropic ${res.status}: ${t.slice(0, 300)}`);
  }

  const blocks = [];
  let stopReason = null;

  const handle = (raw) => {
    let dataLine = '';
    for (const line of raw.split('\n')) if (line.startsWith('data:')) dataLine += line.slice(5).trim();
    if (!dataLine) return;
    let ev;
    try { ev = JSON.parse(dataLine); } catch { return; }

    switch (ev.type) {
      case 'content_block_start': {
        const b = { ...ev.content_block };
        if (b.type === 'text') b.text = b.text || '';
        if (b.type === 'tool_use' || b.type === 'server_tool_use') { b.input = {}; b._json = ''; }
        blocks[ev.index] = b;
        break;
      }
      case 'content_block_delta': {
        const b = blocks[ev.index];
        const d = ev.delta;
        if (!b || !d) break;
        if (d.type === 'text_delta') { b.text += d.text; onText?.(d.text); }
        else if (d.type === 'input_json_delta') b._json += d.partial_json;
        else if (d.type === 'citations_delta') (b.citations ||= []).push(d.citation);
        break;
      }
      case 'content_block_stop': {
        const b = blocks[ev.index];
        if (b && b._json !== undefined) {
          if (b._json) { try { b.input = JSON.parse(b._json); } catch { b.input = {}; } }
          delete b._json;
        }
        break;
      }
      case 'message_delta':
        if (ev.delta?.stop_reason) stopReason = ev.delta.stop_reason;
        break;
      case 'error':
        throw new Error(`Anthropic stream: ${ev.error?.message || 'error'}`);
    }
  };

  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true }).replace(/\r\n/g, '\n');
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const raw = buf.slice(0, i);
      buf = buf.slice(i + 2);
      handle(raw);
    }
  }
  if (buf.trim()) handle(buf);

  const content = blocks
    .filter(Boolean)
    .filter((b) => !(b.type === 'text' && !b.text))
    .map((b) => {
      if (b.type === 'text' && (!b.citations || b.citations.length === 0)) delete b.citations;
      return b;
    });
  return { content, stopReason };
}

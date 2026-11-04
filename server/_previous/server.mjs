// Jarvis Glasses — servidor sin dependencias (Node 22+).
// Puente: gafas -> iPhone -> ESTE servidor -> Claude, más alertas push (TradingView, WhatsApp Business).
import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';

try { process.loadEnvFile(new URL('./.env', import.meta.url)); } catch { /* .env opcional */ }

const PORT = Number(process.env.PORT || 8787);
const TOKEN = process.env.JARVIS_TOKEN || '';
const API_KEY = process.env.ANTHROPIC_API_KEY || '';
const API_BASE = process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com';
const MODEL = process.env.JARVIS_MODEL || 'claude-sonnet-5-5';
const WA_VERIFY = process.env.WA_VERIFY_TOKEN || '';
const WA_TOKEN = process.env.WA_ACCESS_TOKEN || '';
const WA_PHONE_ID = process.env.WA_PHONE_NUMBER_ID || '';
const MAX_TURNS = 20;

if (!TOKEN) { console.error('Falta JARVIS_TOKEN en .env (secreto compartido con la app).'); process.exit(1); }

const SYSTEM = `Eres JARVIS, el asistente personal de Eddie, al estilo del de Iron Man, hablando en español.
Vives en sus gafas Ray-Ban Meta: lo que escribes SE LEE EN VOZ ALTA por los parlantes.
Reglas de voz: respuestas cortas (1 a 3 frases salvo que pida detalle), sin markdown, sin listas, sin emojis, sin URLs.
Tono: hiperinteligente, rápido, con humor seco y elegante; llama a Eddie "señor" de vez en cuando, sin abusar.
Si recibes una imagen, es lo que ven las gafas ahora mismo: descríbela o respóndele sobre ella.
Si Eddie pide algo que no puedes hacer desde aquí, dilo en una frase y ofrece la alternativa más cercana.
Hora actual: {{NOW}} (zona America/Puerto_Rico).`;

// ---------- utilidades ----------
const sessions = new Map();           // sessionId -> [{role, content}]
const listeners = new Set();          // respuestas SSE abiertas (/api/events)

const safeEq = (a, b) => {
  const A = Buffer.from(String(a)), B = Buffer.from(String(b));
  return A.length === B.length && timingSafeEqual(A, B);
};
const authed = (req, url) => {
  const h = req.headers.authorization || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : (url.searchParams.get('token') || '');
  return safeEq(t, TOKEN);
};
const readBody = (req, limit = 12 * 1024 * 1024) => new Promise((resolve, reject) => {
  const chunks = []; let n = 0;
  req.on('data', c => { n += c.length; if (n > limit) { reject(new Error('body demasiado grande')); req.destroy(); } else chunks.push(c); });
  req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  req.on('error', reject);
});
const json = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
const sse = (res, obj) => res.write(`data: ${JSON.stringify(obj)}\n\n`);

function broadcast(event) {
  for (const res of listeners) sse(res, event);
  console.log('[evento]', event.type, listeners.size, 'oyente(s)');
}

// ---------- Claude (streaming) ----------
async function streamClaude({ sessionId, text, imageBase64, imageMime }, onDelta) {
  if (!API_KEY) throw new Error('Falta ANTHROPIC_API_KEY en .env');
  const history = sessions.get(sessionId) || [];
  const content = [];
  if (imageBase64) content.push({ type: 'image', source: { type: 'base64', media_type: imageMime || 'image/jpeg', data: imageBase64 } });
  content.push({ type: 'text', text });
  const messages = [...history, { role: 'user', content }];

  const now = new Date().toLocaleString('es-PR', { timeZone: 'America/Puerto_Rico', dateStyle: 'full', timeStyle: 'short' });
  const r = await fetch(`${API_BASE}/v1/messages`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': API_KEY, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: MODEL, max_tokens: 600, stream: true, system: SYSTEM.replace('{{NOW}}', now), messages }),
  });
  if (!r.ok) throw new Error(`Claude respondió ${r.status}: ${(await r.text()).slice(0, 300)}`);

  let full = '', buf = '';
  const dec = new TextDecoder();
  for await (const chunk of r.body) {
    buf += dec.decode(chunk, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const frame = buf.slice(0, i); buf = buf.slice(i + 2);
      const line = frame.split('\n').find(l => l.startsWith('data: '));
      if (!line) continue;
      try {
        const ev = JSON.parse(line.slice(6));
        if (ev.type === 'content_block_delta' && ev.delta?.type === 'text_delta') { full += ev.delta.text; onDelta(ev.delta.text); }
      } catch { /* ignorar frames parciales */ }
    }
  }
  // La memoria guarda solo el texto de la imagen (no los bytes) para no inflar el contexto.
  const saved = [...history, { role: 'user', content: imageBase64 ? `[imagen de las gafas] ${text}` : text }, { role: 'assistant', content: full }];
  sessions.set(sessionId, saved.slice(-MAX_TURNS * 2));
  return full;
}

// ---------- WhatsApp Business Cloud API ----------
async function sendWhatsApp(to, body) {
  if (!WA_TOKEN || !WA_PHONE_ID) throw new Error('Faltan WA_ACCESS_TOKEN / WA_PHONE_NUMBER_ID en .env');
  const r = await fetch(`https://graph.facebook.com/v21.0/${WA_PHONE_ID}/messages`, {
    method: 'POST',
    headers: { authorization: `Bearer ${WA_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ messaging_product: 'whatsapp', to, type: 'text', text: { body } }),
  });
  if (!r.ok) throw new Error(`WhatsApp respondió ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
}

// ---------- rutas ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const route = `${req.method} ${url.pathname}`;
  try {
    if (route === 'GET /health') return json(res, 200, { ok: true, model: MODEL, claude: !!API_KEY, whatsapp: !!(WA_TOKEN && WA_PHONE_ID) });

    // Verificación del webhook de Meta (WhatsApp): no usa nuestro token, usa WA_VERIFY_TOKEN.
    if (route === 'GET /webhook/whatsapp') {
      const ok = url.searchParams.get('hub.mode') === 'subscribe' && WA_VERIFY && safeEq(url.searchParams.get('hub.verify_token') || '', WA_VERIFY);
      res.writeHead(ok ? 200 : 403, { 'content-type': 'text/plain' });
      return res.end(ok ? url.searchParams.get('hub.challenge') : 'forbidden');
    }
    if (route === 'POST /webhook/whatsapp') {
      const data = JSON.parse((await readBody(req)) || '{}');
      for (const entry of data.entry || []) for (const ch of entry.changes || []) {
        const names = Object.fromEntries((ch.value?.contacts || []).map(c => [c.wa_id, c.profile?.name]));
        for (const m of ch.value?.messages || []) {
          broadcast({ type: 'whatsapp', from: m.from, name: names[m.from] || m.from, text: m.text?.body || `(mensaje de tipo ${m.type})` });
        }
      }
      return json(res, 200, { ok: true });
    }

    // Todo lo demás exige token.
    if (!authed(req, url)) return json(res, 401, { error: 'no autorizado' });

    if (route === 'POST /webhook/tradingview') {
      const raw = (await readBody(req)).trim();
      let text = raw;
      try { const j = JSON.parse(raw); text = j.message || j.text || j.alert || raw; } catch { /* texto plano */ }
      if (!text) return json(res, 400, { error: 'alerta vacía' });
      broadcast({ type: 'alert', source: 'TradingView', text: String(text).slice(0, 400) });
      return json(res, 200, { ok: true });
    }

    if (route === 'GET /api/events') {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
      sse(res, { type: 'hello' });
      listeners.add(res);
      const ping = setInterval(() => res.write(': ping\n\n'), 20000);
      req.on('close', () => { clearInterval(ping); listeners.delete(res); });
      return;
    }

    if (route === 'POST /api/chat') {
      const b = JSON.parse(await readBody(req));
      if (!b.text) return json(res, 400, { error: 'falta text' });
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      try {
        await streamClaude({ sessionId: b.sessionId || 'default', text: b.text, imageBase64: b.imageBase64, imageMime: b.imageMime }, t => sse(res, { t }));
        sse(res, { done: true });
      } catch (e) { sse(res, { error: e.message }); }
      return res.end();
    }

    if (route === 'POST /api/whatsapp/send') {
      const b = JSON.parse(await readBody(req));
      if (!b.to || !b.text) return json(res, 400, { error: 'faltan to/text' });
      return json(res, 200, await sendWhatsApp(String(b.to).replace(/\D/g, ''), b.text));
    }

    if (route === 'POST /api/reset') { sessions.clear(); return json(res, 200, { ok: true }); }

    json(res, 404, { error: 'no existe' });
  } catch (e) {
    console.error(route, e.message);
    if (!res.headersSent) json(res, 500, { error: e.message }); else res.end();
  }
});

server.listen(PORT, () => console.log(`Jarvis escuchando en :${PORT}  modelo=${MODEL}`));

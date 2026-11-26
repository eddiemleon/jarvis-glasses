import http from 'node:http';
import crypto from 'node:crypto';
import { config, log } from './config.js';
import { upgrade } from './ws.js';
import { hub } from './hub.js';
import { store, snapshot, restore, setOnChange } from './store.js';
import { runTurn, cancelCurrent, runBackground, historySnapshot, restoreHistory, onTurnDone, timingStats } from './brain.js';
import { verifySignature, parseIncoming, waEnabled } from './whatsapp.js';
import { synthesize, ttsEnabled, registerPcVoice, ttsSource } from './tts.js';
import { live, VIEWER_HTML, EXPIRED_HTML } from './live.js';
import { usageSnapshot, providers, resolveBrains } from './llm.js';
import { startReminderLoop } from './reminders.js';
import { startRoutineLoop } from './routines.js';
import { startVigia } from './vigia.js';
import { copiloto } from './copiloto.js';
import { translateAndSpeak } from './tools.js';
import { lionEstado, lionAgentes, lionEnabled } from './lion.js';

if (config.token.length < 16) {
  // Plug and play: si no hay contraseña, se crea una sola vez y se guarda.
  const { existsSync, readFileSync, writeFileSync, mkdirSync } = await import('node:fs');
  const { randomBytes } = await import('node:crypto');
  const f = config.dataDir + '/token.txt';
  try { mkdirSync(config.dataDir, { recursive: true }); } catch {}
  let t = existsSync(f) ? readFileSync(f, 'utf8').trim() : '';
  if (t.length < 16) { t = randomBytes(24).toString('hex'); writeFileSync(f, t); }
  config.token = t;
}
if (!config.mock && !config.anthropicKey && !config.fallbacks.length) {
  console.error('Falta una clave de IA: ANTHROPIC_API_KEY (recomendada) o GEMINI_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY / GROQ_API_KEY / OLLAMA_URL.');
  process.exit(1);
}

const readyMsg = () => ({
  type: 'ready',
  model: config.mock ? 'mock' : config.model,
  features: { tts: ttsEnabled(), voice: ttsSource(), whatsapp: waEnabled(), webSearch: config.webSearch },
});

const sha = (s) => crypto.createHash('sha256').update(String(s)).digest();
const safeEq = (a, b) => crypto.timingSafeEqual(sha(a), sha(b));
const authed = (req) => safeEq((req.headers.authorization || '').replace(/^Bearer\s+/i, ''), config.token);

function readBody(req, limit = 1_000_000) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    req.on('data', (c) => {
      n += c.length;
      if (n > limit) {
        reject(new Error('body too large'));
        req.destroy();
      } else chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const reply = (res, code, body, type = 'text/plain; charset=utf-8') => {
  res.writeHead(code, { 'content-type': type });
  res.end(body);
};

let lastLocation = null;

// ---- alertas TradingView ----
function formatAlert(raw) {
  let obj = null;
  try {
    obj = JSON.parse(raw);
  } catch {}
  if (obj && typeof obj === 'object') {
    const sym = obj.symbol || obj.ticker || '';
    const act = obj.action || obj.side || obj.signal || '';
    const price = obj.price ?? obj.close ?? '';
    const msg = obj.message || obj.text || '';
    const parts = [sym, act, price !== '' ? `a ${price}` : '', msg].filter(Boolean);
    return { text: parts.join(' ').trim() || raw.slice(0, 300), secret: obj.secret };
  }
  return { text: raw.trim().slice(0, 500), secret: null };
}

// Qué voz usa la app de verdad (lo informa el iPhone).
const vozInforme = { app: null, frases: [] };

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/health')) {
      return reply(res, 200, JSON.stringify({ ok: true, app: hub.connected, tts: ttsEnabled(), voice: ttsSource(), whatsapp: waEnabled(), brains: providers().map((p) => p.name + ':' + p.label), live: !!live.current }), 'application/json');
    }

    if (req.method === 'GET' && url.pathname === '/setup') {
      if (!safeEq(url.searchParams.get('t') || '', config.token)) return reply(res, 401, 'Abre el enlace completo que sale en los registros del servidor.');
      const host = config.publicUrl || `https://${req.headers['x-forwarded-host'] || req.headers.host}`;
      const link = `jarvisglasses://setup?server=${encodeURIComponent(host)}&token=${encodeURIComponent(config.token)}`;
      return reply(res, 200, `<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><body style="background:#05070d;color:#fff;font-family:-apple-system,sans-serif;text-align:center;padding:60px 20px"><h1>Jarvis</h1><p>Abre esto en tu iPhone con la app instalada:</p><a href="${link}" style="display:inline-block;background:#18b6ff;color:#001018;padding:18px 34px;border-radius:16px;font-size:20px;font-weight:700;text-decoration:none">Conectar la app</a></body>`, 'text/html; charset=utf-8');
    }

    if (req.method === 'GET' && url.pathname === '/timings') {
      if (!authed(req)) return reply(res, 401, 'unauthorized');
      return reply(res, 200, JSON.stringify({ timings: timingStats(), voz: vozInforme }), 'application/json');
    }
    if (req.method === 'GET' && url.pathname === '/usage') {
      if (!authed(req)) return reply(res, 401, 'unauthorized');
      return reply(res, 200, JSON.stringify(usageSnapshot()), 'application/json');
    }

    if (req.method === 'GET' && url.pathname.startsWith('/live/')) {
      const id = url.pathname.slice(6);
      return live.valid(id) ? reply(res, 200, VIEWER_HTML, 'text/html; charset=utf-8') : reply(res, 404, EXPIRED_HTML, 'text/html; charset=utf-8');
    }

    if (url.pathname === '/webhook/tradingview' && req.method === 'POST') {
      const raw = (await readBody(req)).toString('utf8');
      const { text, secret: bodySecret } = formatAlert(raw);
      const provided = url.searchParams.get('secret') || req.headers['x-webhook-secret'] || bodySecret || '';
      if (!config.tvSecret || !safeEq(provided, config.tvSecret)) return reply(res, 401, 'unauthorized');
      const alert = { id: crypto.randomUUID(), source: 'tradingview', text, ts: Date.now() };
      store.addAlert(alert);
      const delivered = hub.deliver({ type: 'alert', ...alert, priority: 'high' });
      log('tradingview:', text, delivered ? '(entregada)' : '(en cola)');
      return reply(res, 200, 'ok');
    }

    if (url.pathname === '/webhook/whatsapp') {
      if (req.method === 'GET') {
        const ok =
          url.searchParams.get('hub.mode') === 'subscribe' &&
          config.wa.verifyToken &&
          safeEq(url.searchParams.get('hub.verify_token') || '', config.wa.verifyToken);
        return ok ? reply(res, 200, url.searchParams.get('hub.challenge') || '') : reply(res, 403, 'forbidden');
      }
      if (req.method === 'POST') {
        const raw = await readBody(req);
        if (!verifySignature(raw, req.headers['x-hub-signature-256'])) return reply(res, 401, 'bad signature');
        reply(res, 200, 'ok'); // WhatsApp exige 200 rápido
        let body;
        try {
          body = JSON.parse(raw.toString('utf8'));
        } catch {
          return;
        }
        for (const m of parseIncoming(body)) {
          store.addWa(m);
          const d = hub.deliver({ type: 'whatsapp_in', ...m });
          log('whatsapp in:', m.name, d ? '(entregado)' : '(en cola)');
        }
        return;
      }
    }

    if (url.pathname === '/tts' && req.method === 'POST') {
      if (!authed(req)) return reply(res, 401, 'unauthorized');
      if (!ttsEnabled()) return reply(res, 501, 'tts not configured');
      const { text } = JSON.parse((await readBody(req, 20_000)).toString('utf8') || '{}');
      if (!text) return reply(res, 400, 'text required');
      const { audio, type } = await synthesize(String(text));
      res.writeHead(200, { 'content-type': type, 'content-length': audio.length });
      return res.end(audio);
    }

    // La PC del usuario avisa dónde está su voz propia (túnel seguro). Cada 5 min.
    // Copiloto: la PC de Leon recoge mensajes (long-poll) y devuelve la respuesta de su chat único de Claude.
    if (url.pathname === '/copiloto/next' && req.method === 'GET') {
      if (!authed(req)) return reply(res, 401, 'unauthorized');
      const m = await copiloto.siguiente(25_000);
      if (!m) { res.writeHead(204); return res.end(); }
      return reply(res, 200, JSON.stringify(m), 'application/json');
    }
    if (url.pathname === '/copiloto/reply' && req.method === 'POST') {
      if (!authed(req)) return reply(res, 401, 'unauthorized');
      let b = null;
      try { b = JSON.parse((await readBody(req, 200_000)).toString('utf8') || '{}'); } catch {}
      if (!b || !b.texto) return reply(res, 400, 'texto requerido');
      copiloto.responder(String(b.id || ''), String(b.texto));
      return reply(res, 200, JSON.stringify({ ok: true }), 'application/json');
    }
    if (url.pathname === '/lion/register' && req.method === 'POST') {
      if (!authed(req)) return reply(res, 401, 'unauthorized');
      let b = null;
      try { b = JSON.parse((await readBody(req, 5_000)).toString('utf8') || '{}'); } catch {}
      if (!b || !/^https:\/\//.test(String(b.url || '')) || String(b.key || '').length < 12) return reply(res, 400, 'url https y key requeridos');
      store.setLion(b);
      // Prueba de punta a punta: el servidor habla con la sala ahora mismo y dice si de verdad funciona.
      let prueba;
      try {
        const e = await lionEstado();
        const ag = await lionAgentes().catch(() => []);
        prueba = { sala: true, mt5: !!e.conectado, motivo: e.motivo || null, agentes: (ag || []).length };
      } catch (err) { prueba = { sala: false, error: String(err.message || err) }; }
      return reply(res, 200, JSON.stringify({ ok: true, prueba }), 'application/json');
    }
    if (url.pathname === '/lion/status' && req.method === 'GET') {
      if (!authed(req)) return reply(res, 401, 'unauthorized');
      if (!lionEnabled()) return reply(res, 200, JSON.stringify({ configurado: false }), 'application/json');
      try {
        const e = await lionEstado();
        return reply(res, 200, JSON.stringify({ configurado: true, sala: true, mt5: !!e.conectado, motivo: e.motivo || null }), 'application/json');
      } catch (err) { return reply(res, 200, JSON.stringify({ configurado: true, sala: false, error: String(err.message || err) }), 'application/json'); }
    }
    if (url.pathname === '/voice/register' && req.method === 'POST') {
      if (!authed(req)) return reply(res, 401, 'unauthorized');
      const { url: voiceUrl } = JSON.parse((await readBody(req, 5_000)).toString('utf8') || '{}');
      const changed = registerPcVoice(voiceUrl);
      if (changed) hub.send(readyMsg()); // la app se entera al instante: empieza a usar la voz propia
      return reply(res, 200, JSON.stringify({ ok: true, source: ttsSource() }), 'application/json');
    }

    // Para atajos de iOS / automatizaciones: hace que Jarvis diga algo en las gafas.
    if (url.pathname === '/push' && req.method === 'POST') {
      if (!authed(req)) return reply(res, 401, 'unauthorized');
      const { text, priority } = JSON.parse((await readBody(req, 20_000)).toString('utf8') || '{}');
      if (!text) return reply(res, 400, 'text required');
      const delivered = hub.deliver({ type: 'alert', id: crypto.randomUUID(), source: 'push', text: String(text), priority: priority || 'normal', ts: Date.now() });
      return reply(res, 200, JSON.stringify({ delivered }), 'application/json');
    }

    reply(res, 404, 'not found');
  } catch (e) {
    log('http error', req.url, e.message);
    if (!res.headersSent) reply(res, 500, 'error');
  }
});

// ---- WebSocket de la app ----
server.on('upgrade', (req, socket, head) => {
  const u = new URL(req.url, 'http://localhost');

  if (u.pathname === '/live/ws') {
    // Visor: el enlace secreto es la credencial.
    return upgrade(req, socket, head, (conn) => {
      if (!live.valid(u.searchParams.get('id') || '') || !live.addViewer(conn)) conn.close(1008);
      conn.on('message', () => {});
    });
  }
  if (u.pathname !== '/ws') return socket.destroy();

  const host = req.headers['x-forwarded-host'] || req.headers.host;
  if (host) live.lastBase = `${req.headers['x-forwarded-proto'] || (/^(localhost|127\.|192\.168\.|10\.)/.test(host) ? 'http' : 'https')}://${host}`;

  upgrade(req, socket, head, (conn) => {
    let ok = false;
    const authTimer = setTimeout(() => !ok && conn.close(1008), 8000);

    conn.on('message', (text) => {
      let m;
      try {
        m = JSON.parse(text);
      } catch {
        return;
      }
      if (!ok) {
        if (m.type === 'hello' && typeof m.token === 'string' && safeEq(m.token, config.token)) {
          if (m.voz) vozInforme.app = { ...m.voz, at: new Date().toISOString() };
          ok = true;
          clearTimeout(authTimer);
          // Una sola app a la vez: una conexión vieja que quedó abierta se cierra (evita respuestas repetidas).
          for (const old of [...hub.clients]) if (old !== conn) { hub.remove(old); old.close(4000); }
          hub.add(conn);
          // Memoria guardada en el iPhone: si este servidor se reinició (plan gratis), la recupera.
          if (m.restore && typeof m.restore === 'object') {
            const okState = restore(m.restore.state);
            restoreHistory(m.restore.history);
            if (okState) log('memoria restaurada desde el iPhone');
          }
          conn.send(JSON.stringify(readyMsg()));
          const n = hub.flushQueue(conn);
          log('app conectada', n ? `(+${n} eventos en cola)` : '');
        } else conn.close(1008);
        return;
      }
      switch (m.type) {
        case 'utterance':
          if (typeof m.text === 'string' && m.text.trim()) {
            if (m.location) lastLocation = m.location;
            log('usuario:', m.text);
            runTurn({ id: m.id || crypto.randomUUID(), text: m.text.trim(), context: { location: m.location || lastLocation, glasses: m.glasses } });
          }
          break;
        case 'location':
          lastLocation = m;
          break;
        case 'cancel':
          cancelCurrent();
          break;
        case 'live_start': {
          const l = live.create(m.ttl || 60);
          conn.send(JSON.stringify({ type: 'live_link', url: l.url, expires: l.expires }));
          break;
        }
        case 'live_stop':
          live.stop('stopped');
          break;
        case 'capture_result':
          hub.resolveCapture(m);
          break;
        case 'device_result':
          hub.resolveDevice(m);
          break;
        case 'interpret':
          // Modo intérprete: frase en otro idioma → traducción al español en las gafas.
          if (typeof m.text === 'string' && m.text.trim()) translateAndSpeak(m.text.trim().slice(0, 2000), String(m.locale || 'en-US'));
          break;
        case 'voz':
          vozInforme.frases.push({ at: new Date().toISOString(), fuente: String(m.fuente || ''), ms: Number(m.ms) || 0 });
          if (vozInforme.frases.length > 40) vozInforme.frases.shift();
          break;
        case 'ping':
          conn.send('{"type":"pong"}');
          break;
      }
    });
    conn.on('binary', (buf) => {
      if (ok) live.relay(buf);
    });
    conn.on('close', () => {
      clearTimeout(authTimer);
      hub.remove(conn);
      log('app desconectada');
    });
    // Latido: la red de Render no deja pasar los "ping" de WebSocket del iPhone, así que antes la app
    // parecía muerta y se cortaba cada 60 s. Ahora el servidor envía un latido en texto (mantiene viva la
    // conexión). Una conexión muerta se detecta cuando falla el envío; el corte por silencio queda en 30 min.
    const hb = setInterval(() => {
      if (Date.now() - conn.lastSeen > 1_800_000) return conn.close(1001);
      conn.send('{"type":"hb"}');
      conn.ping();
    }, 20_000);
    conn.on('close', () => clearInterval(hb));
  });
});

// Copia de la memoria hacia el iPhone tras cada conversación y cada cambio (con pausa para no saturar).
let syncTimer = null;
function scheduleSync() {
  clearTimeout(syncTimer);
  syncTimer = setTimeout(() => {
    if (!hub.connected) return;
    const payload = JSON.stringify({ type: 'sync', state: snapshot(), history: historySnapshot() });
    if (payload.length < 3_000_000) hub.send(JSON.parse(payload));
  }, 1500);
}
setOnChange(scheduleSync);
onTurnDone.fn = scheduleSync;

startReminderLoop();
await resolveBrains();
const routineTick = startRoutineLoop((r) => runBackground({ prompt: r.prompt, label: r.label, context: { location: lastLocation } }));
setTimeout(routineTick, 2000).unref(); // al arrancar, por si toca una ahora mismo
startVigia();
server.listen(config.port, () => {
  log(`ENLACE DE CONEXIÓN (ábrelo en el iPhone): ${config.publicUrl || 'https://TU-SERVIDOR'}/setup?t=${config.token}`);
  log(`Jarvis escuchando en :${config.port}  cerebros=${config.mock ? 'MOCK' : providers().map((p) => p.name + ':' + p.label).join(' → ')}  tts=${ttsEnabled()}  whatsapp=${waEnabled()}  tradingview=${!!config.tvSecret}`);
});

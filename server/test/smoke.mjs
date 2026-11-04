// Prueba de humo: servidor real + cliente WebSocket nativo + Anthropic simulado (SSE).
import { spawn } from 'node:child_process';
import http from 'node:http';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
for (const p of [18081, 18082]) rmSync('/tmp/jarvis-test-' + p, { recursive: true, force: true });

const TOKEN = 'test-token-0123456789abcdef';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let pass = 0;
const ok = (name) => console.log('  ✓', name) || pass++;

// ---------- Anthropic falso ----------
const sse = (events) => events.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join('');
let anthropicCalls = [];
const fake = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const p = JSON.parse(body);
    anthropicCalls.push(p);
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const hasToolResult = p.messages.some((m) => Array.isArray(m.content) && m.content.some((b) => b.type === 'tool_result'));
    const ev = [{ type: 'message_start', message: { id: 'm', role: 'assistant', content: [] } }];
    if (!hasToolResult) {
      const json = JSON.stringify({ reason: 'ver' });
      ev.push(
        { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
        { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Déjeme ver. ' } },
        { type: 'content_block_stop', index: 0 },
        { type: 'content_block_start', index: 1, content_block: { type: 'tool_use', id: 'tu_1', name: 'look', input: {} } },
        { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: json.slice(0, 5) } },
        { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: json.slice(5) } },
        { type: 'content_block_stop', index: 1 },
        { type: 'message_delta', delta: { stop_reason: 'tool_use' } }
      );
    } else {
      ev.push(
        { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
        { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Es una taza azul. Cuesta 3.5 dólares' } },
        { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: ', creo. **Bonita**, ¿no?' } },
        { type: 'content_block_stop', index: 0 },
        { type: 'message_delta', delta: { stop_reason: 'end_turn' } }
      );
    }
    ev.push({ type: 'message_stop' });
    res.end(sse(ev));
  });
});
await new Promise((r) => fake.listen(18999, r));

// ---------- servidor Jarvis ----------
function start(port, extra) {
  const child = spawn('node', ['src/server.js'], {
    env: { ...process.env, PORT: String(port), JARVIS_TOKEN: TOKEN, TV_SECRET: 'tvsecret', WA_VERIFY_TOKEN: 'verif', DATA_DIR: `/tmp/jarvis-test-${port}`, ...extra },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => process.stderr.write(d));
  return child;
}
const srvMock = start(18081, { MOCK_LLM: '1' });
const srvReal = start(18082, { ANTHROPIC_API_KEY: 'k', ANTHROPIC_BASE_URL: 'http://127.0.0.1:18999', WEB_SEARCH: '0' });
await sleep(900);

function client(port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
  const inbox = [];
  const waiters = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    inbox.push(m);
    for (const w of [...waiters]) if (w.pred(m)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(m); }
  };
  const wait = (pred, ms = 3000) =>
    new Promise((resolve, reject) => {
      const hit = inbox.find(pred);
      if (hit) return resolve(hit);
      const w = { pred, resolve };
      waiters.push(w);
      setTimeout(() => reject(new Error('timeout esperando evento; inbox=' + JSON.stringify(inbox.map((x) => x.type)))), ms);
    });
  const open = new Promise((r) => (ws.onopen = r));
  return { ws, inbox, wait, open, send: (o) => ws.send(JSON.stringify(o)) };
}

try {
  console.log('Servidor (LLM simulado)');
  let r = await fetch('http://127.0.0.1:18081/health');
  assert.equal((await r.json()).ok, true); ok('health');

  r = await fetch('http://127.0.0.1:18081/webhook/tradingview?secret=mal', { method: 'POST', body: 'x' });
  assert.equal(r.status, 401); ok('tradingview rechaza secreto malo');

  // alerta con la app desconectada → cola → se entrega al conectar
  r = await fetch('http://127.0.0.1:18081/webhook/tradingview?secret=tvsecret', { method: 'POST', body: JSON.stringify({ symbol: 'XAUUSD', action: 'BUY', price: 2650.5 }) });
  assert.equal(r.status, 200);
  r = await fetch('http://127.0.0.1:18081/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=verif&hub.challenge=abc123');
  assert.equal(await r.text(), 'abc123'); ok('whatsapp verify challenge');
  r = await fetch('http://127.0.0.1:18081/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=no&hub.challenge=abc');
  assert.equal(r.status, 403); ok('whatsapp verify rechaza token malo');
  await fetch('http://127.0.0.1:18081/webhook/whatsapp', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ entry: [{ changes: [{ value: { contacts: [{ wa_id: '17875551234', profile: { name: 'María' } }], messages: [{ id: 'w1', from: '17875551234', type: 'text', text: { body: 'Hola, ¿vienes hoy?' } }] } }] }] }) });

  const c = client(18081);
  await c.open;
  c.send({ type: 'hello', token: 'incorrecto' });
  await sleep(200);
  assert.equal(c.inbox.length, 0); ok('hello con token malo no recibe nada');

  const c2 = client(18081);
  await c2.open;
  c2.send({ type: 'hello', token: TOKEN });
  await c2.wait((m) => m.type === 'ready'); ok('hello correcto → ready');
  const alert = await c2.wait((m) => m.type === 'alert');
  assert.match(alert.text, /XAUUSD BUY a 2650.5/); assert.equal(alert.late, true); ok('alerta TradingView en cola entregada al conectar');
  const wa = await c2.wait((m) => m.type === 'whatsapp_in');
  assert.equal(wa.name, 'María'); ok('WhatsApp entrante entregado');

  c2.send({ type: 'utterance', id: 'u1', text: 'hola jarvis' });
  const say = await c2.wait((m) => m.type === 'say' && m.id === 'u1');
  await c2.wait((m) => m.type === 'done' && m.id === 'u1');
  assert.match(say.text, /Mock/); ok('utterance → say + done');

  c2.send({ type: 'utterance', id: 'u2', text: 'mira esto' });
  const cap = await c2.wait((m) => m.type === 'capture_request');
  c2.send({ type: 'capture_result', reqId: cap.reqId, imageBase64: 'QUJD' });
  await c2.wait((m) => m.type === 'say' && /imagen de 4/.test(m.text)); ok('flujo de captura de cámara (look)');

  c2.send({ type: 'utterance', id: 'u3', text: 'navega a Plaza Las Américas' });
  const nav = await c2.wait((m) => m.type === 'navigate');
  assert.match(nav.destination, /Plaza Las Américas/); ok('navigate emitido');

  r = await fetch('http://127.0.0.1:18081/push', { method: 'POST', headers: { authorization: 'Bearer ' + TOKEN }, body: '{"text":"Prueba push"}' });
  assert.equal((await r.json()).delivered, true);
  await c2.wait((m) => m.type === 'alert' && m.text === 'Prueba push'); ok('/push entrega texto a las gafas');
  r = await fetch('http://127.0.0.1:18081/push', { method: 'POST', body: '{"text":"x"}' });
  assert.equal(r.status, 401); ok('/push exige token');

  console.log('Cerebro real (Anthropic simulado, bucle de herramientas)');
  const d = client(18082);
  await d.open;
  d.send({ type: 'hello', token: TOKEN });
  await d.wait((m) => m.type === 'ready');
  d.send({ type: 'utterance', id: 'r1', text: '¿qué es esto?', location: { lat: 18.4, lon: -66.1, place: 'San Juan' } });
  const cap2 = await d.wait((m) => m.type === 'capture_request');
  d.send({ type: 'capture_result', reqId: cap2.reqId, imageBase64: 'QUJDRA==' });
  await d.wait((m) => m.type === 'done' && m.id === 'r1');
  const says = d.inbox.filter((m) => m.type === 'say').map((m) => m.text);
  assert.deepEqual(says, ['Déjeme ver.', 'Es una taza azul.', 'Cuesta 3.5 dólares, creo.', 'Bonita, ¿no?']);
  ok('frases troceadas para voz (3.5 intacto, markdown limpio): ' + JSON.stringify(says));
  assert.equal(anthropicCalls.length, 2); ok('2 llamadas a la API (tool_use → tool_result)');
  const second = anthropicCalls[1].messages.at(-1).content[0];
  assert.equal(second.type, 'tool_result');
  assert.equal(second.content[0].type, 'image');
  assert.equal(second.content[0].source.data, 'QUJDRA=='); ok('la foto llega a Claude como bloque image base64');
  assert.match(anthropicCalls[0].system[1].text, /San Juan/); ok('ubicación inyectada en el contexto');
  assert.equal(anthropicCalls[0].model, 'claude-sonnet-5-5'); ok('modelo por defecto claude-sonnet-5-5');
  assert.ok(anthropicCalls[0].tools.some((t) => t.name === 'whatsapp_draft')); ok('herramientas expuestas');
  console.log(`\n${pass} pruebas OK`);
} catch (e) {
  console.error('\nFALLÓ:', e.message);
  process.exitCode = 1;
} finally {
  srvMock.kill();
  srvReal.kill();
  fake.close();
  setTimeout(() => process.exit(process.exitCode || 0), 100);
}

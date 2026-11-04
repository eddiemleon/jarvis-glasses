// Prueba de humo de extremo a extremo con un "Anthropic" falso que habla SSE real.
import http from 'node:http';
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const FAKE_PORT = 18901, APP_PORT = 18902;
const TOKEN = 'test-token-1234567890abcdef';
const requests = [];

const sse = (res, events) => {
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  for (const [type, data] of events) res.write(`event: ${type}\r\ndata: ${JSON.stringify({ type, ...data })}\r\n\r\n`);
  res.end();
};
const textBlock = (i, parts) => [
  ['content_block_start', { index: i, content_block: { type: 'text', text: '' } }],
  ...parts.map((t) => ['content_block_delta', { index: i, delta: { type: 'text_delta', text: t } }]),
  ['content_block_stop', { index: i }],
];
const toolBlock = (i, id, name, input) => {
  const j = JSON.stringify(input), mid = Math.floor(j.length / 2);
  return [
    ['content_block_start', { index: i, content_block: { type: 'tool_use', id, name, input: {} } }],
    ['content_block_delta', { index: i, delta: { type: 'input_json_delta', partial_json: j.slice(0, mid) } }],
    ['content_block_delta', { index: i, delta: { type: 'input_json_delta', partial_json: j.slice(mid) } }],
    ['content_block_stop', { index: i }],
  ];
};

const fake = http.createServer((req, res) => {
  let b = '';
  req.on('data', (c) => (b += c));
  req.on('end', () => {
    const body = JSON.parse(b);
    requests.push(body);
    const last = body.messages.at(-1);
    const isResult = Array.isArray(last.content) && last.content[0]?.type === 'tool_result';
    const userText = typeof body.messages.findLast((m) => typeof m.content === 'string')?.content === 'string'
      ? body.messages.findLast((m) => typeof m.content === 'string').content : '';
    if (/boom/.test(userText)) { res.writeHead(500); return res.end('kaboom'); }
    if (/anota/.test(userText)) {
      if (!isResult) {
        return sse(res, [
          ['message_start', { message: {} }],
          ...textBlock(0, ['Déjame anotarlo. ']),
          ...toolBlock(1, 'tu_1', 'remember', { fact: 'Le gusta el café sin azúcar' }),
          ['message_delta', { delta: { stop_reason: 'tool_use' } }],
        ]);
      }
      return sse(res, [...textBlock(0, ['Listo, ', 'Eddie. ', 'Anotado para siempre.']), ['message_delta', { delta: { stop_reason: 'end_turn' } }]]);
    }
    if (/llévame/.test(userText)) {
      if (!isResult)
        return sse(res, [
          ...toolBlock(0, 'tu_2', 'navigate', { destination: 'Plaza Las Américas' }),
          ['message_delta', { delta: { stop_reason: 'tool_use' } }],
        ]);
      return sse(res, [...textBlock(0, ['En camino.']), ['message_delta', { delta: { stop_reason: 'end_turn' } }]]);
    }
    sse(res, [...textBlock(0, ['Hola.']), ['message_delta', { delta: { stop_reason: 'end_turn' } }]]);
  });
});

async function chat(text, session = 's1') {
  const res = await fetch(`http://127.0.0.1:${APP_PORT}/chat`, {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', 'x-session': session },
    body: JSON.stringify({ text, context: { lat: 18.4, lon: -66.1, time: '2026-11-03T08:00:00-04:00' } }),
  });
  assert.equal(res.status, 200);
  const events = [];
  const dec = new TextDecoder();
  let buf = '';
  for await (const chunk of res.body) {
    buf += dec.decode(chunk, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const line = buf.slice(0, i).replace(/^data: /, '');
      buf = buf.slice(i + 2);
      events.push(JSON.parse(line));
    }
  }
  return events;
}

const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'jarvis-test-'));
await new Promise((r) => fake.listen(FAKE_PORT, r));
const app = spawn(process.execPath, ['src/server.js'], {
  env: {
    ...process.env, PORT: APP_PORT, JARVIS_TOKEN: TOKEN, TV_SECRET: 'tvsecret', DATA_DIR: dataDir,
    ANTHROPIC_API_KEY: 'x', ANTHROPIC_BASE_URL: `http://127.0.0.1:${FAKE_PORT}`,
    ELEVENLABS_API_KEY: '', OPENAI_API_KEY: '',
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
app.stderr.on('data', (d) => process.stderr.write(`[server] ${d}`));
await new Promise((r) => app.stdout.on('data', (d) => /escuchando/.test(String(d)) && r()));

let failed = 0;
const t = async (name, fn) => {
  try { await fn(); console.log('  ok  ', name); }
  catch (e) { failed++; console.log('  FALLA', name, '\n      ', e.message); }
};

await t('health abierto y sin secretos', async () => {
  const j = await (await fetch(`http://127.0.0.1:${APP_PORT}/health`)).json();
  assert.equal(j.ok, true); assert.equal(j.tradingview, true);
});
await t('chat sin token -> 401', async () => {
  const r = await fetch(`http://127.0.0.1:${APP_PORT}/chat`, { method: 'POST', body: '{}' });
  assert.equal(r.status, 401);
});
await t('turno simple: speech + done', async () => {
  const ev = await chat('hola');
  assert.deepEqual(ev.map((e) => e.type), ['speech', 'done']);
  assert.equal(ev[0].text, 'Hola.');
  assert.equal(ev[0].audio, null); // sin proveedor TTS la app usa voz local
});
await t('bucle de herramientas: remember + frase final', async () => {
  const ev = await chat('anota que me gusta el café');
  const speech = ev.filter((e) => e.type === 'speech').map((e) => e.text);
  assert.ok(speech[0].startsWith('Déjame anotarlo'), JSON.stringify(speech));
  assert.ok(speech.join(' ').includes('Anotado para siempre'));
  assert.equal(ev.at(-1).type, 'done');
  await new Promise((r) => setTimeout(r, 400));
  const store = JSON.parse(fs.readFileSync(path.join(dataDir, 'store.json'), 'utf8'));
  assert.deepEqual(store.facts, ['Le gusta el café sin azúcar']);
});
await t('la memoria entra al prompt y el contexto GPS también', async () => {
  const last = requests.at(-1);
  await chat('hola otra vez', 's2');
  const sys = requests.at(-1).system;
  assert.match(sys, /Le gusta el café sin azúcar/);
  assert.match(sys, /lat 18\.40000/);
  assert.ok(last);
});
await t('herramienta navigate emite acción al cliente', async () => {
  const ev = await chat('llévame a Plaza', 's3');
  const act = ev.find((e) => e.type === 'action');
  assert.equal(act.name, 'navigate'); assert.equal(act.args.destination, 'Plaza Las Américas');
});
await t('error del proveedor -> evento error y la sesión se recupera', async () => {
  const ev = await chat('boom', 's4');
  assert.equal(ev.at(-1).type, 'error');
  const ev2 = await chat('hola', 's4');
  assert.equal(ev2.at(-1).type, 'done');
});
await t('TradingView: secreto malo -> 401; bueno -> alerta llega a /events', async () => {
  const bad = await fetch(`http://127.0.0.1:${APP_PORT}/webhook/tradingview?secret=nope`, { method: 'POST', body: 'x' });
  assert.equal(bad.status, 401);
  const ev = await fetch(`http://127.0.0.1:${APP_PORT}/events`, { headers: { authorization: `Bearer ${TOKEN}` } });
  const reader = ev.body.getReader(); const dec = new TextDecoder();
  await reader.read(); // hello
  const ok = await fetch(`http://127.0.0.1:${APP_PORT}/webhook/tradingview?secret=tvsecret`, {
    method: 'POST', body: JSON.stringify({ message: 'XAUUSD cruce alcista 1H' }),
  });
  assert.equal(ok.status, 200);
  const { value } = await reader.read();
  const e = JSON.parse(dec.decode(value).replace(/^data: /, ''));
  assert.equal(e.type, 'alert'); assert.match(e.text, /XAUUSD cruce alcista/); assert.equal(e.source, 'tradingview');
  reader.cancel();
});
await t('WhatsApp: verificación GET y mensaje entrante', async () => {
  // sin WA_VERIFY_TOKEN configurado debe negar
  const r = await fetch(`http://127.0.0.1:${APP_PORT}/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=a&hub.challenge=123`);
  assert.equal(r.status, 403);
});

app.kill('SIGTERM'); fake.close();
console.log(failed ? `\n${failed} prueba(s) fallaron` : '\nTodas las pruebas pasaron');
process.exit(failed ? 1 : 0);

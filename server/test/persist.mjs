// Memoria que sobrevive reinicios (copia en el iPhone), latido y autorreparación ante error 400.
import { spawn } from 'node:child_process';
import http from 'node:http';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
const TOKEN = 'test-token-persist-0123456789';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let pass = 0;
const ok = (n) => console.log('  ✓', n) || pass++;
let calls = [];
let fail400 = 0;
const sse = (ev) => ev.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join('');
const text = (t) => [
  { type: 'message_start', message: { id: 'm', role: 'assistant', content: [] } },
  { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: t } },
  { type: 'content_block_stop', index: 0 },
  { type: 'message_delta', delta: { stop_reason: 'end_turn' } },
  { type: 'message_stop' },
];
const fake = http.createServer((req, res) => {
  let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
    const p = JSON.parse(b); calls.push(p);
    if (fail400 > 0 && p.messages.length > 1) { fail400--; res.writeHead(400); return res.end('{"error":{"message":"messages: tool_use ids without tool_result"}}'); }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const last = p.messages.at(-1).content;
    res.end(sse(text(/recuerda/i.test(last) ? 'Anotado, señor.' : `Usted me dijo antes: ${p.messages.length > 1 ? 'sí recuerdo' : 'nada'}.`)));
  });
});
await new Promise((r) => fake.listen(18997, r));
function start(dir) {
  const c = spawn('node', ['src/server.js'], { env: { ...process.env, PORT: '18085', JARVIS_TOKEN: TOKEN, DATA_DIR: dir, ANTHROPIC_API_KEY: 'k', ANTHROPIC_BASE_URL: 'http://127.0.0.1:18997', WEB_SEARCH: '0' }, stdio: ['ignore', 'pipe', 'pipe'] });
  c.stdout.on('data', () => {}); c.stderr.on('data', (d) => process.stderr.write(d));
  return c;
}
function client(hello) {
  const ws = new WebSocket('ws://127.0.0.1:18085/ws'); const inbox = [];
  ws.onmessage = (e) => inbox.push(JSON.parse(e.data));
  const wait = async (pred, ms = 6000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const i = inbox.findIndex(pred); if (i >= 0) return inbox.splice(i, 1)[0]; await sleep(30); } throw new Error('timeout ' + JSON.stringify(inbox.map((x) => x.type))); };
  const open = new Promise((r) => (ws.onopen = () => { ws.send(JSON.stringify({ type: 'hello', token: TOKEN, ...hello })); r(); }));
  return { ws, inbox, wait, open, send: (o) => ws.send(JSON.stringify(o)) };
}
const said = async (c, id) => { await c.wait((m) => m.type === 'done' && m.id === id); return c.inbox.filter((m) => m.type === 'say' && m.id === id).map((m) => m.text).join(' '); };
rmSync('/tmp/jp-a', { recursive: true, force: true }); rmSync('/tmp/jp-b', { recursive: true, force: true });
let srv = start('/tmp/jp-a'); await sleep(900);
try {
  console.log('Memoria que sobrevive reinicios del servidor');
  let c = client({}); await c.open; await c.wait((m) => m.type === 'ready');
  c.send({ type: 'utterance', id: 'u1', text: 'recuerda que mi stop en oro es 8 dólares' });
  await said(c, 'u1');
  const sync = await c.wait((m) => m.type === 'sync', 5000);
  assert.ok(Array.isArray(sync.history) && sync.history.length === 2);
  ok('tras cada conversación el servidor manda una copia de la memoria al iPhone');
  c.ws.close(); srv.kill(); await sleep(300);
  srv = start('/tmp/jp-b'); await sleep(900); // servidor nuevo y vacío = Render gratis tras dormirse
  calls = [];
  c = client({ restore: { state: sync.state, history: sync.history } }); await c.open; await c.wait((m) => m.type === 'ready');
  c.send({ type: 'utterance', id: 'u2', text: '¿qué te dije?' });
  assert.match(await said(c, 'u2'), /sí recuerdo/);
  assert.equal(calls[0].messages[0].content, 'recuerda que mi stop en oro es 8 dólares');
  ok('servidor reiniciado y vacío: al reconectar recupera la conversación desde el iPhone');

  console.log('Latido');
  const hb = await c.wait((m) => m.type === 'hb', 25000);
  assert.ok(hb); await sleep(200);
  assert.equal(c.ws.readyState, 1);
  ok('el servidor manda latidos y NO corta la app a los 60 s (antes se cortaba siempre)');

  console.log('Autorreparación');
  fail400 = 1;
  c.send({ type: 'utterance', id: 'u3', text: 'hola' });
  const r = await said(c, 'u3');
  assert.doesNotMatch(r, /Tuve un problema/);
  ok('si el historial queda inconsistente (error 400) se limpia y responde igual, sin "Tuve un problema"');
  console.log(`\n${pass} pruebas OK`);
} catch (e) { console.error('\nFALLÓ:', e.stack || e.message); process.exitCode = 1; }
finally { srv.kill(); fake.close(); setTimeout(() => process.exit(process.exitCode || 0), 100); }

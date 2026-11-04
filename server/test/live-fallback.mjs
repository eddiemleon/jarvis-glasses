// Pruebas: transmisión en vivo (app → servidor → visor), respaldo de IA sin créditos y recordatorios.
import { spawn } from 'node:child_process';
import http from 'node:http';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
rmSync('/tmp/jarvis-test-live', { recursive: true, force: true });

const TOKEN = 'test-token-0123456789abcdef';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let pass = 0;
const ok = (n) => console.log('  ✓', n) || pass++;

// ---- Anthropic falso: sin créditos (402) ----
let claudeHits = 0;
const claude = http.createServer((req, res) => {
  claudeHits++;
  req.resume();
  res.writeHead(402, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ type: 'error', error: { type: 'billing_error', message: 'Your credit balance is too low to access the Anthropic API.' } }));
});
// ---- Proveedor de respaldo (formato OpenAI): 1ª llamada pide herramienta, 2ª responde ----
const bodies = [];
const backup = http.createServer((req, res) => {
  let b = '';
  req.on('data', (c) => (b += c));
  req.on('end', () => {
    const p = JSON.parse(b);
    bodies.push(p);
    const sawTool = p.messages.some((m) => m.role === 'tool');
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const chunk = (delta, finish = null) => `data: ${JSON.stringify({ choices: [{ delta, finish_reason: finish }] })}\n\n`;
    if (!sawTool) {
      res.write(chunk({ content: 'Anotado. ' }));
      res.write(chunk({ tool_calls: [{ index: 0, id: 'call_1', function: { name: 'set_reminder', arguments: '{"text":"Llamar a Ma' } }] }));
      res.write(chunk({ tool_calls: [{ index: 0, function: { arguments: 'ría","in_minutes":0.02}' } }] }, 'tool_calls'));
    } else {
      res.write(chunk({ content: 'Listo, le avisaré en un momento.' }, 'stop'));
    }
    res.end('data: [DONE]\n\n');
  });
});
await new Promise((r) => claude.listen(18991, r));
await new Promise((r) => backup.listen(18992, r));

const srv = spawn('node', ['src/server.js'], {
  env: {
    ...process.env, PORT: '18083', JARVIS_TOKEN: TOKEN, DATA_DIR: '/tmp/jarvis-test-live', WEB_SEARCH: '0',
    ANTHROPIC_API_KEY: 'k', ANTHROPIC_BASE_URL: 'http://127.0.0.1:18991',
    FALLBACK_BASE_URL: 'http://127.0.0.1:18992', FALLBACK_MODEL: 'modelo-respaldo', FALLBACK_API_KEY: 'x',
    PUBLIC_URL: 'https://jarvis.example.com',
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
srv.stderr.on('data', (d) => process.stderr.write(d));
await sleep(900);

function client(path) {
  const ws = new WebSocket(`ws://127.0.0.1:18083${path}`);
  ws.binaryType = 'arraybuffer';
  const inbox = [];
  const bins = [];
  const waiters = [];
  ws.onmessage = (e) => {
    if (typeof e.data !== 'string') return bins.push(new Uint8Array(e.data));
    const m = JSON.parse(e.data);
    inbox.push(m);
    for (const w of [...waiters]) if (w.pred(m)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(m); }
  };
  const wait = (pred, ms = 4000) => new Promise((resolve, reject) => {
    const hit = inbox.find(pred);
    if (hit) return resolve(hit);
    waiters.push({ pred, resolve });
    setTimeout(() => reject(new Error('timeout; inbox=' + JSON.stringify(inbox.map((x) => x.type)))), ms);
  });
  const closed = new Promise((r) => (ws.onclose = (e) => r(e.code)));
  return { ws, inbox, bins, wait, closed, open: new Promise((r) => (ws.onopen = r)), send: (o) => ws.send(JSON.stringify(o)) };
}

try {
  console.log('Transmisión en vivo');
  const app = client('/ws');
  await app.open;
  app.send({ type: 'hello', token: TOKEN });
  await app.wait((m) => m.type === 'ready');
  const h = await (await fetch('http://127.0.0.1:18083/health')).json();
  assert.deepEqual(h.brains, ['claude:claude-sonnet-5-5', 'cerebro2:modelo-respaldo']); ok('health lista los cerebros en orden de respaldo');

  app.send({ type: 'live_start', ttl: 30 });
  const link = await app.wait((m) => m.type === 'live_link');
  assert.match(link.url, /^https:\/\/jarvis\.example\.com\/live\/[\w-]{20,}$/); ok('enlace público con id aleatorio: ' + link.url.slice(0, 48) + '…');
  const id = link.url.split('/').pop();

  let r = await fetch(`http://127.0.0.1:18083/live/${id}`);
  assert.equal(r.status, 200); assert.match(await r.text(), /Jarvis · En vivo/); ok('página del visor se sirve con el enlace correcto');
  r = await fetch('http://127.0.0.1:18083/live/adivinando');
  assert.equal(r.status, 404); ok('un id inventado da 404');

  const bad = client('/live/ws?id=nope');
  await bad.open;
  assert.equal(await bad.closed, 1008); ok('visor con id inválido rechazado');

  // primer cuadro antes de que entre el visor → debe recibirlo al conectarse
  app.ws.send(new Uint8Array([1, 0xff, 0xd8, 0xff, 1, 2, 3]));
  await sleep(150);
  const viewer = client(`/live/ws?id=${id}`);
  await viewer.open;
  await viewer.wait((m) => m.type === 'hello');
  await app.wait((m) => m.type === 'live_viewers' && m.n === 1); ok('la app se entera de que hay 1 espectador');
  await sleep(150);
  assert.equal(viewer.bins.length, 1); assert.equal(viewer.bins[0][0], 1); ok('el visor recibe de inmediato el último cuadro');

  app.ws.send(new Uint8Array([2, 10, 0, 20, 0]));
  app.ws.send(new Uint8Array([1, 0xff, 0xd8, 9, 9]));
  await sleep(250);
  assert.equal(viewer.bins.length, 3);
  assert.deepEqual([...viewer.bins[1]], [2, 10, 0, 20, 0]); ok('audio PCM y video se reenvían intactos');

  app.send({ type: 'live_stop' });
  const ended = await viewer.wait((m) => m.type === 'ended'); assert.equal(ended.reason, 'stopped');
  await app.wait((m) => m.type === 'live_ended'); ok('al detener, el visor y la app reciben el fin');
  r = await fetch(`http://127.0.0.1:18083/live/${id}`);
  assert.equal(r.status, 404); ok('el enlace deja de funcionar al terminar');

  console.log('IA de respaldo + recordatorios');
  app.send({ type: 'utterance', id: 'f1', text: 'recuérdame llamar a María en un momento' });
  await app.wait((m) => m.type === 'done' && m.id === 'f1', 8000);
  const says = app.inbox.filter((m) => m.type === 'say' && m.id === 'f1').map((m) => m.text);
  assert.ok(says.slice(0, 2).join(' ').includes('sin créditos') && says.slice(0, 2).join(' ').includes('cerebro2')); ok('avisa por voz: "' + says.slice(0, 2).join(' ') + '"');
  assert.ok(says.includes('Anotado.') && says.includes('Listo, le avisaré en un momento.')); ok('el respaldo responde con herramientas (bucle tool_calls)');
  assert.equal(claudeHits, 1); ok('Claude solo se intentó una vez (queda marcado como caído)');
  const toolMsg = bodies[1].messages.find((m) => m.role === 'tool');
  assert.equal(toolMsg.tool_call_id, 'call_1'); assert.match(toolMsg.content, /Recordatorio/); ok('resultado de la herramienta vuelve en formato OpenAI');
  assert.ok(bodies[0].tools.some((t) => t.function.name === 'look')); ok('herramientas traducidas a formato OpenAI');
  const rem = await app.wait((m) => m.type === 'alert' && m.source === 'reminder', 5000);
  assert.equal(rem.text, 'Llamar a María'); ok('el recordatorio suena a la hora: "' + rem.text + '"');

  app.send({ type: 'utterance', id: 'f2', text: 'hola otra vez' });
  await app.wait((m) => m.type === 'done' && m.id === 'f2', 8000);
  assert.equal(claudeHits, 1); ok('mientras Claude esté caído, ya no se le vuelve a llamar');
  const u = await (await fetch('http://127.0.0.1:18083/usage', { headers: { authorization: 'Bearer ' + TOKEN } })).json();
  assert.ok(u.down.claude && u.byProvider.cerebro2.calls >= 3); ok('/usage muestra el estado de cada cerebro');
  console.log(`\n${pass} pruebas OK`);
} catch (e) {
  console.error('\nFALLÓ:', e.message);
  process.exitCode = 1;
} finally {
  srv.kill(); claude.close(); backup.close();
  setTimeout(() => process.exit(process.exitCode || 0), 100);
}

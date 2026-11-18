// Pruebas de las capacidades nuevas: transmisión sin retraso + foto HD, memoria visual, rutinas,
// calendario, intérprete, modelo económico. IA y app simuladas: no gasta créditos.
import { spawn } from 'node:child_process';
import http from 'node:http';
import assert from 'node:assert/strict';
import { rmSync, mkdirSync, writeFileSync, readFileSync, readdirSync } from 'node:fs';

const TOKEN = 'test-token-features-0123456789';
const DIR_A = '/tmp/jarvis-feat-a';
const DIR_B = '/tmp/jarvis-feat-b';
for (const d of [DIR_A, DIR_B, '/tmp/jarvis-feat-unit']) rmSync(d, { recursive: true, force: true });
process.env.DATA_DIR = '/tmp/jarvis-feat-unit';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let pass = 0;
const ok = (name) => console.log('  ✓', name) || pass++;

// ---------------- pruebas unitarias (en proceso) ----------------
console.log('Horas y zonas');
const { parseWhen, parseDays, describeDays, localNow } = await import('../src/routines.js');
assert.equal(new Date(parseWhen('2026-11-04T15:00', 'America/Puerto_Rico')).toISOString(), '2026-11-04T19:00:00.000Z');
ok('"15:00" sin zona = 3 pm de Puerto Rico (19:00 UTC), no 3 pm UTC');
assert.equal(new Date(parseWhen('2026-03-07T12:00', 'America/New_York')).toISOString(), '2026-03-07T17:00:00.000Z');
assert.equal(new Date(parseWhen('2026-03-09T12:00', 'America/New_York')).toISOString(), '2026-03-09T16:00:00.000Z');
ok('cambio de horario (Nueva York) correcto antes y después');
assert.equal(new Date(parseWhen('2026-11-04T15:00:00-04:00')).toISOString(), '2026-11-04T19:00:00.000Z');
assert.equal(new Date(parseWhen('2026-11-04T19:00:00Z')).toISOString(), '2026-11-04T19:00:00.000Z');
ok('fechas con zona se respetan tal cual');
assert.deepEqual(parseDays(['laborables']), [1, 2, 3, 4, 5]);
assert.deepEqual(parseDays(['Sábado', 'dom']), [0, 6]);
assert.deepEqual(parseDays(undefined), [0, 1, 2, 3, 4, 5, 6]);
assert.equal(describeDays([1, 2, 3, 4, 5]), 'de lunes a viernes');
ok('días: laborables, nombres con acento, diario por defecto');

console.log('Transmisión en vivo: siempre el cuadro más reciente');
const { live } = await import('../src/live.js');
live.create(5);
const mkViewer = (backlog) => ({ backlog, got: [], sendBinary(b) { this.got.push(b[0]); }, send() {}, on() {}, close() {} });
const fast = mkViewer(0);
const slow = mkViewer(50_000); // aún tiene ~50 KB pendientes
live.current.viewers.add(fast);
live.current.viewers.add(slow);
const frame = Buffer.concat([Buffer.from([1]), Buffer.alloc(20_000)]);
live.relay(frame);
live.relay(Buffer.concat([Buffer.from([2]), Buffer.alloc(640)]));
assert.deepEqual(fast.got, [1, 2]);
assert.deepEqual(slow.got, [2]);
ok('visor atrasado: se salta el cuadro viejo (no se acumula retraso) pero sigue recibiendo audio');
slow.backlog = 0;
live.relay(frame);
assert.deepEqual(slow.got, [2, 1]);
ok('en cuanto se pone al día recibe el cuadro más nuevo');
live.relay(Buffer.concat([Buffer.from([3]), Buffer.alloc(300_000)]));
assert.equal(fast.got.at(-1), 3);
ok('la foto en máxima calidad (paquete 0x03) llega al visor');
live.stop('test', false);

console.log('Respaldo (Gemini/OpenAI): imágenes directas');
const { toOpenAI } = await import('../src/openai.js');
const conv = toOpenAI(
  { system: [{ text: 's' }], max_tokens: 10, messages: [{ role: 'user', content: [{ type: 'image', source: { media_type: 'image/jpeg', data: 'QQ==' } }, { type: 'text', text: 'hola' }] }] },
  { model: 'm' }
);
assert.equal(conv.messages[1].content[0].image_url.url, 'data:image/jpeg;base64,QQ==');
assert.equal(conv.messages[1].content[1].text, 'hola');
ok('una imagen enviada directo ya no se pierde con cerebros de respaldo');

// ---------------- Anthropic simulado ----------------
let calls = [];
let failHaikuOnce = true;
const sse = (events) => events.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join('');
const textMsg = (t) => [
  { type: 'message_start', message: { id: 'm', role: 'assistant', content: [], usage: { input_tokens: 1 } } },
  { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: t } },
  { type: 'content_block_stop', index: 0 },
  { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 3 } },
  { type: 'message_stop' },
];
const toolMsg = (name, input) => [
  { type: 'message_start', message: { id: 'm', role: 'assistant', content: [] } },
  { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'tu_' + calls.length, name, input: {} } },
  { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(input) } },
  { type: 'content_block_stop', index: 0 },
  { type: 'message_delta', delta: { stop_reason: 'tool_use' } },
  { type: 'message_stop' },
];
const resultText = (tr) => (typeof tr.content === 'string' ? tr.content : tr.content.filter((c) => c.type === 'text').map((c) => c.text).join(' | '));

const fake = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const p = JSON.parse(body);
    calls.push(p);
    const sys = p.system.map((s) => s.text).join('\n');
    if (p.model === 'claude-haiku-5-5' && failHaikuOnce) {
      failHaikuOnce = false;
      res.writeHead(404, { 'content-type': 'application/json' });
      return res.end('{"type":"error","error":{"type":"not_found_error","message":"model: claude-haiku-5-5"}}');
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const last = p.messages.at(-1);
    let ev;
    if (/intérprete de JARVIS/.test(sys)) ev = textMsg(/ruido/.test(last.content) ? '(nada)' : '"Hola, ¿cómo está usted?"');
    else if (/Describe en UNA frase/.test(sys)) ev = textMsg('Las llaves están sobre la mesa de la cocina, junto al microondas.');
    else if (typeof last.content === 'string' && last.content.startsWith('[Rutina programada')) {
      ev = /PELIGRO/.test(last.content) ? toolMsg('whatsapp_send_confirmed', { draft_id: 'x' }) : textMsg('Buenos días, señor. Briefing de prueba listo.');
    } else if (typeof last.content === 'string' && last.content.startsWith('DO ')) {
      const [, name, json] = last.content.match(/^DO (\w+) ?(.*)$/);
      ev = toolMsg(name, json ? JSON.parse(json) : {});
    } else if (Array.isArray(last.content) && last.content[0]?.type === 'tool_result') {
      ev = textMsg('RESULT: ' + resultText(last.content[0]));
    } else ev = textMsg('ok.');
    res.end(sse(ev));
  });
});
await new Promise((r) => fake.listen(18998, r));

function start(port, dir) {
  const child = spawn('node', ['src/server.js'], {
    env: { ...process.env, PORT: String(port), JARVIS_TOKEN: TOKEN, DATA_DIR: dir, ANTHROPIC_API_KEY: 'k', ANTHROPIC_BASE_URL: 'http://127.0.0.1:18998', WEB_SEARCH: '0', JARVIS_TZ: 'America/Puerto_Rico' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => process.stderr.write(d));
  return child;
}

function client(port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
  ws.binaryType = 'arraybuffer';
  const inbox = [];
  const waiters = [];
  ws.onmessage = (e) => {
    if (typeof e.data !== 'string') return;
    const m = JSON.parse(e.data);
    inbox.push(m);
    for (const w of [...waiters]) if (w.pred(m)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(m); }
  };
  const wait = (pred, ms = 4000) =>
    new Promise((resolve, reject) => {
      const hit = inbox.find(pred);
      if (hit) { inbox.splice(inbox.indexOf(hit), 1); return resolve(hit); }
      const w = { pred, resolve: (m) => { inbox.splice(inbox.indexOf(m), 1); resolve(m); } };
      waiters.push(w);
      setTimeout(() => reject(new Error('timeout; inbox=' + JSON.stringify(inbox.map((x) => x.type + (x.text ? ':' + x.text.slice(0, 40) : ''))))), ms);
    });
  const open = new Promise((r) => (ws.onopen = r));
  return { ws, inbox, wait, open, send: (o) => ws.send(JSON.stringify(o)) };
}

// Turno completo: devuelve todo lo que Jarvis dijo.
async function turn(c, id, text, extra = {}, onRequest) {
  c.send({ type: 'utterance', id, text, ...extra });
  if (onRequest) await onRequest();
  await c.wait((m) => m.type === 'done' && m.id === id, 8000);
  const said = [];
  for (let i = c.inbox.length - 1; i >= 0; i--) if (c.inbox[i].type === 'say' && c.inbox[i].id === id) said.unshift(c.inbox.splice(i, 1)[0].text);
  return said.join(' ');
}

// Servidor B con una rutina sembrada para AHORA (prueba que se dispara sola).
mkdirSync(DIR_B, { recursive: true });
if (new Date().getSeconds() >= 50) await sleep((61 - new Date().getSeconds()) * 1000); // no sembrar justo al cambiar de minuto
const nowPR = localNow(new Date(), 'America/Puerto_Rico');
writeFileSync(
  DIR_B + '/state.json',
  JSON.stringify({
    routines: [
      { id: 'r1', prompt: 'Dame el briefing', time: nowPR.hm, days: [0, 1, 2, 3, 4, 5, 6], label: 'briefing', lastRun: '' },
      { id: 'r2', prompt: 'PELIGRO envía el WhatsApp', time: nowPR.hm, days: [0, 1, 2, 3, 4, 5, 6], label: 'peligrosa', lastRun: '' },
    ],
  })
);

const A = start(18083, DIR_A);
const B = start(18084, DIR_B);
await sleep(1000);

try {
  console.log('Una sola conexión (respuestas no se repiten)');
  const dup1 = client(18083); await dup1.open; dup1.send({ type: 'hello', token: TOKEN }); await dup1.wait((m) => m.type === 'ready');
  const dup2 = client(18083); await dup2.open; dup2.send({ type: 'hello', token: TOKEN }); await dup2.wait((m) => m.type === 'ready');
  await sleep(300);
  assert.equal(dup1.ws.readyState, 3, 'la conexión vieja debe cerrarse');
  ok('al reconectar, la conexión vieja se cierra');
  const said1 = await turn(dup2, 'd1', 'hola');
  assert.equal(dup2.inbox.filter((m) => m.type === 'say').length + said1.split('ok.').length - 2, 0);
  assert.equal(said1, 'ok.');
  ok('la respuesta llega una sola vez');
  dup2.ws.close();
  await sleep(200);

  console.log('Memoria visual + modelo económico');
  const c = client(18083);
  await c.open;
  c.send({ type: 'hello', token: TOKEN });
  await c.wait((m) => m.type === 'ready');

  let said = await turn(c, 'v1', 'DO visual_note {"label":"llaves"}', { location: { lat: 18.44, lon: -66.06, place: 'Calle Loíza, San Juan' } }, async () => {
    const cap = await c.wait((m) => m.type === 'capture_request');
    c.send({ type: 'capture_result', reqId: cap.reqId, imageBase64: '/9j/4AAQSkZJRg==' });
  });
  assert.match(said, /Guardado "llaves": Las llaves están sobre la mesa de la cocina/);
  assert.match(said, /Calle Loíza/);
  ok('"recuerda dónde dejé las llaves": foto + descripción + lugar');
  assert.equal(readdirSync(DIR_A + '/visual').filter((f) => f.endsWith('.jpg')).length, 1);
  assert.equal(readFileSync(DIR_A + '/visual/' + readdirSync(DIR_A + '/visual')[0]).toString('base64'), '/9j/4AAQSkZJRg==');
  ok('la foto queda guardada en el disco del servidor, intacta');
  const fastCalls = calls.filter((p) => /Describe en UNA frase/.test(p.system[0].text));
  // La conversación ya intenta Haiku primero: al no existir (404) cae a Sonnet y lo recuerda para todo lo demás.
  assert.equal(calls[0].model, 'claude-haiku-5-5');
  assert.ok(calls.slice(1).every((p) => p.model === 'claude-sonnet-5-5'));
  assert.deepEqual(fastCalls.map((p) => p.model), ['claude-sonnet-5-5']);
  ok('modelo económico: si Haiku no existe en la cuenta, cae a Sonnet sin romper nada');

  said = await turn(c, 'v2', 'DO visual_recall {"query":"¿dónde dejé las llaves?"}');
  assert.match(said, /llaves \(hace 0 min, cerca de Calle Loíza, San Juan\): Las llaves están sobre la mesa/);
  const recallResult = calls.at(-1).messages.at(-1).content[0];
  assert.ok(recallResult.content.some((b) => b.type === 'image' && b.source.data === '/9j/4AAQSkZJRg=='));
  ok('"¿dónde dejé las llaves?": responde con lugar y hora, y la IA ve la foto guardada');
  said = await turn(c, 'v3', 'DO visual_recall {"query":"pasaporte"}');
  assert.match(said, /No tengo nada guardado sobre "pasaporte"/);
  ok('si no hay nada guardado lo dice claro (no inventa)');

  console.log('Rutinas');
  said = await turn(c, 'r1', 'DO routine_add {"prompt":"Briefing","time":"7:30","days":["laborables"],"label":"briefing"}');
  assert.match(said, /Rutina \w+ "briefing" creada: de lunes a viernes a las 07:30/);
  ok('"de lunes a viernes a las 7:30 dame el briefing" → rutina creada');
  said = await turn(c, 'r2', 'DO routine_add {"prompt":"x","time":"25:99"}');
  assert.match(said, /Hora inválida/);
  ok('hora imposible rechazada con explicación');

  console.log('Calendario del iPhone');
  said = await turn(c, 'k1', 'DO calendar_add {"title":"Dentista","start":"2026-11-05T15:00","minutes":45}', {}, async () => {
    const rq = await c.wait((m) => m.type === 'device_request' && m.action === 'calendar_add');
    assert.equal(rq.params.start, '2026-11-05T19:00:00Z');
    assert.equal(rq.params.end, '2026-11-05T19:45:00Z');
    c.send({ type: 'device_result', reqId: rq.reqId, ok: true, data: { id: 'E1' } });
  });
  assert.match(said, /Evento creado: Dentista, jueves, 5 de noviembre de 2026, 3:00/);
  ok('"agéndame dentista mañana a las 3": hora correcta para el iPhone (UTC sin milisegundos)');
  said = await turn(c, 'k2', 'DO calendar_events {"days":1}', {}, async () => {
    const rq = await c.wait((m) => m.type === 'device_request' && m.action === 'calendar_events');
    c.send({ type: 'device_result', reqId: rq.reqId, ok: true, data: [{ title: 'Reunión con Pedro', start: '2026-11-04T10:00:00-04:00' }] });
  });
  assert.match(said, /Reunión con Pedro/);
  assert.match(said, /datos de terceros/);
  ok('"¿qué tengo hoy?": lee la agenda (marcada como datos, no órdenes)');
  said = await turn(c, 'k3', 'DO calendar_events {}', {}, async () => {
    const rq = await c.wait((m) => m.type === 'device_request');
    c.send({ type: 'device_result', reqId: rq.reqId, ok: false, error: 'Sin permiso para el calendario' });
  });
  assert.match(said, /Error: Sin permiso para el calendario/);
  ok('sin permiso de calendario: el error llega claro a la IA');

  console.log('Foto en máxima calidad');
  said = await turn(c, 'p1', 'DO photo_hd', {}, async () => {
    const rq = await c.wait((m) => m.type === 'device_request' && m.action === 'photo_hd');
    c.send({ type: 'device_result', reqId: rq.reqId, ok: true, data: { width: 3024, height: 4032, sharedLive: true } });
  });
  assert.match(said, /Foto guardada en Fotos del iPhone \(3024 por 4032\); también se envió a la transmisión/);
  ok('"toma una foto": máxima calidad, guardada y compartida con la transmisión');

  console.log('Intérprete');
  said = await turn(c, 'i1', 'DO interpreter_start {"locale":"fr-FR"}');
  const on = await c.wait((m) => m.type === 'interpreter');
  assert.deepEqual([on.on, on.locale], [true, 'fr-FR']);
  assert.match(said, /francés → español/);
  ok('"tradúceme del francés": la app cambia al reconocimiento en francés');
  c.send({ type: 'interpret', text: 'bonjour comment allez-vous', locale: 'fr-FR' });
  const sp = await c.wait((m) => m.type === 'speak');
  assert.equal(sp.text, 'Hola, ¿cómo está usted?');
  ok('frase en francés → traducción al oído (sin comillas, modelo económico)');
  assert.equal(calls.filter((p) => /intérprete de JARVIS/.test(p.system[0].text)).at(-1).model, 'claude-sonnet-5-5');
  c.send({ type: 'interpret', text: 'ruido ruido', locale: 'fr-FR' });
  await sleep(600);
  assert.equal(c.inbox.filter((m) => m.type === 'speak').length, 0);
  ok('ruido sin sentido: Jarvis se calla');
  await turn(c, 'i2', 'DO interpreter_stop');
  const off = await c.wait((m) => m.type === 'interpreter');
  assert.equal(off.on, false);
  ok('salir del modo intérprete');

  console.log('Transmisión de punta a punta (app → servidor → navegador)');
  c.send({ type: 'live_start', ttl: 5 });
  const link = await c.wait((m) => m.type === 'live_link');
  const id = link.url.split('/').pop();
  const v = new WebSocket(`ws://127.0.0.1:18083/live/ws?id=${id}`);
  v.binaryType = 'arraybuffer';
  const got = [];
  v.onmessage = (e) => typeof e.data !== 'string' && got.push(new Uint8Array(e.data));
  await new Promise((r) => (v.onopen = r));
  await c.wait((m) => m.type === 'live_viewers' && m.n === 1);
  const jpeg = new Uint8Array([1, 0xff, 0xd8, 0xff, 0xe0, 9, 9]);
  const photo = new Uint8Array(200_000).fill(7);
  photo[0] = 3;
  c.ws.send(jpeg);
  c.ws.send(photo);
  const t0 = Date.now();
  while (got.length < 2 && Date.now() - t0 < 3000) await sleep(20);
  assert.deepEqual([...got[0]], [...jpeg]);
  assert.equal(got[1].length, 200_000);
  assert.equal(got[1][0], 3);
  ok(`cuadro y foto HD llegan intactos al navegador (${Date.now() - t0} ms en local)`);
  const html = await (await fetch(link.url)).text();
  assert.match(html, /Foto en máxima calidad/);
  assert.match(html, /fps/);
  ok('el visor muestra cuadros por segundo y botón para ver/descargar la foto HD');
  v.close();

  console.log('Rutinas que se disparan solas');
  const b = client(18084);
  await b.open;
  b.send({ type: 'hello', token: TOKEN });
  await b.wait((m) => m.type === 'ready');
  const alerts = [await b.wait((m) => m.type === 'alert' && m.source === 'routine', 8000), await b.wait((m) => m.type === 'alert' && m.source === 'routine', 8000)];
  const texts = alerts.map((a) => a.text).sort();
  assert.ok(texts.some((t) => t === 'Buenos días, señor. Briefing de prueba listo.'));
  ok('a la hora programada Jarvis da el briefing solo, sin que le hablen');
  assert.ok(texts.some((t) => /RESULT: No disponible en rutinas/.test(t)));
  const bgCall = calls.find((p) => typeof p.messages[0].content === 'string' && /PELIGRO/.test(p.messages[0].content));
  assert.ok(!bgCall.tools.some((t) => /whatsapp_send|whatsapp_draft|live_share|photo_hd/.test(t.name)));
  ok('una rutina NO puede enviar WhatsApp ni transmitir (solo herramientas de lectura)');
  await sleep(500);
  const st = JSON.parse(readFileSync(DIR_B + '/state.json', 'utf8'));
  assert.ok(st.routines.every((r) => r.lastRun === nowPR.date));
  ok('queda marcada como hecha hoy: no se repite aunque el servidor reinicie');

  console.log(`\n${pass} pruebas OK`);
} catch (e) {
  console.error('\nFALLÓ:', e.stack || e.message);
  process.exitCode = 1;
} finally {
  A.kill();
  B.kill();
  fake.close();
  setTimeout(() => process.exit(process.exitCode || 0), 100);
}

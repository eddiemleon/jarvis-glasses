// Voz propia desde la PC: registro, uso, aviso a la app y respaldo si la PC se apaga.
import { spawn } from 'node:child_process';
import http from 'node:http';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
const TOKEN = 'test-token-voice-0123456789';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let pass = 0; const ok = (n) => console.log('  ✓', n) || pass++;
let pcCalls = 0;
const wav = Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(100)]);
const pc = http.createServer((req, res) => {
  let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
    pcCalls++;
    assert.equal(req.headers.authorization, 'Bearer ' + TOKEN);
    res.writeHead(200, { 'content-type': 'audio/wav' }); res.end(wav);
  });
});
await new Promise((r) => pc.listen(18996, r));
rmSync('/tmp/jv', { recursive: true, force: true });
const srv = spawn('node', ['src/server.js'], { env: { ...process.env, PORT: '18086', JARVIS_TOKEN: TOKEN, DATA_DIR: '/tmp/jv', MOCK_LLM: '1', VOICE_ALLOW_HTTP: '1' }, stdio: ['ignore', 'pipe', 'pipe'] });
srv.stdout.on('data', () => {}); srv.stderr.on('data', (d) => process.stderr.write(d));
await sleep(900);
const H = { authorization: 'Bearer ' + TOKEN, 'content-type': 'application/json' };
try {
  console.log('Voz propia desde la PC');
  const ws = new WebSocket('ws://127.0.0.1:18086/ws'); const inbox = [];
  ws.onmessage = (e) => inbox.push(JSON.parse(e.data));
  await new Promise((r) => (ws.onopen = r)); ws.send(JSON.stringify({ type: 'hello', token: TOKEN }));
  await sleep(300);
  assert.equal(inbox.find((m) => m.type === 'ready').features.tts, false);
  let r = await fetch('http://127.0.0.1:18086/voice/register', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"url":"https://x.trycloudflare.com"}' });
  assert.equal(r.status, 401); ok('registrar la voz exige la contraseña de Jarvis');
  r = await fetch('http://127.0.0.1:18086/voice/register', { method: 'POST', headers: H, body: '{"url":"javascript:alert(1)"}' });
  assert.equal((await r.json()).source, 'iphone'); ok('rechaza direcciones inválidas');
  r = await fetch('http://127.0.0.1:18086/voice/register', { method: 'POST', headers: H, body: '{"url":"http://127.0.0.1:18996"}' });
  assert.equal((await r.json()).source, 'pc');
  await sleep(200);
  const upd = inbox.filter((m) => m.type === 'ready').at(-1);
  assert.equal(upd.features.tts, true); assert.equal(upd.features.voice, 'pc');
  ok('al conectarse la PC, la app recibe al instante que hay voz propia');
  r = await fetch('http://127.0.0.1:18086/tts', { method: 'POST', headers: H, body: '{"text":"Bienvenido de vuelta, señor Leon."}' });
  assert.equal(r.status, 200); assert.equal(r.headers.get('content-type'), 'audio/wav');
  assert.equal(Buffer.from(await r.arrayBuffer()).subarray(0, 4).toString(), 'RIFF');
  ok('la app pide una frase y recibe el audio WAV generado por la PC');
  pc.close(); pc.closeAllConnections?.(); await sleep(200);
  for (let i = 0; i < 3; i++) { r = await fetch('http://127.0.0.1:18086/tts', { method: 'POST', headers: H, body: '{"text":"hola"}' }); assert.notEqual(r.status, 200); }
  r = await fetch('http://127.0.0.1:18086/tts', { method: 'POST', headers: H, body: '{"text":"hola"}' });
  assert.equal(r.status, 501);
  ok('si la PC se apaga, deja de usarla y la app vuelve sola a la voz del iPhone');
  console.log(`\n${pass} pruebas OK`);
} catch (e) { console.error('\nFALLÓ:', e.stack || e.message); process.exitCode = 1; }
finally { srv.kill(); pc.close(); setTimeout(() => process.exit(process.exitCode || 0), 100); }

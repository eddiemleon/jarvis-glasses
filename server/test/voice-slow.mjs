// La PC ocupada (tarjeta usada por otro proyecto): Jarvis no espera, usa la voz del iPhone al instante
// y vuelve solo a la voz propia cuando la PC está libre.
import { spawn } from 'node:child_process';
import http from 'node:http';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
const TOKEN = 'test-token-voice-0123456789';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let pass = 0; const ok = (n) => console.log('  ✓', n) || pass++;
let delay = 2000;
const pc = http.createServer((req, res) => { req.resume(); req.on('end', () => setTimeout(() => {
  if (res.destroyed) return; res.writeHead(200, { 'content-type': 'audio/wav' }); res.end(Buffer.from('RIFF0000'));
}, delay)); });
await new Promise((r) => pc.listen(18997, r));
rmSync('/tmp/jvs', { recursive: true, force: true });
const srv = spawn('node', ['src/server.js'], { env: { ...process.env, PORT: '18087', JARVIS_TOKEN: TOKEN, DATA_DIR: '/tmp/jvs', MOCK_LLM: '1', VOICE_ALLOW_HTTP: '1',
  PC_VOICE_TIMEOUT_MS: '800', PC_VOICE_SLOW_MS: '500', PC_VOICE_BUSY_MS: '1500', PC_VOICE_PROBE_MS: '400' }, stdio: ['ignore', 'pipe', 'pipe'] });
srv.stdout.on('data', () => {}); srv.stderr.on('data', (d) => process.stderr.write(d));
await sleep(900);
const H = { authorization: 'Bearer ' + TOKEN, 'content-type': 'application/json' };
const tts = () => fetch('http://127.0.0.1:18087/tts', { method: 'POST', headers: H, body: '{"text":"hola"}' });
try {
  console.log('Voz propia con la PC ocupada');
  await fetch('http://127.0.0.1:18087/voice/register', { method: 'POST', headers: H, body: '{"url":"http://127.0.0.1:18997"}' });
  let t0 = Date.now(); let r = await tts();
  assert.notEqual(r.status, 200); assert.ok(Date.now() - t0 < 1500, 'esperó demasiado');
  ok('si la PC no responde rápido, se corta en menos de 1 s (antes esperaba 10 s)');
  t0 = Date.now(); r = await tts();
  assert.equal(r.status, 501); assert.ok(Date.now() - t0 < 200);
  ok('las siguientes frases van directo a la voz del iPhone, sin esperar nada');
  r = await fetch('http://127.0.0.1:18087/voice/register', { method: 'POST', headers: H, body: '{"url":"http://127.0.0.1:18997"}' });
  assert.equal((await tts()).status, 501);
  ok('el re-registro cada 5 min no vuelve a meter la voz lenta');
  delay = 50; await sleep(1500);
  r = await tts(); assert.equal(r.status, 200);
  ok('cuando la PC se libera, vuelve sola la voz propia');
  console.log(`\n${pass} pruebas OK`);
} catch (e) { console.error('\nFALLÓ:', e.stack || e.message); process.exitCode = 1; }
finally { srv.kill(); pc.close(); setTimeout(() => process.exit(process.exitCode || 0), 100); }

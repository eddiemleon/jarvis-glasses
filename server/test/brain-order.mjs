// El cerebro configurado como PRINCIPAL (BRAIN_ORDER) es el primero en usarse; Claude queda de reserva.
import { spawn } from 'node:child_process';
import http from 'node:http';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
rmSync('/tmp/jarvis-test-order', { recursive: true, force: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const TOKEN = 'test-token-0123456789abcdef';
let claudeHits = 0, mainHits = 0;
const claude = http.createServer((q, r) => { claudeHits++; q.resume(); r.writeHead(500); r.end('x'); });
const main = http.createServer((q, r) => {
  mainHits++; q.resume();
  r.writeHead(200, { 'content-type': 'text/event-stream' });
  r.write(`data: ${JSON.stringify({ choices: [{ delta: { content: 'Soy el principal.' }, finish_reason: 'stop' }] })}\n\ndata: [DONE]\n\n`);
  r.end();
});
await new Promise((r) => claude.listen(18993, r));
await new Promise((r) => main.listen(18994, r));
const srv = spawn('node', ['src/server.js'], { env: { ...process.env, PORT: '18084', JARVIS_TOKEN: TOKEN, DATA_DIR: '/tmp/jarvis-test-order', WEB_SEARCH: '0',
  ANTHROPIC_API_KEY: 'k', ANTHROPIC_BASE_URL: 'http://127.0.0.1:18993',
  BRAIN2_NAME: 'gemini', BRAIN2_BASE_URL: 'http://127.0.0.1:18994', BRAIN2_MODEL: 'm', BRAIN_ORDER: 'gemini,claude' }, stdio: ['ignore', 'pipe', 'inherit'] });
await sleep(800);
try {
  const h = await (await fetch('http://127.0.0.1:18084/health')).json();
  assert.deepEqual(h.brains, ['gemini:m', 'claude:claude-sonnet-5-5']); console.log('  ✓ orden de cerebros: ' + h.brains.join(' → '));
  const ws = new WebSocket('ws://127.0.0.1:18084/ws'); const got = [];
  ws.onmessage = (e) => got.push(JSON.parse(e.data));
  await new Promise((r) => (ws.onopen = r)); ws.send(JSON.stringify({ type: 'hello', token: TOKEN })); await sleep(200);
  ws.send(JSON.stringify({ type: 'utterance', id: 'o1', text: 'hola' })); await sleep(700);
  assert.equal(mainHits, 1); assert.equal(claudeHits, 0);
  assert.ok(got.some((m) => m.type === 'say' && m.text === 'Soy el principal.')); assert.ok(!got.some((m) => /principal se quedó|no responde/.test(m.text || '')));
  console.log('  ✓ el cerebro principal responde primero, Claude ni se toca, sin avisos de cambio\n1 prueba OK');
} catch (e) { console.error('FALLÓ:', e.message); process.exitCode = 1; }
finally { srv.kill(); claude.close(); main.close(); setTimeout(() => process.exit(process.exitCode || 0), 100); }

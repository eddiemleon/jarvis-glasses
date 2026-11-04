// Solo una URL de Ollama (sin Anthropic): se vuelve el cerebro principal y elige solo el mejor modelo.
import { spawn } from 'node:child_process';
import http from 'node:http';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
rmSync('/tmp/jarvis-test-auto', { recursive: true, force: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let usedModel = '';
const ol = http.createServer((q, r) => {
  if (q.url === '/v1/models') { r.writeHead(200, { 'content-type': 'application/json' }); return r.end(JSON.stringify({ data: [{ id: 'llama3.2:1b' }, { id: 'llama3.3:70b' }, { id: 'nomic-embed-text' }] })); }
  let b = ''; q.on('data', (d) => (b += d)); q.on('end', () => {
    try { usedModel = JSON.parse(b).model; } catch {}
    r.writeHead(200, { 'content-type': 'text/event-stream' });
    r.write(`data: ${JSON.stringify({ choices: [{ delta: { content: 'Listo, señor.' }, finish_reason: 'stop' }] })}\n\ndata: [DONE]\n\n`); r.end();
  });
});
await new Promise((r) => ol.listen(18995, r));
const env = { ...process.env, PORT: '18085', JARVIS_TOKEN: 'test-token-0123456789abcdef', DATA_DIR: '/tmp/jarvis-test-auto', WEB_SEARCH: '0', OLLAMA_URL: 'http://127.0.0.1:18995' };
delete env.ANTHROPIC_API_KEY;
const srv = spawn('node', ['src/server.js'], { env, stdio: ['ignore', 'pipe', 'inherit'] });
await sleep(1000);
try {
  const h = await (await fetch('http://127.0.0.1:18085/health')).json();
  assert.deepEqual(h.brains, ['ollama:llama3.3:70b']); console.log('  ✓ solo con la URL: principal = ' + h.brains[0]);
  const ws = new WebSocket('ws://127.0.0.1:18085/ws'); const got = [];
  ws.onmessage = (e) => got.push(JSON.parse(e.data));
  await new Promise((r) => (ws.onopen = r)); ws.send(JSON.stringify({ type: 'hello', token: 'test-token-0123456789abcdef' })); await sleep(200);
  ws.send(JSON.stringify({ type: 'utterance', id: 'a1', text: 'hola' })); await sleep(700);
  assert.equal(usedModel, 'llama3.3:70b');
  assert.ok(got.some((m) => m.type === 'say' && /Listo/.test(m.text)));
  console.log('  ✓ responde con el modelo elegido automáticamente\n1 prueba OK');
} catch (e) { console.error('FALLÓ:', e.message); process.exitCode = 1; }
finally { srv.kill(); ol.close(); setTimeout(() => process.exit(process.exitCode || 0), 100); }

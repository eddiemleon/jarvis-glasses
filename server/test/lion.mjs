// Puente con Lion Capital contra una sala simulada: estado de la cuenta y encargos al Director.
import http from 'node:http';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
rmSync('/tmp/jlion', { recursive: true, force: true });
process.env.DATA_DIR = '/tmp/jlion';
process.env.JARVIS_TOKEN = 'test-token-lion-0123456789';
process.env.LION_URL = 'http://127.0.0.1:18998';
process.env.LION_KEY = 'clave-secreta-123';
let pass = 0; const ok = (n) => console.log('  ✓', n) || pass++;
const sala = http.createServer((req, res) => {
  if (!(req.headers.cookie || '').includes('lck=clave-secreta-123')) { res.writeHead(401); return res.end(); }
  if (req.url === '/api/estado') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ vivo: { ok: true, bid: 2650.1, ask: 2650.4, conectado: true, algo: true, ea: true,
      cuenta: { balance: 10512.3, equity: 10530.1, total_pct: 5.3, hoy_pct: 0.4, dias_ganadores: 2, dias_min: 3, objetivo_pct: 8, freno_diario_pct: 4, freno_total_pct: 9.8, riesgo_abierto_pct: 0.6 },
      posiciones: [{ estrategia: 'Keltner SQX H1', lado: 1, lotes: 0.2, flotante: 17.8, riesgo_usd: 60 }] } }));
  }
  if (req.url === '/api/conversar' && req.method === 'POST') {
    let b = ''; req.on('data', (d) => (b += d)); req.on('end', () => {
      const body = JSON.parse(b);
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write('data: ' + JSON.stringify({ tipo: 'inicio', motor: 'local' }) + '\n\n');
      res.write('data: ' + JSON.stringify({ tipo: 'texto', t: 'La fábrica va' }) + '\n\n');
      setTimeout(() => res.end('data: ' + JSON.stringify({ tipo: 'fin', texto: `**La fábrica** probó 40 estrategias hoy. (${body.agente})`, nombre: 'Director' }) + '\n\n'), 50);
    });
    return;
  }
  res.writeHead(404); res.end();
});
await new Promise((r) => sala.listen(18998, r));
const { hub } = await import('../src/hub.js');
const { lionEstado, lionEncargar, lionEnabled } = await import('../src/lion.js');
const avisos = [];
hub.deliver = (m) => { avisos.push(m); return true; };
try {
  console.log('Lion Capital');
  assert.ok(lionEnabled()); ok('configurado por variables de entorno');
  const e = await lionEstado();
  assert.equal(e.balance, 10512.3); assert.equal(e.ganancia_total_pct, 5.3); assert.equal(e.posiciones[0].lado, 'compra'); assert.equal(e.ea_cargado, true);
  ok('estado en vivo: balance, avance al objetivo, posiciones y EA');
  assert.equal(lionEncargar('Director', '¿Cómo va la fábrica?'), 'director'); ok('el encargo responde al instante (no bloquea la conversación)');
  for (let i = 0; i < 40 && !avisos.length; i++) await new Promise((r) => setTimeout(r, 50));
  assert.match(avisos[0].text, /Director de Lion Capital responde: La fábrica probó 40 estrategias hoy\. \(director\)/);
  assert.doesNotMatch(avisos[0].text, /\*/); ok('la respuesta del Director llega sola como aviso de voz, sin markdown');
  process.env.LION_KEY = 'mala-clave-0000000';
  await assert.rejects(lionEstado()); ok('con clave equivocada no hay acceso');
  console.log(`\n${pass} pruebas OK`);
} catch (e) { console.error('\nFALLÓ:', e.stack || e.message); process.exitCode = 1; }
finally { sala.close(); setTimeout(() => process.exit(process.exitCode || 0), 100); }

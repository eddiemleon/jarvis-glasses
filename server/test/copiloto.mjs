import assert from 'node:assert/strict';
process.env.JARVIS_VIGIA = '0';
const { copiloto, esSalida } = await import('../src/copiloto.js');
const { hub } = await import('../src/hub.js');
const recibidos = [];
hub.add({ send: (t) => { recibidos.push(JSON.parse(t)); return true; } });
// la PC espera; llega un mensaje con foto → la PC lo recibe al instante
const p = copiloto.siguiente(2000);
const id = copiloto.enviar('¿Qué cable va en el positivo?', 'AAAA');
const m = await p;
assert.equal(m.id, id); assert.equal(m.imagen, 'AAAA');
assert.ok(copiloto.pcConectada);
// sin mensajes: la espera termina vacía
assert.equal(await copiloto.siguiente(50), null);
// la respuesta de Claude se le lee a Leon (sin markdown)
copiloto.responder(id, '**El rojo** va al positivo.');
assert.equal(recibidos.at(-1).source, 'copiloto');
assert.equal(recibidos.at(-1).text, 'El rojo va al positivo.');
// salir del modo
for (const s of ['salir del copiloto', 'Jarvis, termina el copiloto', 'apaga el copiloto', 'pásame a Jarvis', 'regrésame a Jarvis']) assert.ok(esSalida(s), s);
for (const s of ['¿qué ves aquí?', 'pregúntale al copiloto qué opina']) assert.ok(!esSalida(s), s);
console.log('copiloto: 9 comprobaciones OK');

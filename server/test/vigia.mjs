import assert from 'node:assert/strict';
process.env.JARVIS_VIGIA = '0';
const { detectar, silencio } = await import('../src/vigia.js');
const base = { conectado: true, ea_cargado: true, trading_algoritmico: true, hoy_pct: 0, freno_diario_pct: 4, objetivo_pct: 8, ganancia_total_pct: 5, posiciones: [] };
const t = (prev, cur) => detectar(prev, cur).map((a) => a.t);
// nada cambia: silencio
assert.deepEqual(t(base, { ...base }), []);
// abre y cierra posiciones
const abierta = { ...base, posiciones: [{ estrategia: 'M-00224', lado: 'compra', lotes: 0.5, flotante_usd: 41 }] };
assert.match(t(base, abierta)[0], /M-00224 abrió una compra de 0.5 lotes/);
assert.match(t(abierta, base)[0], /se cerró la compra de M-00224, ganando unos 41 dólares/);
// freno diario: avisa al 50 % y al 80 % (urgente), una sola vez
assert.match(t(base, { ...base, hoy_pct: -2.1 })[0], /50 % del freno diario/);
const a80 = detectar({ ...base, hoy_pct: -2.1 }, { ...base, hoy_pct: -3.3 });
assert.equal(a80.length, 1); assert.ok(a80[0].urgente);
assert.deepEqual(t({ ...base, hoy_pct: -3.3 }, { ...base, hoy_pct: -3.4 }), []);
// EA y conexión
assert.ok(detectar(base, { ...base, ea_cargado: false })[0].urgente);
assert.match(t(base, { conectado: false, motivo: 'MT5 cerrado' })[0], /perdió la conexión/);
// objetivo
assert.match(t(base, { ...base, ganancia_total_pct: 8.1 })[0], /alcanzó el objetivo/);
// horas de silencio
assert.ok(silencio('23:30') && silencio('06:59') && !silencio('07:00') && !silencio('15:00'));
console.log('vigia: 11 comprobaciones OK');

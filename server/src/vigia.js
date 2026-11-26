// Jarvis proactivo: vigila Lion Capital en segundo plano y le habla SOLO cuando algo importa.
// Solo lectura (opción A): mira el estado de la cuenta, nunca ordena nada.
import crypto from 'node:crypto';
import { config, log } from './config.js';
import { hub } from './hub.js';
import { lionEnabled, lionEstado } from './lion.js';
import { localNow } from './routines.js';

const usd = (n) => `${Math.round(Math.abs(Number(n) || 0))} dólares`;
const pct = (n) => `${(Math.round((Number(n) || 0) * 100) / 100).toString().replace('.', ',')} %`;
const clave = (p) => `${p.estrategia}|${p.lado}`;

/** Compara dos estados y devuelve los avisos (texto, urgente). Pura: se prueba sin red. */
export function detectar(prev, cur) {
  const out = [];
  if (!prev || !cur) return out;
  // Conexión de la cuenta / EA
  if (prev.conectado && !cur.conectado) out.push({ t: `Señor, Lion Capital perdió la conexión con MT5: ${cur.motivo || 'sin datos'}.`, urgente: true });
  if (!prev.conectado && cur.conectado) out.push({ t: 'Señor, Lion Capital volvió a conectarse con MT5.', urgente: false });
  if (!cur.conectado || !prev.conectado) return out;
  if (prev.ea_cargado && !cur.ea_cargado) out.push({ t: 'Atención, señor: el EA de Lion Capital ya no está cargado en MT5.', urgente: true });
  if (prev.trading_algoritmico && !cur.trading_algoritmico) out.push({ t: 'Atención, señor: el trading algorítmico de MT5 se desactivó.', urgente: true });
  // Posiciones abiertas / cerradas
  const antes = new Map((prev.posiciones || []).map((p) => [clave(p), p]));
  const ahora = new Map((cur.posiciones || []).map((p) => [clave(p), p]));
  for (const [k, p] of ahora) if (!antes.has(k)) out.push({ t: `Señor, ${p.estrategia || 'el EA'} abrió una ${p.lado} de ${p.lotes} lotes en oro.`, urgente: false });
  for (const [k, p] of antes) if (!ahora.has(k)) {
    const f = Number(p.flotante_usd) || 0;
    out.push({ t: `Señor, se cerró la ${p.lado} de ${p.estrategia || 'el EA'}, ${f >= 0 ? 'ganando' : 'perdiendo'} unos ${usd(f)}.`, urgente: false });
  }
  // Pérdida del día acercándose al freno diario (avisa una vez al cruzar 50 % y 80 % del freno)
  const freno = Math.abs(Number(cur.freno_diario_pct) || 0);
  if (freno > 0) {
    for (const nivel of [0.5, 0.8]) {
      const lim = -freno * nivel;
      if (Number(prev.hoy_pct) > lim && Number(cur.hoy_pct) <= lim)
        out.push({ t: `Cuidado, señor: el día va en ${pct(cur.hoy_pct)}, ya es el ${nivel * 100} % del freno diario de ${pct(freno)}.`, urgente: nivel >= 0.8 });
    }
  }
  // Objetivo alcanzado
  const obj = Number(cur.objetivo_pct);
  if (obj > 0 && Number(prev.ganancia_total_pct) < obj && Number(cur.ganancia_total_pct) >= obj)
    out.push({ t: `¡Excelente, señor! Lion Capital alcanzó el objetivo: ${pct(cur.ganancia_total_pct)}.`, urgente: true });
  return out;
}

/** Horas de silencio (23:00–07:00 en su zona): solo pasan los avisos urgentes. */
export function silencio(hm) {
  const h = Number(String(hm).slice(0, 2));
  return h >= 23 || h < 7;
}

let previo = null;
let fallos = 0;

export async function tick() {
  if (!lionEnabled()) return;
  let cur;
  try {
    cur = await lionEstado();
    fallos = 0;
  } catch (e) {
    // Si la sala deja de responder 5 minutos seguidos, avisa una vez.
    if (++fallos === 5) hub.deliver({ type: 'alert', id: crypto.randomUUID(), source: 'lion', text: 'Señor, la sala de Lion Capital no responde desde hace cinco minutos. ¿La PC está encendida?', priority: 'normal', ts: Date.now() });
    return;
  }
  const avisos = detectar(previo, cur);
  previo = cur;
  const quiet = silencio(localNow().hm);
  for (const a of avisos) {
    if (quiet && !a.urgente) continue;
    log('vigía:', a.t);
    hub.deliver({ type: 'alert', id: crypto.randomUUID(), source: 'lion', text: a.t, priority: a.urgente ? 'high' : 'normal', ts: Date.now() });
  }
}

export function startVigia() {
  if (process.env.JARVIS_VIGIA === '0') return;
  setInterval(() => tick().catch(() => {}), 60_000).unref();
}

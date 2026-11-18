// Puente Jarvis ↔ Lion Capital: lee la sala de trading que corre en la PC de Leon (MT5 en vivo) y le
// pasa encargos al Director o a cualquier agente. La sala se publica con Tailscale Funnel (URL fija).
import crypto from 'node:crypto';
import { config, log } from './config.js';
import { hub } from './hub.js';
import { store } from './store.js';

function conf() {
  const s = store.lion?.() || {};
  return { url: (process.env.LION_URL || s.url || '').replace(/\/+$/, ''), key: process.env.LION_KEY || s.key || '' };
}
export const lionEnabled = () => {
  const c = conf();
  return !!(c.url && c.key);
};

async function pedir(path, { method = 'GET', body, timeout = 12_000 } = {}) {
  const c = conf();
  if (!c.url || !c.key) throw new Error('Lion Capital no está conectado a Jarvis todavía');
  return fetch(c.url + path, {
    method,
    headers: { Cookie: 'lck=' + c.key, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(timeout),
    redirect: 'manual',
  });
}

/** Estado en vivo de la cuenta (MT5): balance, avance al objetivo, posiciones abiertas, EA. */
export async function lionEstado() {
  const r = await pedir('/api/estado');
  if (!r.ok) throw new Error(`la sala respondió ${r.status}`);
  const v = (await r.json()).vivo || {};
  if (!v.ok) return { conectado: false, motivo: v.motivo || 'MT5 sin datos' };
  const c = v.cuenta || {};
  return {
    conectado: true,
    balance: c.balance, equity: c.equity, ganancia_total_pct: c.total_pct, hoy_pct: c.hoy_pct,
    objetivo_pct: c.objetivo_pct, dias_ganadores: c.dias_ganadores, dias_minimos: c.dias_min,
    freno_diario_pct: c.freno_diario_pct, freno_total_pct: c.freno_total_pct, riesgo_abierto_pct: c.riesgo_abierto_pct,
    oro: { bid: v.bid, ask: v.ask },
    mt5_conectado: v.conectado, trading_algoritmico: v.algo, ea_cargado: v.ea,
    posiciones: (v.posiciones || []).map((p) => ({ estrategia: p.estrategia, lado: p.lado > 0 ? 'compra' : 'venta', lotes: p.lotes, flotante_usd: p.flotante, riesgo_usd: p.riesgo_usd })),
  };
}

/** Conversación con un agente de la sala (SSE). Devuelve el texto final. */
async function conversar(agente, texto, timeout) {
  const r = await pedir('/api/conversar', { method: 'POST', body: { agente, texto }, timeout });
  if (!r.ok) throw new Error(`la sala respondió ${r.status}`);
  const reader = r.body.getReader();
  const dec = new TextDecoder();
  let buf = '', ultimo = '', fin = null, error = null;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const raw = buf.slice(0, i).replace(/^data:\s?/gm, '');
      buf = buf.slice(i + 2);
      try {
        const ev = JSON.parse(raw);
        if (ev.tipo === 'texto') ultimo = ev.t || ultimo;
        else if (ev.tipo === 'fin') fin = ev;
        else if (ev.tipo === 'error') error = ev.msg || ev.code;
      } catch {}
    }
  }
  if (error) throw new Error(error);
  return { texto: (fin?.texto || ultimo || '').trim(), nombre: fin?.nombre || agente, motor: fin?.motor };
}

/** Encargo o pregunta a un agente. Los agentes pueden tardar (IA local o Claude con acceso a los archivos):
 *  se responde enseguida y la respuesta le llega a Leon por voz cuando el agente termina. */
export function lionEncargar(agente, texto) {
  const id = crypto.randomUUID();
  const aid = String(agente || 'director').toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 30) || 'director';
  conversar(aid, `[Mensaje de Leon a través de Jarvis, su asistente por voz] ${texto}`, 300_000)
    .then((r) => {
      const t = r.texto.replace(/[*_#`>|]/g, '').replace(/\s+/g, ' ').slice(0, 900);
      hub.deliver({ type: 'alert', id, source: 'lion', text: `${r.nombre} de Lion Capital responde: ${t || 'recibido.'}`, priority: 'normal', ts: Date.now() });
    })
    .catch((e) => {
      log('lion: encargo falló', e.message);
      hub.deliver({ type: 'alert', id, source: 'lion', text: `No pude completar el encargo a ${aid} de Lion Capital: ${e.message}.`, priority: 'normal', ts: Date.now() });
    });
  return aid;
}

export async function lionAgentes() {
  const r = await pedir('/api/db/doc?p=' + encodeURIComponent('sala/config'));
  if (!r.ok) throw new Error(`la sala respondió ${r.status}`);
  const d = (await r.json()).data || {};
  return (d.agents || []).map((a) => ({ id: a.id, nombre: a.name, rol: a.role })).slice(0, 80);
}

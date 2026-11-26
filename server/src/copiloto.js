// Copiloto: un chat ÚNICO y permanente de Claude que vive en la PC de Leon (Claude Code, su suscripción).
// Leon habla por las gafas → Jarvis transcribe (y adjunta lo que ven las gafas) → la PC lo recoge, Claude responde
// en ese mismo chat → Jarvis le lee la respuesta. La PC se conecta HACIA el servidor (sin abrir puertos en casa).
import crypto from 'node:crypto';
import { hub } from './hub.js';
import { log } from './config.js';

const cola = [];
const esperando = new Set(); // peticiones de la PC esperando trabajo (long-poll)
let activo = false;
let ultimaVisitaPC = 0;

export const copiloto = {
  get activo() { return activo; },
  set activo(v) { activo = !!v; },
  /** La PC preguntó por trabajo hace menos de 1 minuto. */
  get pcConectada() { return Date.now() - ultimaVisitaPC < 60_000; },

  enviar(texto, imagen) {
    const m = { id: crypto.randomUUID(), texto: String(texto || '').slice(0, 4000), imagen: imagen || null, ts: Date.now() };
    cola.push(m);
    while (cola.length > 20) cola.shift();
    for (const w of esperando) { esperando.delete(w); w(); }
    return m.id;
  },

  /** Long-poll de la PC: devuelve el siguiente mensaje o null tras `ms`. */
  siguiente(ms = 25_000) {
    ultimaVisitaPC = Date.now();
    if (cola.length) return Promise.resolve(cola.shift());
    return new Promise((res) => {
      const w = () => { clearTimeout(t); res(cola.shift() || null); };
      const t = setTimeout(() => { esperando.delete(w); res(null); }, ms);
      esperando.add(w);
    });
  },

  responder(id, texto) {
    ultimaVisitaPC = Date.now();
    const t = String(texto || '').replace(/[*_#`>|]/g, '').replace(/\s+/g, ' ').trim().slice(0, 2500);
    log('copiloto responde', id, t.length, 'car.');
    return hub.deliver({ type: 'alert', id: id || crypto.randomUUID(), source: 'copiloto', text: t || 'El copiloto no respondió nada.', priority: 'high', ts: Date.now() });
  },
};

/** ¿La frase es para salir del modo copiloto? */
export function esSalida(text) {
  const t = String(text || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  if (/\b(pasame|regresa(me)?|vuelve|volver)\b.*\bjarvis\b/.test(t)) return true;
  return /\b(sal(ir|te)?|termina(r)?|cierra|apaga|deja|desactiva|fin)\b.*\bcopiloto\b|\bcopiloto\b.*\b(apagado|fuera|off|termina)\b/.test(t);
}

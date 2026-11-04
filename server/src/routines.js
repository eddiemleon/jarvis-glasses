// Rutinas: tareas que Jarvis ejecuta solo a una hora fija (briefing matutino, precio del oro, etc.)
// y cuyo resultado le dice al oído.
import crypto from 'node:crypto';
import { config, log } from './config.js';
import { store } from './store.js';

const DAY_NAMES = ['dom', 'lun', 'mar', 'mie', 'jue', 'vie', 'sab'];
const EN = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

export const BRIEFING_PROMPT =
  'Briefing: saluda según la hora, dime la fecha, mis eventos de hoy en el calendario, recordatorios pendientes, ' +
  'alertas de TradingView y mensajes de WhatsApp recientes, el precio actual del oro (XAUUSD) y el clima de hoy donde estoy. ' +
  'Máximo seis frases; omite lo que esté vacío.';

// Hora local del usuario (zona JARVIS_TZ): {date: 'YYYY-MM-DD', hm: 'HH:MM', dow: 0..6}
export function localNow(d = new Date(), tz = config.tz) {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short', hourCycle: 'h23' })
      .formatToParts(d)
      .map((x) => [x.type, x.value])
  );
  return { date: `${p.year}-${p.month}-${p.day}`, hm: `${p.hour}:${p.minute}`, dow: EN[p.weekday] };
}

// Convierte una fecha ISO a milisegundos. Si no trae zona ("2026-11-04T15:00"), se interpreta en la zona del usuario.
export function parseWhen(s, tz = config.tz) {
  const str = String(s || '').trim();
  if (!str) return NaN;
  if (/(z|[+-]\d\d:?\d\d)$/i.test(str)) return Date.parse(str);
  const m = str.match(/^(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d))?)?/);
  if (!m) return NaN;
  const wall = Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
  const offsetAt = (ms) => {
    const p = Object.fromEntries(
      new Intl.DateTimeFormat('en-US', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' })
        .formatToParts(new Date(ms))
        .map((x) => [x.type, x.value])
    );
    return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - ms;
  };
  let guess = wall - offsetAt(wall);
  guess = wall - offsetAt(guess); // segunda pasada: correcto también cerca de cambios de horario
  return guess;
}

export function parseTime(t) {
  const m = String(t || '').trim().match(/^(\d{1,2})(?::(\d{2}))?$/);
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2] || 0);
  if (h > 23 || min > 59) return null;
  return `${String(h).padStart(2, '0')}:${String(min).padStart(2, '0')}`;
}

export function parseDays(days) {
  const list = Array.isArray(days) ? days : days ? [days] : ['diario'];
  const out = new Set();
  for (const raw of list) {
    const d = String(raw)
      .normalize('NFD')
      .replace(/\p{M}/gu, '')
      .toLowerCase()
      .trim();
    if (/diario|todos|cada dia|everyday|daily/.test(d)) [0, 1, 2, 3, 4, 5, 6].forEach((x) => out.add(x));
    else if (/laborable|semana|weekday|lunes a viernes/.test(d)) [1, 2, 3, 4, 5].forEach((x) => out.add(x));
    else if (/fin/.test(d)) [0, 6].forEach((x) => out.add(x));
    else {
      const i = DAY_NAMES.findIndex((n) => d.startsWith(n));
      if (i >= 0) out.add(i);
    }
  }
  return out.size ? [...out].sort() : null;
}

export function describeDays(days) {
  if (days.length === 7) return 'todos los días';
  if (days.join() === '1,2,3,4,5') return 'de lunes a viernes';
  if (days.join() === '0,6') return 'los fines de semana';
  return days.map((d) => ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'][d]).join(', ');
}

export function addRoutine({ prompt, time, days, label }) {
  const hm = parseTime(time);
  if (!hm) throw new Error('Hora inválida: usa formato HH:MM de 24 horas, por ejemplo 07:30');
  const ds = parseDays(days);
  if (!ds) throw new Error('Días inválidos: usa "diario", "laborables", "fines" o nombres como lun, mar, mie');
  const r = { id: crypto.randomBytes(3).toString('hex'), prompt: String(prompt).slice(0, 800), time: hm, days: ds, label: String(label || prompt).slice(0, 80), lastRun: localNow().date };
  // lastRun = hoy: una rutina creada a las 07:30 para las 07:30 no se dispara dos veces; sí sale si la hora aún no llega.
  if (hm > localNow().hm) r.lastRun = '';
  store.addRoutine(r);
  return r;
}

export function removeRoutines(key) {
  const k = String(key).toLowerCase();
  const hit = store.routines().filter((r) => r.id === k || r.label.toLowerCase().includes(k) || r.prompt.toLowerCase().includes(k) || k === 'todas');
  return store.removeRoutines(hit.map((r) => r.id));
}

// Revisa cada 15 s. runner(routine) ejecuta la tarea (inyectado para poder probarlo).
export function startRoutineLoop(runner) {
  const tick = () => {
    const now = localNow();
    for (const r of store.routines()) {
      if (r.time === now.hm && r.days.includes(now.dow) && r.lastRun !== now.date) {
        store.updateRoutine(r.id, { lastRun: now.date });
        log('rutina:', r.label);
        Promise.resolve(runner(r)).catch((e) => log('rutina error', e.message));
      }
    }
  };
  setInterval(tick, 15_000).unref();
  return tick;
}

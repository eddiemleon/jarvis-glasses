import fs from 'node:fs';
import path from 'node:path';
import { config, log } from './config.js';

const file = path.join(config.dataDir, 'state.json');
let state = { facts: [], alerts: [], wa: [], reminders: [], visual: [], routines: [], activity: { last: 0, days: {} } };
try {
  state = { ...state, ...JSON.parse(fs.readFileSync(file, 'utf8')) };
} catch {
  /* primer arranque */
}

let timer = null;
let onChange = null;
function save() {
  onChange?.();
  clearTimeout(timer);
  timer = setTimeout(() => {
    try {
      fs.mkdirSync(config.dataDir, { recursive: true });
      const tmp = file + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(state));
      fs.renameSync(tmp, file);
    } catch (e) {
      log('store: no pude guardar', e.message);
    }
  }, 300);
}

const cap = (arr, n) => {
  while (arr.length > n) arr.shift();
};

// Copia de la memoria que se guarda en el iPhone (el plan gratis de Render borra el disco al dormirse).
// No incluye fotos (pesan mucho); sí datos, recordatorios, rutinas, notas visuales y horarios.
const SYNC_KEYS = ['facts', 'reminders', 'routines', 'visual', 'activity', 'alerts', 'wa', 'lion'];
export function snapshot() {
  const out = {};
  for (const k of SYNC_KEYS) out[k] = state[k];
  out.savedAt = Date.now();
  return out;
}
const isEmpty = () => !state.facts.length && !state.reminders.length && !state.routines.length && !(state.activity?.last > 0);
// Restaura la copia del iPhone solo si este servidor arrancó vacío o la copia es más nueva.
export function restore(snap) {
  if (!snap || typeof snap !== 'object') return false;
  if (!isEmpty() && !(snap.savedAt > (state.savedAt || 0))) return false;
  for (const k of SYNC_KEYS) if (snap[k] !== undefined) state[k] = snap[k];
  state.savedAt = snap.savedAt || Date.now();
  save();
  return true;
}
export function setOnChange(fn) {
  onChange = fn;
}

export const store = {
  lion: () => state.lion || {},
  setLion(v) {
    state.lion = { url: String(v.url || '').trim(), key: String(v.key || '').trim(), at: Date.now() };
    save();
  },
  facts: () => state.facts,
  addFact(text) {
    const t = String(text).trim().slice(0, 300);
    if (!t || state.facts.includes(t)) return false;
    state.facts.push(t);
    cap(state.facts, 300);
    save();
    return true;
  },
  removeFacts(substr) {
    const s = String(substr).toLowerCase();
    const before = state.facts.length;
    state.facts = state.facts.filter((f) => !f.toLowerCase().includes(s));
    save();
    return before - state.facts.length;
  },
  addAlert(a) {
    state.alerts.push(a);
    cap(state.alerts, 200);
    save();
  },
  alerts: (n = 5) => state.alerts.slice(-n),
  addWa(m) {
    state.wa.push(m);
    cap(state.wa, 300);
    save();
  },
  wa: (n = 5) => state.wa.slice(-n),
  reminders: () => state.reminders,
  addReminder(r) {
    state.reminders.push(r);
    save();
  },
  removeReminder(id) {
    const before = state.reminders.length;
    state.reminders = state.reminders.filter((r) => r.id !== id);
    save();
    return before - state.reminders.length;
  },

  // ---- memoria visual: dato en state.json + foto en DATA_DIR/visual/<id>.jpg ----
  visual: () => state.visual,
  addVisual(note, jpegBase64) {
    fs.mkdirSync(visualDir, { recursive: true });
    fs.writeFileSync(path.join(visualDir, note.id + '.jpg'), Buffer.from(jpegBase64, 'base64'));
    state.visual.push(note);
    while (state.visual.length > 200) dropVisualFile(state.visual.shift().id);
    save();
  },
  visualImage(id) {
    try {
      return fs.readFileSync(path.join(visualDir, id + '.jpg')).toString('base64');
    } catch {
      return null;
    }
  },
  removeVisual(ids) {
    const set = new Set(ids);
    state.visual = state.visual.filter((n) => !set.has(n.id));
    ids.forEach(dropVisualFile);
    save();
    return ids.length;
  },

  // ---- actividad: cuándo conversa el usuario (para el saludo de regreso) ----
  activity: () => state.activity || (state.activity = { last: 0, days: {} }),
  markTurn(now, day, hm) {
    const a = store.activity();
    a.last = now;
    const d = (a.days[day] ||= { first: hm, last: hm, turns: 0 });
    d.last = hm;
    d.turns++;
    const keys = Object.keys(a.days).sort();
    while (keys.length > 14) delete a.days[keys.shift()];
    save();
  },

  // ---- rutinas programadas ----
  routines: () => state.routines,
  addRoutine(r) {
    state.routines.push(r);
    cap(state.routines, 30);
    save();
  },
  updateRoutine(id, patch) {
    const r = state.routines.find((x) => x.id === id);
    if (r) Object.assign(r, patch);
    save();
  },
  removeRoutines(ids) {
    const set = new Set(ids);
    state.routines = state.routines.filter((r) => !set.has(r.id));
    save();
    return ids.length;
  },
};

const visualDir = path.join(config.dataDir, 'visual');
function dropVisualFile(id) {
  try {
    fs.unlinkSync(path.join(visualDir, id + '.jpg'));
  } catch {}
}

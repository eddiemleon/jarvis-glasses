import crypto from 'node:crypto';
import { store } from './store.js';
import { hub } from './hub.js';
import { log } from './config.js';
import { parseWhen } from './routines.js';

export function addReminder({ inMinutes, atIso, text }) {
  let at;
  if (typeof inMinutes === 'number' && inMinutes >= 0) at = Date.now() + inMinutes * 60_000;
  else if (atIso) at = parseWhen(atIso);
  if (!at || Number.isNaN(at)) throw new Error('Hora inválida: usa in_minutes o at_iso con zona horaria');
  if (at < Date.now() - 5000) throw new Error('Esa hora ya pasó');
  const r = { id: crypto.randomBytes(3).toString('hex'), at, text: String(text).slice(0, 300) };
  store.addReminder(r);
  return r;
}

export const listReminders = () => store.reminders().slice().sort((a, b) => a.at - b.at);

export function cancelReminder(key) {
  const k = String(key).toLowerCase();
  const hit = store.reminders().filter((r) => r.id === k || r.text.toLowerCase().includes(k));
  hit.forEach((r) => store.removeReminder(r.id));
  return hit.length;
}

// Revisa cada segundo (evita el límite de setTimeout y sobrevive a reinicios porque los recordatorios se guardan).
export function startReminderLoop() {
  setInterval(() => {
    const now = Date.now();
    for (const r of store.reminders().filter((x) => x.at <= now)) {
      store.removeReminder(r.id);
      hub.deliver({ type: 'alert', id: r.id, source: 'reminder', text: r.text, priority: 'high', ts: now });
      log('recordatorio:', r.text);
    }
  }, 1000).unref();
}

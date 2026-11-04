import crypto from 'node:crypto';
import { config } from './config.js';

export const waEnabled = () => !!(config.wa.token && config.wa.phoneId);

export function verifySignature(raw, header) {
  if (!config.wa.appSecret) return true; // sin secreto configurado no se valida (no recomendado)
  if (!header || !header.startsWith('sha256=')) return false;
  const expected = crypto.createHmac('sha256', config.wa.appSecret).update(raw).digest('hex');
  const got = header.slice(7);
  return got.length === expected.length && crypto.timingSafeEqual(Buffer.from(got), Buffer.from(expected));
}

// Extrae mensajes entrantes del payload de WhatsApp Cloud API.
export function parseIncoming(body) {
  const out = [];
  for (const entry of body?.entry || []) {
    for (const ch of entry.changes || []) {
      const v = ch.value || {};
      const names = Object.fromEntries((v.contacts || []).map((c) => [c.wa_id, c.profile?.name]));
      for (const m of v.messages || []) {
        let text = '';
        if (m.type === 'text') text = m.text?.body || '';
        else if (m.type === 'audio') text = '[nota de voz]';
        else if (m.type === 'image') text = '[imagen]' + (m.image?.caption ? ' ' + m.image.caption : '');
        else if (m.type === 'video') text = '[video]';
        else if (m.type === 'document') text = '[documento]';
        else if (m.type === 'location') text = '[ubicación]';
        else text = `[${m.type}]`;
        out.push({ id: m.id, from: m.from, name: names[m.from] || m.from, text, ts: Date.now() });
      }
    }
  }
  return out;
}

export async function sendText(to, text) {
  const digits = String(to).replace(/\D/g, '');
  if (!digits) throw new Error('Número inválido');
  const res = await fetch(`https://graph.facebook.com/${config.wa.apiVersion}/${config.wa.phoneId}/messages`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${config.wa.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ messaging_product: 'whatsapp', to: digits, type: 'text', text: { body: text } }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`WhatsApp ${res.status}: ${body.slice(0, 300)}`);
  return body;
}

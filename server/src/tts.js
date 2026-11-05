import { config, log } from './config.js';

// Voz propia de Jarvis: la genera la PC del usuario (XTTS-v2) y se conecta aquí por un túnel seguro.
// Si la PC está apagada, se usa ElevenLabs (si está configurado) o la voz del iPhone.
const pc = { url: '', at: 0, fails: 0, busyUntil: 0, probing: false };
const PC_FRESH_MS = 12 * 60_000; // la PC se re-registra cada 5 min
// Prioridad a la rapidez: si la voz de la PC tarda (su tarjeta está ocupada con otro proyecto), Jarvis
// responde AL INSTANTE con la voz del iPhone y vuelve a la voz propia sola cuando la PC esté libre.
const PC_TIMEOUT_MS = Number(process.env.PC_VOICE_TIMEOUT_MS || 4000);
const PC_SLOW_MS = Number(process.env.PC_VOICE_SLOW_MS || 3500);
const BUSY_MS = Number(process.env.PC_VOICE_BUSY_MS || 120_000);
const PROBE_MS = Number(process.env.PC_VOICE_PROBE_MS || 60_000);

export function registerPcVoice(url) {
  const re = process.env.VOICE_ALLOW_HTTP === '1' ? /^https?:\/\/[a-z0-9.-]+(:\d+)?\/?$/i : /^https:\/\/[a-z0-9.-]+(:\d+)?\/?$/i; // http solo en pruebas
  const ok = re.test(String(url || ''));
  if (!ok) return false;
  const changed = !pcRegistered() || pc.url !== url.replace(/\/+$/, '');
  pc.url = url.replace(/\/+$/, '');
  pc.at = Date.now();
  pc.fails = 0;
  if (changed) log('voz propia conectada desde la PC');
  return changed;
}

const pcRegistered = () => !!pc.url && Date.now() - pc.at < PC_FRESH_MS && pc.fails < 3;
export const pcVoiceOn = () => pcRegistered() && Date.now() >= pc.busyUntil;

function markBusy(why) {
  if (Date.now() < pc.busyUntil) return;
  pc.busyUntil = Date.now() + BUSY_MS;
  log('voz PC lenta (' + why + '): se usa la voz del iPhone mientras tanto');
  scheduleProbe();
}

// Mientras la PC está ocupada, una frase cortita de prueba cada minuto: si sale rápida, vuelve la voz propia.
function scheduleProbe() {
  if (pc.probing) return;
  pc.probing = true;
  const t = setTimeout(async () => {
    pc.probing = false;
    if (!pcRegistered()) return;
    const t0 = Date.now();
    try {
      await fromPc('Sí.');
      if (Date.now() - t0 <= PC_SLOW_MS) { pc.busyUntil = 0; log('voz PC rápida otra vez'); return; }
    } catch {}
    pc.busyUntil = Date.now() + BUSY_MS;
    scheduleProbe();
  }, PROBE_MS);
  t.unref?.();
}
const elevenOn = () => !!(config.eleven.key && config.eleven.voice);
export const ttsEnabled = () => pcVoiceOn() || elevenOn();
export const ttsSource = () => (pcVoiceOn() ? 'pc' : elevenOn() ? 'elevenlabs' : 'iphone');

async function fromPc(text) {
  const res = await fetch(pc.url + '/tts', {
    method: 'POST',
    signal: AbortSignal.timeout(PC_TIMEOUT_MS),
    headers: { 'content-type': 'application/json', authorization: `Bearer ${config.token}` },
    body: JSON.stringify({ text: text.slice(0, 1500) }),
  });
  if (!res.ok) throw new Error(`voz PC ${res.status}`);
  return { audio: Buffer.from(await res.arrayBuffer()), type: 'audio/wav' };
}

async function fromEleven(text) {
  const url = `https://api.elevenlabs.io/v1/text-to-speech/${config.eleven.voice}?output_format=mp3_44100_128`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'xi-api-key': config.eleven.key, 'content-type': 'application/json' },
    body: JSON.stringify({
      text: text.slice(0, 1500),
      model_id: config.eleven.model,
      voice_settings: { stability: 0.45, similarity_boost: 0.8, style: 0.25, use_speaker_boost: true },
    }),
  });
  if (!res.ok) throw new Error(`TTS ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return { audio: Buffer.from(await res.arrayBuffer()), type: 'audio/mpeg' };
}

// Devuelve {audio, type}. Si la voz de la PC falla 3 veces seguidas, se deja de usar hasta que vuelva a registrarse.
export async function synthesize(text) {
  if (pcVoiceOn()) {
    const t0 = Date.now();
    try {
      const r = await fromPc(text);
      pc.fails = 0;
      if (Date.now() - t0 > PC_SLOW_MS) markBusy(`${Date.now() - t0} ms`);
      return r;
    } catch (e) {
      if (e.name === 'TimeoutError' || /timeout|abort/i.test(e.message)) markBusy('sin respuesta en ' + PC_TIMEOUT_MS + ' ms');
      else pc.fails++;
      log('voz PC falló:', e.message);
      if (!elevenOn()) throw e;
    }
  }
  return fromEleven(text);
}

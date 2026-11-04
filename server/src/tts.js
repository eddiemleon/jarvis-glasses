import { config } from './config.js';

export const ttsEnabled = () => !!(config.eleven.key && config.eleven.voice);

// Voz neuronal opcional (ElevenLabs). Devuelve mp3.
export async function synthesize(text) {
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
  return Buffer.from(await res.arrayBuffer());
}

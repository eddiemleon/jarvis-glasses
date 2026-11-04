import { config } from "./config.js";

/** Devuelve PCM 16-bit little-endian mono a 24 kHz, o null si no hay ElevenLabs configurado. */
export async function synthesize(text: string): Promise<Buffer | null> {
  if (!config.elevenKey || !config.elevenVoice) return null;
  try {
    const url =
      `https://api.elevenlabs.io/v1/text-to-speech/${config.elevenVoice}` +
      `?output_format=pcm_24000&optimize_streaming_latency=3`;
    const res = await fetch(url, {
      method: "POST",
      headers: { "xi-api-key": config.elevenKey, "Content-Type": "application/json" },
      body: JSON.stringify({
        text,
        model_id: config.elevenModel,
        voice_settings: { stability: 0.45, similarity_boost: 0.8, style: 0.25 },
      }),
    });
    if (!res.ok) {
      console.error("ElevenLabs", res.status, await res.text().catch(() => ""));
      return null;
    }
    return Buffer.from(await res.arrayBuffer());
  } catch (e) {
    console.error("TTS error", e);
    return null;
  }
}

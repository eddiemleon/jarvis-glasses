import "node:process";

function env(name: string, fallback = ""): string {
  return process.env[name] ?? fallback;
}

export const config = {
  port: Number(env("PORT", "8080")),
  token: env("JARVIS_TOKEN"),
  anthropicKey: env("ANTHROPIC_API_KEY"),
  model: env("ANTHROPIC_MODEL", "claude-sonnet-5-5"),
  webSearch: env("ENABLE_WEB_SEARCH", "true") === "true",
  elevenKey: env("ELEVENLABS_API_KEY"),
  elevenVoice: env("ELEVENLABS_VOICE_ID"),
  elevenModel: env("ELEVENLABS_MODEL", "eleven_flash_v2_5"),
  waVerify: env("WHATSAPP_VERIFY_TOKEN"),
  waToken: env("WHATSAPP_ACCESS_TOKEN"),
  waPhoneId: env("WHATSAPP_PHONE_NUMBER_ID"),
  dataDir: env("DATA_DIR", "./data"),
  userName: env("USER_NAME", "Eddie"),
  timezone: env("TIMEZONE", "America/Puerto_Rico"),
};

export function assertConfig(): void {
  const missing: string[] = [];
  if (!config.token) missing.push("JARVIS_TOKEN");
  if (!config.anthropicKey) missing.push("ANTHROPIC_API_KEY");
  if (missing.length) {
    console.error(`Faltan variables obligatorias: ${missing.join(", ")}`);
    process.exit(1);
  }
}

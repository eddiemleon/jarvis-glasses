const env = process.env;

export const config = {
  port: Number(env.PORT || 8080),
  token: env.JARVIS_TOKEN || '',
  anthropicKey: env.ANTHROPIC_API_KEY || '',
  anthropicBase: env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com',
  // Automático: Sonnet para charla rápida, Opus para lo complejo. JARVIS_MODEL (opcional) fuerza uno solo.
  model: env.JARVIS_MODEL || 'claude-sonnet-5-5',
  modelDeep: env.JARVIS_MODEL || 'claude-opus-5-5',
  // Modelo económico para tareas de fondo (vigilancia, traducción, descripciones). Si no existe, se usa el normal.
  modelFast: env.JARVIS_MODEL_FAST || env.JARVIS_MODEL || 'claude-haiku-5-5',
  maxTokens: Number(env.JARVIS_MAX_TOKENS || 1024),
  webSearch: env.WEB_SEARCH !== '0',
  mock: env.MOCK_LLM === '1',
  tz: env.JARVIS_TZ || 'America/Puerto_Rico',
  owner: env.JARVIS_OWNER || 'Leon',
  // Tras cuántos minutos sin hablar Jarvis lo recibe con "Bienvenido de vuelta".
  welcomeAfterMin: Number(env.JARVIS_WELCOME_MIN || 30),
  publicUrl: (env.PUBLIC_URL || '').replace(/\/+$/, ''),
  dataDir: env.DATA_DIR || './data',
  tvSecret: env.TV_SECRET || '',
  wa: {
    verifyToken: env.WA_VERIFY_TOKEN || '',
    token: env.WA_TOKEN || '',
    phoneId: env.WA_PHONE_ID || '',
    appSecret: env.WA_APP_SECRET || '',
    apiVersion: env.WA_API_VERSION || 'v21.0',
  },
  // Cerebros adicionales: basta con pegar la clave. URL y modelo se detectan solos.
  // Orden automático: Claude → Gemini → OpenAI → OpenRouter → Groq → Ollama (el primero disponible es el principal).
  fallbacks: [
    { name: 'gemini', base: 'https://generativelanguage.googleapis.com/v1beta/openai', key: env.GEMINI_API_KEY, model: 'gemini-2.5-pro' },
    { name: 'openai', base: 'https://api.openai.com/v1', key: env.OPENAI_API_KEY, model: 'gpt-5' },
    { name: 'openrouter', base: 'https://openrouter.ai/api/v1', key: env.OPENROUTER_API_KEY, model: 'openrouter/auto', fixed: true },
    { name: 'groq', base: 'https://api.groq.com/openai/v1', key: env.GROQ_API_KEY, model: 'llama-3.3-70b-versatile' },
    { name: 'ollama', base: env.OLLAMA_URL ? env.OLLAMA_URL.replace(/\/+$/, '') + '/v1' : '', key: env.OLLAMA_URL ? 'local' : '', model: 'llama3.3' },
    // Compatibilidad con configuraciones antiguas (opcional, ya no hace falta):
    { name: (env.BRAIN2_NAME || env.FALLBACK_NAME || 'cerebro2').toLowerCase(), base: (env.BRAIN2_BASE_URL || env.FALLBACK_BASE_URL || '').replace(/\/+$/, ''), key: env.BRAIN2_API_KEY || env.FALLBACK_API_KEY || 'x', model: env.BRAIN2_MODEL || env.FALLBACK_MODEL || '', fixed: true },
    { name: (env.BRAIN3_NAME || env.FALLBACK2_NAME || 'cerebro3').toLowerCase(), base: (env.BRAIN3_BASE_URL || env.FALLBACK2_BASE_URL || '').replace(/\/+$/, ''), key: env.BRAIN3_API_KEY || env.FALLBACK2_API_KEY || 'x', model: env.BRAIN3_MODEL || env.FALLBACK2_MODEL || '', fixed: true },
  ].filter((f) => f.base && f.key && f.model),
  brainOrder: (env.BRAIN_ORDER || '').split(',').map((x) => x.trim().toLowerCase()).filter(Boolean),
  eleven: {
    key: env.ELEVENLABS_API_KEY || '',
    voice: env.ELEVENLABS_VOICE_ID || '',
    model: env.ELEVENLABS_MODEL || 'eleven_flash_v2_5',
  },
};

export function log(...a) {
  console.log(new Date().toISOString(), ...a);
}

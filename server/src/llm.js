// Cadena de cerebros: Claude primero; si no hay créditos, hay límite o está caído, pasa solo al respaldo.
import { config, log } from './config.js';
import { createMessage, ApiError } from './claude.js';
import { createOpenAI } from './openai.js';

const down = new Map(); // proveedor -> hasta cuándo evitarlo
const notified = new Map();
const today = () => new Date().toISOString().slice(0, 10);
let stats = { day: today(), byProvider: {} };

function bump(name, u) {
  if (stats.day !== today()) stats = { day: today(), byProvider: {} };
  const s = (stats.byProvider[name] ||= { calls: 0, input: 0, output: 0 });
  s.calls++;
  s.input += u?.input || 0;
  s.output += u?.output || 0;
}
export const usageSnapshot = () => ({ ...stats, down: Object.fromEntries([...down].filter(([, t]) => t > Date.now()).map(([k, t]) => [k, new Date(t).toISOString()])) });

export function providers() {
  const list = [];
  if (config.anthropicKey) {
    list.push({
      name: 'claude',
      label: config.model,
      async call(params, opts) {
        const p = { ...params, model: opts?.fast ? config.modelFast : opts?.complex ? config.modelDeep : config.model };
        try {
          return await createMessage(p, opts);
        } catch (e) {
          // El modelo económico no existe en esta cuenta: se usa el normal desde ya (sin marcar a Claude como caído).
          if (e instanceof ApiError && e.status === 404 && opts?.fast && p.model !== config.model) {
            log(`llm: modelo económico ${p.model} no disponible; uso ${config.model}`);
            config.modelFast = config.model;
            return createMessage({ ...p, model: config.model }, opts);
          }
          if (e instanceof ApiError && e.status === 400 && /web_search/i.test(e.body) && config.webSearch) {
            log('llm: búsqueda web no disponible en esta cuenta; desactivada');
            config.webSearch = false;
            return createMessage({ ...p, tools: p.tools.filter((t) => t.name !== 'web_search') }, opts);
          }
          throw e;
        }
      },
    });
  }
  for (const f of config.fallbacks) list.push({ name: f.name, label: f.model, call: (params, opts) => createOpenAI(f, params, opts) });
  // El primero de BRAIN_ORDER es el cerebro principal; los demás quedan como reserva en ese orden.
  const rank = (p) => {
    const i = config.brainOrder.indexOf(p.name);
    return i < 0 ? 1000 + list.indexOf(p) : i;
  };
  return list.sort((a, b) => rank(a) - rank(b));
}

function classify(e) {
  const min = 60_000;
  if (e instanceof ApiError) {
    const b = e.body || '';
    if (e.status === 402 || /credit balance|billing|insufficient|quota|exceeded your/i.test(b)) return { ms: 60 * min, reason: 'credits' };
    if (e.status === 401 || e.status === 403) return { ms: 30 * min, reason: 'auth' };
    if (e.status === 404) return { ms: 30 * min, reason: 'model' };
    if (e.status === 429) return { ms: 2 * min, reason: 'rate' };
    if (e.status >= 500) return { ms: 2 * min, reason: 'overload' };
    return null;
  }
  if (e?.name === 'TypeError' || /fetch failed|ENOTFOUND|ECONN|ETIMEDOUT/i.test(e?.message || '')) return { ms: min, reason: 'network' };
  return null;
}

const switchText = (reason, to) =>
  reason === 'credits'
    ? `Mi cerebro principal se quedó sin créditos, señor. Continúo con ${to}.`
    : `Mi cerebro principal no responde, señor. Continúo con ${to}.`;

const SKIP = /embed|tts|whisper|image|audio|vision|moderation|rerank|guard|transcrib|realtime|dall|imagen|veo|lyria|robotics|aqa/i;
export function rankModel(id) {
  const nums = (id.match(/\d+(?:\.\d+)?/g) || []).map(Number);
  const version = nums.length ? Math.max(...nums.filter((n) => n < 100), 0) : 0; // evita fechas/tamaños enormes
  const big = Number((id.match(/(\d+)b\b/i) || [])[1] || 0);
  const tier = /pro|opus|ultra|large|405b|70b|gpt-\d+(?!.*(mini|nano))|\bo\d/i.test(id) ? 2 : /flash|mini|small|haiku|sonnet|nano|\b[0-8]b\b/i.test(id) ? 1 : 0;
  const penalty = /preview|exp|deprecated|legacy|instruct-0/i.test(id) ? 1 : 0;
  return tier * 1000 + (tier === 0 ? 0 : 0) + version * 10 + Math.min(big, 400) / 100 - penalty * 5;
}

// Al arrancar: pregunta a cada servicio qué modelos tiene y se queda con el más capaz. Si no puede, usa el de fábrica.
export async function resolveBrains() {
  await Promise.all(
    config.fallbacks.filter((f) => !f.fixed).map(async (f) => {
      try {
        const ctl = AbortSignal.timeout(6000);
        const res = await fetch(`${f.base}/models`, { signal: ctl, headers: f.key && f.key !== 'local' ? { authorization: `Bearer ${f.key}` } : {} });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const j = await res.json();
        const ids = (j.data || j.models || []).map((m) => String(m.id || m.name || '').replace(/^models\//, '')).filter((id) => id && !SKIP.test(id));
        if (!ids.length) throw new Error('sin modelos');
        const best = ids.sort((a, b) => rankModel(b) - rankModel(a))[0];
        log(`cerebro ${f.name}: modelo elegido automáticamente → ${best}`);
        f.model = best;
      } catch (e) {
        log(`cerebro ${f.name}: no pude listar modelos (${e.message}); uso ${f.model}`);
      }
    })
  );
}

// Pregunta corta al modelo económico, sin herramientas. Devuelve solo el texto.
export async function quickAsk({ system, content, maxTokens = 300, signal }) {
  const r = await callLLM(
    { max_tokens: maxTokens, system: [{ type: 'text', text: system }], messages: [{ role: 'user', content }] },
    { fast: true, signal }
  );
  return r.content
    .filter((b) => b.type === 'text')
    .map((b) => b.text)
    .join('')
    .trim();
}

export async function callLLM(params, { signal, onText, onNotice, complex, fast } = {}) {
  const list = providers();
  if (!list.length) throw new Error('No hay ningún proveedor de IA configurado');
  let lastErr;
  for (let i = 0; i < list.length; i++) {
    const p = list[i];
    const isLast = i === list.length - 1;
    if ((down.get(p.name) || 0) > Date.now() && !isLast) continue;
    let emitted = false;
    if (i > 0 && (notified.get(p.name) || 0) < Date.now() - 600_000) {
      notified.set(p.name, Date.now());
      onNotice?.(switchText(lastErr ? classify(lastErr)?.reason : 'overload', p.name)); // antes de que el otro cerebro empiece a hablar
    }
    try {
      const r = await p.call(params, {
        signal,
        complex,
        fast,
        onText: (t) => {
          emitted = true;
          onText?.(t);
        },
      });
      bump(p.name, r.usage);
      return { ...r, provider: p.name };
    } catch (e) {
      if (signal?.aborted) throw e;
      lastErr = e;
      const c = classify(e);
      log(`llm: ${p.name} falló (${c?.reason || 'error'}): ${String(e.message).slice(0, 160)}`);
      if (!c || emitted) throw e; // errores de petición o ya se habló: no tiene sentido cambiar de cerebro a medias
      down.set(p.name, Date.now() + c.ms);
      if (isLast) throw e;
    }
  }
  throw lastErr;
}

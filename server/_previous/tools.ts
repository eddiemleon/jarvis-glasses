import type Anthropic from "@anthropic-ai/sdk";
import { config } from "./config.js";
import { store } from "./store.js";
import { sendWhatsApp } from "./whatsapp.js";

/** Herramientas que se ejecutan en el iPhone (el servidor las pide por WebSocket). */
export const CLIENT_TOOLS = new Set(["take_photo", "get_location", "navigate", "stop_navigation"]);

export function toolDefinitions(): Anthropic.Messages.ToolUnion[] {
  const tools: Anthropic.Messages.ToolUnion[] = [
    {
      name: "take_photo",
      description:
        "Toma una foto con la cámara de las gafas (lo que el usuario está mirando) y te la devuelve para analizarla.",
      input_schema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "get_location",
      description: "Devuelve la ubicación GPS actual del usuario (latitud, longitud, dirección aproximada).",
      input_schema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "navigate",
      description:
        "Inicia navegación por voz paso a paso desde la ubicación actual hasta un destino (nombre de lugar o dirección).",
      input_schema: {
        type: "object",
        properties: {
          destination: { type: "string", description: "Lugar o dirección de destino" },
          mode: { type: "string", enum: ["driving", "walking", "transit"], description: "Por defecto driving" },
        },
        required: ["destination"],
      },
    },
    {
      name: "stop_navigation",
      description: "Cancela la navegación activa.",
      input_schema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "recent_trading_alerts",
      description: "Últimas alertas recibidas desde TradingView (más recientes al final).",
      input_schema: {
        type: "object",
        properties: { limit: { type: "integer", description: "Cuántas (por defecto 5, máx 30)" } },
        required: [],
      },
    },
    {
      name: "whatsapp_inbox",
      description: "Últimos mensajes de WhatsApp Business recibidos y enviados.",
      input_schema: {
        type: "object",
        properties: { limit: { type: "integer", description: "Cuántos (por defecto 5, máx 30)" } },
        required: [],
      },
    },
    {
      name: "whatsapp_send",
      description:
        "Envía un mensaje de WhatsApp Business. SOLO tras confirmación explícita del usuario con el texto exacto.",
      input_schema: {
        type: "object",
        properties: {
          to: { type: "string", description: "Número con código de país, solo dígitos" },
          text: { type: "string" },
        },
        required: ["to", "text"],
      },
    },
    {
      name: "remember",
      description: "Guarda un hecho duradero sobre el usuario para futuras conversaciones.",
      input_schema: {
        type: "object",
        properties: { fact: { type: "string" } },
        required: ["fact"],
      },
    },
    {
      name: "forget",
      description: "Borra de la memoria todo lo que contenga este fragmento de texto.",
      input_schema: {
        type: "object",
        properties: { fragment: { type: "string" } },
        required: ["fragment"],
      },
    },
  ];
  if (config.webSearch) {
    tools.push({ type: "web_search_20250305", name: "web_search", max_uses: 3 } as Anthropic.Messages.ToolUnion);
  }
  return tools;
}

/** Ejecuta herramientas del lado del servidor. */
export async function runServerTool(name: string, input: Record<string, unknown>): Promise<string> {
  switch (name) {
    case "recent_trading_alerts": {
      const n = Math.min(Number(input.limit) || 5, 30);
      const a = store.alerts(n);
      return a.length ? a.map((x) => `[${x.at}] ${x.text}`).join("\n") : "No hay alertas recientes.";
    }
    case "whatsapp_inbox": {
      const n = Math.min(Number(input.limit) || 5, 30);
      const m = store.whatsapp(n);
      return m.length
        ? m
            .map((x) => `[${x.at}] ${x.direction === "in" ? "de" : "para"} ${x.name ?? x.from}: ${x.text}`)
            .join("\n")
        : "No hay mensajes.";
    }
    case "whatsapp_send":
      return sendWhatsApp(String(input.to ?? ""), String(input.text ?? ""));
    case "remember":
      store.remember(String(input.fact ?? "").slice(0, 300));
      return "Guardado.";
    case "forget":
      return `Borrados ${store.forget(String(input.fragment ?? ""))} elementos.`;
    default:
      return `Herramienta desconocida: ${name}`;
  }
}

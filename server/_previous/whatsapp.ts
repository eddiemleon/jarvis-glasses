import { Router } from "express";
import { config } from "./config.js";
import { store } from "./store.js";

type Notify = (text: string) => void;

export function whatsappRouter(notify: Notify): Router {
  const r = Router();

  // Verificación del webhook (Meta la llama una vez al configurarlo)
  r.get("/webhook/whatsapp", (req, res) => {
    if (
      req.query["hub.mode"] === "subscribe" &&
      req.query["hub.verify_token"] === config.waVerify &&
      config.waVerify
    ) {
      res.status(200).send(String(req.query["hub.challenge"]));
    } else {
      res.sendStatus(403);
    }
  });

  // Mensajes entrantes
  r.post("/webhook/whatsapp", (req, res) => {
    res.sendStatus(200);
    try {
      const entries = req.body?.entry ?? [];
      for (const entry of entries) {
        for (const change of entry.changes ?? []) {
          const value = change.value ?? {};
          const contacts: Record<string, string> = {};
          for (const c of value.contacts ?? []) contacts[c.wa_id] = c.profile?.name ?? "";
          for (const m of value.messages ?? []) {
            const text =
              m.type === "text" ? m.text?.body : `[${m.type ?? "mensaje"} sin texto]`;
            const name = contacts[m.from] || undefined;
            store.addWhatsApp({
              at: new Date().toISOString(),
              from: m.from,
              name,
              text: String(text ?? ""),
              direction: "in",
            });
            notify(`WhatsApp de ${name ?? m.from}: ${text}`);
          }
        }
      }
    } catch (e) {
      console.error("whatsapp webhook", e);
    }
  });

  return r;
}

export async function sendWhatsApp(to: string, text: string): Promise<string> {
  if (!config.waToken || !config.waPhoneId) {
    return "WhatsApp Business no está configurado en el servidor.";
  }
  const res = await fetch(`https://graph.facebook.com/v21.0/${config.waPhoneId}/messages`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.waToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      to: to.replace(/[^\d]/g, ""),
      type: "text",
      text: { body: text },
    }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    return `Error de WhatsApp (${res.status}): ${body.slice(0, 300)}`;
  }
  store.addWhatsApp({
    at: new Date().toISOString(),
    from: to,
    text,
    direction: "out",
  });
  return "Mensaje enviado.";
}

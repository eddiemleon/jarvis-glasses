import fs from "node:fs";
import path from "node:path";
import { config } from "./config.js";

export interface TradingAlert {
  at: string;
  text: string;
}
export interface WhatsAppMessage {
  at: string;
  from: string;
  name?: string;
  text: string;
  direction: "in" | "out";
}

interface Data {
  alerts: TradingAlert[];
  whatsapp: WhatsAppMessage[];
  memory: string[];
}

const file = path.join(config.dataDir, "jarvis.json");
let data: Data = { alerts: [], whatsapp: [], memory: [] };

try {
  fs.mkdirSync(config.dataDir, { recursive: true });
  if (fs.existsSync(file)) data = { ...data, ...JSON.parse(fs.readFileSync(file, "utf8")) };
} catch (e) {
  console.error("No se pudo leer el almacén, empiezo vacío:", e);
}

let timer: NodeJS.Timeout | null = null;
function save(): void {
  if (timer) return;
  timer = setTimeout(() => {
    timer = null;
    try {
      fs.writeFileSync(file, JSON.stringify(data));
    } catch (e) {
      console.error("Error guardando:", e);
    }
  }, 500);
}

export const store = {
  addAlert(text: string): TradingAlert {
    const a = { at: new Date().toISOString(), text };
    data.alerts.push(a);
    data.alerts = data.alerts.slice(-200);
    save();
    return a;
  },
  alerts(limit: number): TradingAlert[] {
    return data.alerts.slice(-limit);
  },
  addWhatsApp(m: WhatsAppMessage): void {
    data.whatsapp.push(m);
    data.whatsapp = data.whatsapp.slice(-500);
    save();
  },
  whatsapp(limit: number): WhatsAppMessage[] {
    return data.whatsapp.slice(-limit);
  },
  remember(fact: string): void {
    if (!data.memory.includes(fact)) data.memory.push(fact);
    data.memory = data.memory.slice(-100);
    save();
  },
  forget(fragment: string): number {
    const before = data.memory.length;
    data.memory = data.memory.filter((m) => !m.toLowerCase().includes(fragment.toLowerCase()));
    save();
    return before - data.memory.length;
  },
  memory(): string[] {
    return [...data.memory];
  },
};

import crypto from 'node:crypto';
import { log } from './config.js';

// Registro de clientes (la app del iPhone) + cola de eventos para cuando no hay nadie conectado.
class Hub {
  constructor() {
    this.clients = new Set();
    this.captures = new Map();
    this.queue = [];
  }

  add(conn) {
    this.clients.add(conn);
  }
  remove(conn) {
    this.clients.delete(conn);
  }
  get connected() {
    return this.clients.size > 0;
  }

  send(obj) {
    const text = JSON.stringify(obj);
    let n = 0;
    for (const c of this.clients) if (c.send(text)) n++;
    return n > 0;
  }

  // Eventos importantes (alertas, WhatsApp): si no hay app conectada se guardan 1 h.
  deliver(obj) {
    if (this.send(obj)) return true;
    this.queue.push({ obj, at: Date.now() });
    while (this.queue.length > 50) this.queue.shift();
    return false;
  }

  flushQueue(conn) {
    const fresh = this.queue.filter((q) => Date.now() - q.at < 3600_000);
    this.queue = [];
    for (const q of fresh) conn.send(JSON.stringify({ ...q.obj, late: true }));
    return fresh.length;
  }

  // Pide una foto a las gafas (vía la app) y espera el resultado.
  // Las fotos van en fila: la cámara de las gafas nunca recibe dos peticiones a la vez (vigilancia + "qué es esto").
  requestCapture(timeoutMs = 15000, signal) {
    const run = (this.captureChain || Promise.resolve()).then(() => this._capture(timeoutMs, signal));
    this.captureChain = run.catch(() => {});
    return run;
  }

  _capture(timeoutMs, signal) {
    return new Promise((resolve, reject) => {
      if (signal?.aborted) return reject(new Error('cancelado'));
      if (!this.connected) return reject(new Error('La app no está conectada'));
      const reqId = crypto.randomUUID();
      const timer = setTimeout(() => {
        this.captures.delete(reqId);
        reject(new Error('Tiempo agotado esperando la foto de las gafas'));
      }, timeoutMs);
      const done = (fn) => (v) => {
        clearTimeout(timer);
        this.captures.delete(reqId);
        fn(v);
      };
      this.captures.set(reqId, { resolve: done(resolve), reject: done(reject) });
      signal?.addEventListener('abort', () => this.captures.get(reqId)?.reject(new Error('cancelado')), { once: true });
      this.send({ type: 'capture_request', reqId });
      log('hub: capture_request', reqId);
    });
  }

  resolveCapture(msg) {
    const p = this.captures.get(msg.reqId);
    if (!p) return;
    if (msg.error || !msg.imageBase64) p.reject(new Error(msg.error || 'Sin imagen'));
    else p.resolve(msg.imageBase64);
  }

  // Petición genérica a la app (calendario, etc.): {type:'device_request', reqId, action, params} → {type:'device_result', reqId, ok, data|error}.
  requestDevice(action, params = {}, timeoutMs = 12000, signal) {
    return new Promise((resolve, reject) => {
      if (!this.connected) return reject(new Error('La app no está conectada'));
      const reqId = crypto.randomUUID();
      const timer = setTimeout(() => {
        this.captures.delete(reqId);
        reject(new Error('La app no respondió a tiempo (¿app sin actualizar?)'));
      }, timeoutMs);
      const done = (fn) => (v) => {
        clearTimeout(timer);
        this.captures.delete(reqId);
        fn(v);
      };
      this.captures.set(reqId, { resolve: done(resolve), reject: done(reject) });
      signal?.addEventListener('abort', () => this.captures.get(reqId)?.reject(new Error('cancelado')), { once: true });
      this.send({ type: 'device_request', reqId, action, params });
    });
  }

  resolveDevice(msg) {
    const p = this.captures.get(msg.reqId);
    if (!p) return;
    if (msg.ok === false || msg.error) p.reject(new Error(String(msg.error || 'Falló en el teléfono')));
    else p.resolve(msg.data ?? null);
  }
}

export const hub = new Hub();

// Servidor WebSocket mínimo (RFC 6455) sin dependencias: texto, ping/pong, cierre, fragmentos.
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_MESSAGE = 12 * 1024 * 1024;

export class WSConnection extends EventEmitter {
  constructor(socket) {
    super();
    this.socket = socket;
    this.buf = Buffer.alloc(0);
    this.frags = [];
    this.fragOpcode = 0;
    this.closed = false;
    this.lastSeen = Date.now();
    socket.setNoDelay(true);
    socket.on('data', (d) => this._onData(d));
    socket.on('close', () => this._finish());
    socket.on('error', () => this._finish());
  }

  _finish() {
    if (this.closed) return;
    this.closed = true;
    this.emit('close');
  }

  _frame(opcode, payload) {
    const len = payload.length;
    let header;
    if (len < 126) header = Buffer.from([0x80 | opcode, len]);
    else if (len < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | opcode;
      header[1] = 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | opcode;
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(len), 2);
    }
    return Buffer.concat([header, payload]);
  }

  send(text) {
    if (this.closed || this.socket.destroyed) return false;
    this.socket.write(this._frame(0x1, Buffer.from(text, 'utf8')));
    return true;
  }

  sendBinary(buf) {
    if (this.closed || this.socket.destroyed) return false;
    this.socket.write(this._frame(0x2, buf));
    return true;
  }

  get backlog() {
    return this.socket.writableLength;
  }

  ping() {
    if (!this.closed) this.socket.write(this._frame(0x9, Buffer.alloc(0)));
  }

  close(code = 1000) {
    if (this.closed) return;
    const p = Buffer.alloc(2);
    p.writeUInt16BE(code);
    try {
      this.socket.write(this._frame(0x8, p));
    } catch {}
    this.socket.end();
    this._finish();
  }

  _onData(chunk) {
    this.lastSeen = Date.now();
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    while (this.buf.length >= 2) {
      const b0 = this.buf[0];
      const b1 = this.buf[1];
      const fin = !!(b0 & 0x80);
      const opcode = b0 & 0x0f;
      const masked = !!(b1 & 0x80);
      let len = b1 & 0x7f;
      let off = 2;
      if (len === 126) {
        if (this.buf.length < 4) return;
        len = this.buf.readUInt16BE(2);
        off = 4;
      } else if (len === 127) {
        if (this.buf.length < 10) return;
        len = Number(this.buf.readBigUInt64BE(2));
        off = 10;
      }
      if (len > MAX_MESSAGE) return this.close(1009);
      const maskLen = masked ? 4 : 0;
      if (this.buf.length < off + maskLen + len) return;
      let payload = Buffer.from(this.buf.subarray(off + maskLen, off + maskLen + len));
      if (masked) {
        const mask = this.buf.subarray(off, off + 4);
        for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      }
      this.buf = this.buf.subarray(off + maskLen + len);

      if (opcode === 0x8) return this.close(1000);
      if (opcode === 0x9) {
        if (!this.closed) this.socket.write(this._frame(0xa, payload));
        continue;
      }
      if (opcode === 0xa) continue;
      if (opcode === 0x1 || opcode === 0x2) {
        this.fragOpcode = opcode;
        this.frags = [payload];
      } else if (opcode === 0x0) {
        this.frags.push(payload);
      } else continue;
      if (fin) {
        const data = Buffer.concat(this.frags);
        this.frags = [];
        if (this.fragOpcode === 0x1) this.emit('message', data.toString('utf8'));
        else this.emit('binary', data);
      }
    }
  }
}

export function upgrade(req, socket, head, onConnection) {
  const key = req.headers['sec-websocket-key'];
  if (!key || String(req.headers.upgrade).toLowerCase() !== 'websocket') {
    socket.destroy();
    return;
  }
  const accept = crypto.createHash('sha1').update(key + GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );
  const conn = new WSConnection(socket);
  onConnection(conn, req);
  if (head && head.length) conn._onData(head);
}

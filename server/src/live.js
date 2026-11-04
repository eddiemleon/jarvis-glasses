import crypto from 'node:crypto';
import { hub } from './hub.js';
import { config, log } from './config.js';

// Transmisión en vivo (video + audio de las gafas) a un enlace privado que se abre en cualquier navegador.
// Paquetes binarios desde la app: 0x01 + JPEG | 0x02 + PCM16 LE 16 kHz mono. Se reenvían tal cual a los visores.
class Live {
  current = null;
  lastBase = '';

  create(minutes = 60) {
    this.stop('replaced', false);
    const ttl = Math.max(1, Math.min(720, Math.round(Number(minutes) || 60)));
    const id = crypto.randomBytes(16).toString('base64url');
    const expires = Date.now() + ttl * 60_000;
    const base = config.publicUrl || this.lastBase || 'http://localhost:' + config.port;
    const timer = setTimeout(() => this.stop('expired'), ttl * 60_000);
    this.current = { id, expires, viewers: new Set(), started: Date.now(), timer, lastFrame: null };
    log('live: creada', id.slice(0, 6) + '…', `${ttl} min`);
    return { id, url: `${base}/live/${id}`, expires };
  }

  valid(id) {
    const c = this.current;
    return !!c && c.id === id && Date.now() < c.expires;
  }

  addViewer(conn) {
    const c = this.current;
    if (!c) return false;
    c.viewers.add(conn);
    conn.send(JSON.stringify({ type: 'hello', startedAt: c.started, expires: c.expires }));
    if (c.lastFrame) conn.sendBinary(c.lastFrame);
    this.announceCount();
    conn.on('close', () => {
      c.viewers.delete(conn);
      if (this.current === c) this.announceCount();
    });
    return true;
  }

  announceCount() {
    hub.send({ type: 'live_viewers', n: this.current?.viewers.size || 0 });
  }

  // Baja latencia (tipo AirPlay): nunca se acumula video. Si un visor todavía no terminó de recibir
  // el cuadro anterior, el nuevo se descarta y le llega el siguiente: siempre ve lo más reciente.
  relay(buf) {
    const c = this.current;
    if (!c || buf.length < 2) return;
    const video = buf[0] === 1;
    if (video) {
      c.lastFrame = buf;
      c.frames = (c.frames || 0) + 1;
    }
    for (const v of c.viewers) {
      if (video && v.backlog > buf.length) continue; // más de ~1 cuadro pendiente: saltar este
      if (!video && v.backlog > 256_000) continue; // audio: solo se descarta si el visor está muy atrasado
      v.sendBinary(buf);
    }
  }

  stop(reason = 'stopped', notifyApp = true) {
    const c = this.current;
    if (!c) return false;
    clearTimeout(c.timer);
    for (const v of c.viewers) {
      v.send(JSON.stringify({ type: 'ended', reason }));
      v.close(1000);
    }
    this.current = null;
    if (notifyApp) hub.send({ type: 'live_ended', reason });
    log('live: terminada', reason);
    return true;
  }
}

export const live = new Live();

export const VIEWER_HTML = `<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow"><title>Jarvis · En vivo</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}
body{margin:0;background:#04070d;color:#e8f6ff;font:16px -apple-system,system-ui,sans-serif;min-height:100dvh;display:flex;flex-direction:column}
header{display:flex;align-items:center;gap:10px;padding:12px 16px}
.dot{width:10px;height:10px;border-radius:50%;background:#777}.live .dot{background:#ff3b30;box-shadow:0 0 10px #ff3b30;animation:p 1.2s infinite}
@keyframes p{50%{opacity:.35}}
h1{font-size:15px;font-weight:600;margin:0;flex:1;letter-spacing:.3px}
#stage{flex:1;display:flex;align-items:center;justify-content:center;padding:0 12px;min-height:0}
img{max-width:100%;max-height:calc(100dvh - 150px);border-radius:14px;background:#0b1220;display:block}
#msg{position:absolute;text-align:center;color:#8fb4c8;padding:20px}
footer{display:flex;gap:10px;padding:14px 16px calc(14px + env(safe-area-inset-bottom))}
button{flex:1;padding:13px;border:0;border-radius:12px;background:#12324a;color:#bdefff;font-size:15px;font-weight:600}
button.on{background:#0a8aa8;color:#fff}
small{display:block;text-align:center;color:#5d7a8c;padding:0 16px 10px}
</style></head><body>
<header id="hd"><span class="dot"></span><h1>Jarvis · En vivo</h1><span id="st">Conectando…</span></header>
<div id="stage"><div id="msg">Esperando video…</div><img id="v" alt="" hidden></div>
<div id="hdbar" style="display:none;gap:10px;align-items:center;margin:8px 16px 0;padding:10px 12px;border-radius:12px;background:#0f2a3d"><span style="flex:1">📸 Foto en máxima calidad</span><a id="hdview" target="_blank" style="color:#7fe3ff">Ver</a><a id="hddl" download="jarvis-foto.jpg" style="color:#7fe3ff">Descargar</a></div>
<small>Transmisión privada. Solo quien tiene este enlace puede verla.</small>
<footer><button id="snd">🔇 Activar sonido</button><button id="fs">⛶ Pantalla completa</button></footer>
<script>
const id=location.pathname.split('/').pop();
const img=document.getElementById('v'),msg=document.getElementById('msg'),st=document.getElementById('st'),hd=document.getElementById('hd'),snd=document.getElementById('snd');
let ctx=null,next=0,sound=false,ended=false,frames=0,lastUrl=null,retry=0,hdUrl=null;
function setSound(on){sound=on;if(on&&!ctx){ctx=new (window.AudioContext||window.webkitAudioContext)()}if(ctx&&on)ctx.resume();snd.textContent=on?'🔊 Sonido activado':'🔇 Activar sonido';snd.className=on?'on':''}
snd.onclick=()=>setSound(!sound);
document.getElementById('fs').onclick=()=>{const e=document.documentElement;(e.requestFullscreen||e.webkitRequestFullscreen||(()=>{})).call(e)};
function pcm(u8){if(!ctx||!sound)return;const n=u8.byteLength>>1;if(!n)return;const dv=new DataView(u8.buffer,u8.byteOffset,u8.byteLength);
const b=ctx.createBuffer(1,n,16000),ch=b.getChannelData(0);for(let i=0;i<n;i++)ch[i]=dv.getInt16(i*2,true)/32768;
const s=ctx.createBufferSource();s.buffer=b;s.connect(ctx.destination);const now=ctx.currentTime;if(next<now+0.03||next>now+0.5)next=now+0.1;s.start(next);next+=b.duration}
function connect(){
 const ws=new WebSocket((location.protocol==='https:'?'wss':'ws')+'://'+location.host+'/live/ws?id='+encodeURIComponent(id));ws.binaryType='arraybuffer';
 ws.onopen=()=>{retry=0;st.textContent='Conectado'};
 ws.onmessage=e=>{
  if(typeof e.data==='string'){const m=JSON.parse(e.data);if(m.type==='ended'){ended=true;hd.className='';st.textContent='Terminó';msg.hidden=false;msg.textContent='La transmisión terminó.';img.hidden=true}return}
  const u=new Uint8Array(e.data);if(!u.length)return;const t=u[0],body=u.subarray(1);
  if(t===1){const url=URL.createObjectURL(new Blob([body],{type:'image/jpeg'}));img.onload=()=>{if(lastUrl)URL.revokeObjectURL(lastUrl);lastUrl=url};img.src=url;if(img.hidden){img.hidden=false;msg.hidden=true}hd.className='live';frames++}
  else if(t===2)pcm(body)
  else if(t===3){if(hdUrl)URL.revokeObjectURL(hdUrl);hdUrl=URL.createObjectURL(new Blob([body],{type:'image/jpeg'}));const b=document.getElementById('hdbar');b.style.display='flex';document.getElementById('hdview').href=hdUrl;document.getElementById('hddl').href=hdUrl}};
 ws.onclose=ev=>{if(ended)return;if(ev.code===1008){msg.hidden=false;msg.textContent='Este enlace expiró o no existe.';st.textContent='—';return}hd.className='';st.textContent='Reconectando…';setTimeout(connect,Math.min(5000,1000*++retry))}
}
setInterval(()=>{if(hd.className==='live')st.textContent='EN VIVO · '+frames+' fps';frames=0},1000);
connect();
</script></body></html>`;

export const EXPIRED_HTML = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Jarvis</title>
<body style="background:#04070d;color:#8fb4c8;font:16px system-ui;display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center;padding:24px">Este enlace expiró o la transmisión ya terminó.</body>`;

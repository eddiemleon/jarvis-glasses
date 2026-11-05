"""
Voz de Jarvis: clona la voz de referencia.wav con XTTS-v2 (código abierto, uso personal no comercial)
y la sirve al servidor de Jarvis.

  python voz_jarvis.py --muestra salida.wav "Texto"   -> genera un audio de prueba
  python voz_jarvis.py --servidor                      -> servidor de voz + túnel seguro + registro en Jarvis

Variables (archivo config.txt junto a este script, una por línea CLAVE=valor):
  JARVIS_URL=https://jarvis-xxxx.onrender.com
  JARVIS_TOKEN=la contraseña de Jarvis
"""
import io
import json
import os
import re
import subprocess
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import request

AQUI = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(AQUI, "referencia.wav")
PUERTO = 8765
SR = 24000


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def cargar_config():
    cfg = dict(os.environ)
    ruta = os.path.join(AQUI, "config.txt")
    if os.path.exists(ruta):
        for linea in open(ruta, encoding="utf-8"):
            if "=" in linea and not linea.strip().startswith("#"):
                k, v = linea.split("=", 1)
                cfg[k.strip()] = v.strip()
    return cfg


# ---------------- motor de voz ----------------
class Voz:
    def __init__(self):
        import torch
        from TTS.api import TTS

        self.torch = torch
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        log("cargando XTTS-v2 en", self.device, "(la primera vez descarga ~1.8 GB)")
        tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(self.device)
        self.model = tts.synthesizer.tts_model
        # La "huella" de la voz se calcula una sola vez: cada frase después es rápida.
        self.gpt_latent, self.speaker_emb = self.model.get_conditioning_latents(
            audio_path=[REF], gpt_cond_len=30, max_ref_length=60, sound_norm_refs=False
        )
        self.lock = threading.Lock()
        self.diagnostico()
        t0 = time.time()
        self.decir("Listo.")  # calentamiento
        log(f"voz lista (calentamiento {time.time() - t0:.1f}s)")

    def diagnostico(self):
        t = self.torch
        try:
            dev = next(self.model.parameters()).device
            info = f"torch {t.__version__}, cuda {t.version.cuda}, modelo en {dev}"
            if t.cuda.is_available():
                libre, total = t.cuda.mem_get_info()
                info += f", GPU {t.cuda.get_device_name(0)}, VRAM libre {libre / 2**30:.1f}/{total / 2**30:.1f} GB"
            log("diagnostico:", info)
        except Exception as e:  # noqa: BLE001
            log("diagnostico fallo:", e)

    @staticmethod
    def limpiar(texto):
        t = re.sub(r"\s+", " ", texto).strip()
        # Los puntos suspensivos hacen que XTTS "alargue" o balbucee: se convierten en una pausa con coma.
        t = re.sub(r"\s*(\.{2,}|…)\s*", ", ", t)
        t = re.sub(r",\s*([.!?])", r"\1", t).strip(" ,")
        return t[:600]

    @staticmethod
    def trozos(t, maximo=230):
        # Se corta SOLO al final de cada oración (cortar en comas deja trozos cortos y el modelo
        # rellena con silencios largos). Oraciones muy cortas se unen a la siguiente.
        oraciones = [o for o in re.split(r"(?<=[.!?])\s+", t) if o.strip()]
        partes, actual = [], ""
        for o in oraciones:
            if not actual or len(actual) + len(o) + 1 <= maximo and len(actual) < 60:
                actual = (actual + " " + o).strip()
            else:
                partes.append(actual)
                actual = o
        if actual:
            partes.append(actual)
        final = []
        for p in partes:  # una oración larguísima se parte en una coma cercana al medio
            while len(p) > maximo:
                corte = p.rfind(", ", 0, maximo)
                corte = corte + 1 if corte > 60 else (p.rfind(" ", 0, maximo) if p.rfind(" ", 0, maximo) > 40 else maximo)
                final.append(p[:corte].strip())
                p = p[corte:].strip()
            final.append(p)
        return final

    @staticmethod
    def recortar(w, sr=SR, umbral=0.012, margen=0.06):
        # Quita silencio sobrante al inicio y al final de cada trozo.
        import numpy as np

        v = np.abs(w)
        idx = np.where(v > umbral)[0]
        if not len(idx):
            return w[:0]
        a = max(0, idx[0] - int(sr * margen))
        b = min(len(w), idx[-1] + int(sr * margen * 2))
        return w[a:b]

    def decir(self, texto, llegada=None):
        import numpy as np

        t = self.limpiar(texto)
        if not t:
            return b""
        trozos = []
        with self.lock, self.torch.inference_mode():
            # Si la frase esperó en cola más de 10 s, Jarvis ya contestó con la voz del iPhone: no se genera.
            if llegada and time.time() - llegada > 10:
                return None
            for parte in self.trozos(t):
                # Duración esperada en español: ~0.075 s por carácter. Si sale mucho más larga, el modelo
                # se "alargó" o balbuceó: se regenera con menos variación (hasta 2 intentos más).
                limite = 0.11 * len(parte) + 1.2
                for temp in (0.78, 0.62, 0.5):
                    t1 = time.time()
                    out = self.model.inference(
                        parte, "es", self.gpt_latent, self.speaker_emb,
                        # Expresiva (al estilo Jarvis), con respaldo más estable si se desvía.
                        temperature=temp, length_penalty=1.0, repetition_penalty=4.0 if temp > 0.7 else 6.0,
                        top_k=60, top_p=0.9, speed=1.03, enable_text_splitting=False,
                    )
                    w = out["wav"]
                    log(f"  trozo {len(parte)} letras en {time.time() - t1:.1f}s (temp {temp})")
                    w = w.cpu().numpy() if hasattr(w, "cpu") else np.asarray(w)
                    w = self.recortar(w.astype(np.float32))
                    if len(w) / SR <= limite:
                        break
                    log(f"frase demasiado larga ({len(w) / SR:.1f}s > {limite:.1f}s), regenerando")
                trozos.append(w)
                trozos.append(np.zeros(int(SR * 0.18), dtype=np.float32))  # pausa natural entre oraciones
        audio = np.concatenate(trozos) if trozos else np.zeros(1, dtype=np.float32)
        audio = np.clip(audio, -1, 1)
        pcm = (audio * 32767).astype("<i2").tobytes()
        buf = io.BytesIO()
        with wave.open(buf, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SR)
            wf.writeframes(pcm)
        return buf.getvalue()


# ---------------- servidor HTTP ----------------
def servir(voz, token):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _ok_auth(self):
            return self.headers.get("Authorization", "") == f"Bearer {token}"

        def do_GET(self):
            if self.path == "/health":
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"ok": True, "device": voz.device}).encode())
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            if self.path != "/tts" or not self._ok_auth():
                self.send_response(401)
                self.end_headers()
                return
            n = int(self.headers.get("content-length", "0") or 0)
            try:
                texto = json.loads(self.rfile.read(min(n, 20000)) or b"{}").get("text", "")
                t0 = time.time()
                audio = voz.decir(texto, llegada=t0)
                if audio is None:
                    log(f"frase descartada (esperó demasiado): {texto[:60]}")
                    self.send_response(503)
                    self.end_headers()
                    return
                log(f"frase en {time.time() - t0:.2f}s: {texto[:60]}")
                self.send_response(200)
                self.send_header("content-type", "audio/wav")
                self.send_header("content-length", str(len(audio)))
                self.end_headers()
                self.wfile.write(audio)
            except Exception as e:  # noqa: BLE001
                log("error:", e)
                self.send_response(500)
                self.end_headers()

    srv = ThreadingHTTPServer(("127.0.0.1", PUERTO), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log("servidor de voz en http://127.0.0.1:%d" % PUERTO)


# ---------------- túnel seguro gratuito (Cloudflare) + registro en Jarvis ----------------
def tunel():
    exe = os.path.join(AQUI, "cloudflared.exe" if os.name == "nt" else "cloudflared")
    p = subprocess.Popen(
        [exe, "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{PUERTO}"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        creationflags=0x08000000 if os.name == "nt" else 0,  # sin ventana en Windows
    )
    for linea in p.stdout:
        m = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", linea)
        if m:
            threading.Thread(target=lambda: [None for _ in p.stdout], daemon=True).start()
            return p, m.group(0)
    raise RuntimeError("no se pudo abrir el túnel")


def registrar(jarvis_url, token, url_publica):
    datos = json.dumps({"url": url_publica}).encode()
    req = request.Request(
        jarvis_url.rstrip("/") + "/voice/register", data=datos, method="POST",
        headers={"content-type": "application/json", "Authorization": f"Bearer {token}"},
    )
    with request.urlopen(req, timeout=90) as r:  # 90 s: Render gratis puede estar despertando
        return r.status


def modo_servidor():
    cfg = cargar_config()
    jarvis, token = cfg.get("JARVIS_URL", ""), cfg.get("JARVIS_TOKEN", "")
    if not jarvis or len(token) < 16:
        sys.exit("Falta JARVIS_URL o JARVIS_TOKEN en config.txt")
    voz = Voz()
    servir(voz, token)
    while True:
        proc, url = tunel()
        log("túnel:", url)
        while proc.poll() is None:
            try:
                registrar(jarvis, token, url)
                log("registrada en Jarvis")
            except Exception as e:  # noqa: BLE001
                log("no pude registrar (reintento en 1 min):", e)
                time.sleep(60)
                continue
            for _ in range(60):  # re-registro cada 5 min (Render gratis olvida al dormirse)
                if proc.poll() is not None:
                    break
                time.sleep(5)
        log("el túnel se cerró; abriendo otro")
        time.sleep(3)


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "--muestra":
        v = Voz()
        for i, texto in enumerate(sys.argv[3:]):
            t0 = time.time()
            datos = v.decir(texto)
            ruta = sys.argv[2] if len(sys.argv) == 4 else sys.argv[2].replace(".wav", f"_{i + 1}.wav")
            open(ruta, "wb").write(datos)
            log(f"{ruta}: {time.time() - t0:.1f}s")
    elif len(sys.argv) >= 2 and sys.argv[1] == "--servidor":
        modo_servidor()
    else:
        print(__doc__)

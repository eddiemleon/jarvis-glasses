"""
Muestras de la voz de Jarvis con 3 emociones (XTTS-v2, uso personal no comercial), para aprobarlas antes de usarlas.
Corre en la PC con la voz ya instalada. Resultado: Descargas\\Jarvis\\muestras\\*.wav
"""
import os
import re
import sys
import time
import wave
from pathlib import Path

AQUI = Path(__file__).resolve().parent
sys.path.insert(0, str(AQUI))
os.environ.setdefault("COQUI_TOS_AGREED", "1")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
SALIDA = Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Downloads" / "Jarvis" / "muestras"
SR = 24000

# (nombre, texto, temperatura, velocidad): cada emoción con su propio "carácter".
MUESTRAS = [
    ("1_calida", "Bienvenido de vuelta, señor Leon. Lo extrañaba, bueno, tanto como puede extrañar una inteligencia artificial. ¿En qué trabajamos hoy?", 0.75, 1.00),
    ("2_entusiasta", "¡Excelente, señor! El oro tocó su objetivo. Ganancia asegurada, y sin despeinarse. Debo admitir que estoy impresionado.", 0.85, 1.05),
    ("3_seria", "Señor, con todo respeto, ese stop está demasiado cerca. Le recomiendo cautela. No me gustaría verlo perder lo que tanto le ha costado.", 0.65, 0.96),
]


def acortar_pausas(w, umbral=0.012, maximo=0.32):
    """Deja cualquier silencio interno en máximo 0.32 s (sin cortar la voz)."""
    import numpy as np

    v = np.abs(w) > umbral
    ven = int(SR * 0.02)
    act = np.convolve(v.astype(np.float32), np.ones(ven), "same") > 0
    out, i, n = [], 0, len(w)
    while i < n:
        j = i
        while j < n and act[j] == act[i]:
            j += 1
        seg = w[i:j]
        if not act[i] and (j - i) > SR * maximo:
            seg = seg[: int(SR * maximo)]
        out.append(seg)
        i = j
    return np.concatenate(out) if out else w


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def main():
    import numpy as np
    import torch
    from TTS.api import TTS
    from voz_jarvis import Voz  # se reutilizan limpieza, cortes y recorte de silencios

    SALIDA.mkdir(parents=True, exist_ok=True)
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    log("cargando XTTS-v2 en", dev)
    model = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(dev).synthesizer.tts_model
    # Huella de voz con TODO el audio de referencia: más parecido y más matices.
    lat, emb = model.get_conditioning_latents(audio_path=[str(AQUI / "referencia.wav")], gpt_cond_len=30,
                                              gpt_cond_chunk_len=6, max_ref_length=60, sound_norm_refs=False)
    for nombre, texto, temp, vel in MUESTRAS:
        t0 = time.time()
        trozos = []
        with torch.inference_mode():
            # Una oración a la vez: XTTS "balbucea" o rellena con silencios cuando junta oraciones cortas.
            for parte in [o for o in re.split(r"(?<=[.!?])\s+", Voz.limpiar(texto)) if o.strip()]:
                esperado = 0.068 * len(parte) / vel + 0.4
                candidatos = []
                for t in (temp, temp, max(0.5, temp - 0.12)):
                    o = model.inference(parte, "es", lat, emb, temperature=t, length_penalty=1.0,
                                        repetition_penalty=4.0 if t > 0.7 else 6.0, top_k=60, top_p=0.9,
                                        speed=vel, enable_text_splitting=False)["wav"]
                    o = o.cpu().numpy() if hasattr(o, "cpu") else np.asarray(o)
                    o = acortar_pausas(Voz.recortar(o.astype(np.float32)))
                    dur = len(o) / SR
                    candidatos.append((abs(dur - esperado) / esperado, o))
                    if 0.75 * esperado <= dur <= 1.3 * esperado:
                        break
                    log(f"  {nombre}: '{parte[:30]}' duró {dur:.1f}s (esperado {esperado:.1f}s), repitiendo")
                mejor = min(candidatos, key=lambda c: c[0])[1]
                trozos += [mejor, np.zeros(int(SR * 0.28), dtype=np.float32)]
        a = np.concatenate(trozos)
        # Volumen parejo y algo de presencia: nivel RMS fijo y picos limitados.
        rms = float(np.sqrt(np.mean(a ** 2)) + 1e-9)
        a = np.tanh(a * (0.1 / rms) * 1.1) / 1.1
        f = np.minimum(1, np.arange(len(a)) / (SR * 0.01))
        a = a * f * f[::-1]
        ruta = SALIDA / f"jarvis_{nombre}.wav"
        with wave.open(str(ruta), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes((np.clip(a, -1, 1) * 32767).astype("<i2").tobytes())
        log(f"{ruta.name}: {len(a) / SR:.1f}s de audio en {time.time() - t0:.0f}s")
    log("LISTO")


if __name__ == "__main__":
    try:
        main()
        msg = "Muestras listas. Escriba a Claude: 'muestras listas'."
    except Exception as e:  # noqa: BLE001
        log("ERROR:", repr(e))
        msg = f"Fallo al generar las muestras: {e}"
    try:
        import ctypes
        ctypes.windll.user32.MessageBoxW(0, msg, "Jarvis - voz", 0x40)
    except Exception:
        pass

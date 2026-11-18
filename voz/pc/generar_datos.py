"""Genera el conjunto de entrenamiento con la voz clonada de Jarvis (XTTS-v2, uso personal no comercial).
Salida: datos/wavs/*.wav (22050 Hz) + datos/metadata.csv. Se puede interrumpir y reanudar."""
import os, re, sys, time, wave
from pathlib import Path
import numpy as np

AQUI = Path(__file__).resolve().parent
sys.path.insert(0, str(AQUI))
os.environ.setdefault("COQUI_TOS_AGREED", "1")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
from muestras_emocion import acortar_pausas  # noqa: E402
from voz_jarvis import Voz  # noqa: E402

SR, SR_OUT = 24000, 22050
DATOS = AQUI / "datos"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 620
ARCHIVOS = sys.argv[2].split(",") if len(sys.argv) > 2 else ["jarvis_frases.txt", "frases_corpus.txt"]
PREFIJO = sys.argv[3] if len(sys.argv) > 3 else "c"


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def main():
    import torch, librosa
    from TTS.api import TTS
    frases = [l.strip() for f in ARCHIVOS
              for l in (AQUI / f).read_text(encoding="utf-8").splitlines() if l.strip()][:N]
    (DATOS / "wavs").mkdir(parents=True, exist_ok=True)
    meta = DATOS / "metadata.csv"
    hechas = {l.split("|", 1)[0] for l in meta.read_text(encoding="utf-8").splitlines()} if meta.exists() else set()
    pend = [(i, t) for i, t in enumerate(frases) if f"{PREFIJO}{i:04d}.wav" not in hechas]
    log(f"frases {len(frases)}, faltan {len(pend)}")
    if not pend:
        return
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    model = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(dev).synthesizer.tts_model
    lat, emb = model.get_conditioning_latents(audio_path=[str(AQUI / "referencia.wav")], gpt_cond_len=30,
                                              gpt_cond_chunk_len=6, max_ref_length=60, sound_norm_refs=False)
    t0, total = time.time(), 0.0
    with open(meta, "a", encoding="utf-8") as f, torch.inference_mode():
        for k, (i, t) in enumerate(pend):
            texto = Voz.limpiar(t)
            # tono según la frase: exclamación = entusiasta, pregunta/neutra = cálida
            temp, vel = (0.82, 1.04) if "!" in texto else (0.74, 1.0)
            esperado = 0.068 * len(texto) / vel + 0.4
            mejor = None
            for intento in range(3):
                o = model.inference(texto, "es", lat, emb, temperature=temp if intento < 2 else 0.6, length_penalty=1.0,
                                    repetition_penalty=5.0, top_k=60, top_p=0.88, speed=vel,
                                    enable_text_splitting=False)["wav"]
                o = o.cpu().numpy() if hasattr(o, "cpu") else np.asarray(o)
                o = acortar_pausas(Voz.recortar(o.astype(np.float32)))
                d = len(o) / SR
                err = abs(d - esperado) / esperado
                if mejor is None or err < mejor[0]:
                    mejor = (err, o)
                if 0.75 <= d / esperado <= 1.3:
                    break
            if mejor[0] > 0.45:  # ninguna toma salió natural: se descarta (mejor sin ella que enseñar balbuceos)
                log("descartada:", t[:50]); continue
            w = librosa.resample(mejor[1], orig_sr=SR, target_sr=SR_OUT)
            w = np.clip(w / max(1e-6, float(np.abs(w).max())) * 0.9, -1, 1)
            nombre = f"{PREFIJO}{i:04d}.wav"
            with wave.open(str(DATOS / "wavs" / nombre), "wb") as wf:
                wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(SR_OUT)
                wf.writeframes((w * 32767).astype("<i2").tobytes())
            f.write(f"{nombre}|{t}\n"); f.flush()
            total += len(w) / SR_OUT
            if k % 20 == 0:
                log(f"{k + 1}/{len(pend)}  audio {total / 60:.1f} min  ({time.time() - t0:.0f}s)")
    log(f"LISTO datos: {total / 60:.1f} min nuevos")


if __name__ == "__main__":
    main()

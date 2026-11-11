"""
Voz de Jarvis para el iPhone (sin servidor): entrena un modelo Piper compacto con la voz clonada.

  1. Genera frases con la voz de referencia (XTTS-v2, uso personal no comercial).
  2. Afina un modelo Piper en español con esas frases.
  3. Lo exporta a ONNX listo para el iPhone (sherpa-onnx): modelo + tokens + datos de pronunciación.

Uso:
  python entrenar.py --salida OUT [--frases 520] [--horas 9.5] [--epocas 1400] [--prueba]
--prueba: versión mínima para validar todo el camino en una máquina sin GPU (pocos clips, 1 época).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import wave
from pathlib import Path

AQUI = Path(__file__).resolve().parent
PIPER_COMMIT = "10880972db9e0aca101fed350eadf8f49deefe9f"
SHERPA_ESPEAK = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/espeak-ng-data.tar.bz2"
SR = 22050


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def run(cmd, **kw):
    log("$", " ".join(map(str, cmd))[:300])
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def frases(n):
    j = (AQUI / "jarvis_frases.txt").read_text(encoding="utf-8").splitlines()
    c = (AQUI / "frases_corpus.txt").read_text(encoding="utf-8").splitlines()
    todas = [f.strip() for f in j + c if f.strip()]
    return todas[:n]


# ---------------- 1. datos con la voz clonada ----------------
def generar(out, n, prueba):
    import numpy as np
    import torch
    import librosa

    wavs = out / "wavs"
    wavs.mkdir(parents=True, exist_ok=True)
    meta = out / "metadata.csv"
    hechas = {}
    if meta.exists():
        for l in meta.read_text(encoding="utf-8").splitlines():
            a, t = l.split("|", 1)
            hechas[a] = t
    lista = frases(n)
    pendientes = [(i, t) for i, t in enumerate(lista) if f"c{i:04d}.wav" not in hechas]
    log(f"frases: {len(lista)} (faltan {len(pendientes)})")
    if not pendientes:
        return meta
    os.environ.setdefault("COQUI_TOS_AGREED", "1")
    from TTS.api import TTS

    dev = "cuda" if torch.cuda.is_available() else "cpu"
    model = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(dev).synthesizer.tts_model
    ref = AQUI / "referencia.wav"
    if not ref.exists():
        ref = AQUI.parent / "referencia.wav"
    lat, emb = model.get_conditioning_latents(audio_path=[str(ref)], gpt_cond_len=30, max_ref_length=60, sound_norm_refs=False)
    t0 = time.time()
    with open(meta, "a", encoding="utf-8") as f, torch.inference_mode():
        for k, (i, t) in enumerate(pendientes):
            limite = 0.11 * len(t) + 1.2
            w = None
            for temp in (0.7, 0.55, 0.45):
                o = model.inference(t, "es", lat, emb, temperature=temp, length_penalty=1.0, repetition_penalty=5.0,
                                    top_k=50, top_p=0.85, speed=1.0, enable_text_splitting=False)["wav"]
                o = o.cpu().numpy() if hasattr(o, "cpu") else np.asarray(o)
                o = o.astype(np.float32)
                idx = np.where(np.abs(o) > 0.012)[0]
                if not len(idx):
                    continue
                o = o[max(0, idx[0] - 1200): idx[-1] + 2400]
                if len(o) / 24000 <= limite:
                    w = o
                    break
            if w is None:
                log("descartada:", t[:60])
                continue
            w = librosa.resample(w, orig_sr=24000, target_sr=SR)
            w = np.clip(w / max(1e-6, np.abs(w).max()) * 0.9, -1, 1)
            nombre = f"c{i:04d}.wav"
            with wave.open(str(wavs / nombre), "wb") as wf:
                wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(SR)
                wf.writeframes((w * 32767).astype("<i2").tobytes())
            f.write(f"{nombre}|{t}\n"); f.flush()
            if k % 25 == 0:
                log(f"  {k + 1}/{len(pendientes)} ({time.time() - t0:.0f}s)")
    del model
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    return meta


# ---------------- 2. Piper ----------------
def instalar_piper(base):
    src = base / "piper1-gpl"
    if not (src / "src" / "piper" / "train").exists():
        run(["git", "clone", "-q", "https://github.com/OHF-Voice/piper1-gpl", src])
        run(["git", "-C", src, "checkout", "-q", PIPER_COMMIT])
    # Sin medidor MOS (no se usa): se quita su guardado, que si no detiene el entrenamiento.
    import re as _re
    mp = src / "src" / "piper" / "train" / "__main__.py"
    txt = mp.read_text(encoding="utf-8")
    txt2 = _re.sub(r'        ModelCheckpoint\(\n            monitor="val_mos",.*?\n        \),\n', "", txt, flags=_re.S)
    if txt2 != txt:
        mp.write_text(txt2, encoding="utf-8")
    try:
        import piper.train  # noqa: F401
        from piper.train.vits import monotonic_align  # noqa: F401
        return src
    except Exception:
        pass
    run([sys.executable, "-m", "pip", "install", "-q", "scikit-build<1", "cmake", "ninja", "cython>=3,<4"])
    run([sys.executable, "-m", "pip", "install", "-q", "-e", f"{src}[train]"])
    run([sys.executable, "setup.py", "build_ext", "--inplace"], cwd=src)
    # Extensión de alineación (Cython) que el entrenamiento necesita: ver build_monotonic_align.sh de Piper.
    ma = src / "src" / "piper" / "train" / "vits" / "monotonic_align"
    (ma / "monotonic_align").mkdir(exist_ok=True)
    run([sys.executable, "-m", "cython", "-3", "core.pyx"], cwd=ma)
    run([sys.executable, "-c", "from setuptools import setup, Extension; import numpy; "
         "setup(ext_modules=[Extension('core', ['core.c'], include_dirs=[numpy.get_include()])], script_args=['build_ext', '--inplace'])"], cwd=ma)
    for so in ma.glob("core*.so"):
        shutil.move(str(so), ma / "monotonic_align" / so.name)
    for so in ma.glob("core*.pyd"):
        shutil.move(str(so), ma / "monotonic_align" / so.name)
    return src


def checkpoint_es(base):
    from huggingface_hub import hf_hub_download, list_repo_files

    archivos = list_repo_files("rhasspy/piper-checkpoints", repo_type="dataset")
    cands = [f for f in archivos if f.endswith(".ckpt") and "/medium/" in f and f.startswith("es/")]
    cands.sort(key=lambda f: (0 if "davefx" in f else 1 if "es_MX" in f else 2, f))
    log("checkpoints en español:", cands[:4])
    if not cands:
        raise SystemExit("no encontré un checkpoint medium en español")
    return Path(hf_hub_download("rhasspy/piper-checkpoints", cands[0], repo_type="dataset", cache_dir=str(base / "hf")))


def duracion(horas):
    m = int(horas * 60)
    return f"{m // 1440:02d}:{m // 60 % 24:02d}:{m % 60:02d}:00"


def entrenar(out, meta, ck, horas, epocas, prueba):
    import torch

    gpu = torch.cuda.is_available()
    lote = 4 if prueba else (24 if gpu else 8)
    raiz = out / "entreno"
    cmd = [sys.executable, "-m", "piper.train", "fit",
           "--data.voice_name", "jarvis",
           "--data.csv_path", meta, "--data.audio_dir", out / "wavs",
           "--model.sample_rate", SR, "--data.espeak_voice", "es",
           "--data.cache_dir", out / "cache", "--data.config_path", out / "config.json",
           "--data.batch_size", lote, "--data.num_test_examples", 2 if prueba else 5,
           "--data.validation_split", 0.1 if prueba else 0.05,
           "--model.mos_metric", "none",
           "--model.warmstart_ckpt", ck,
           "--trainer.max_epochs", epocas,
           "--trainer.max_time", duracion(horas),
           "--trainer.accelerator", "gpu" if gpu else "cpu",
           "--trainer.devices", 1,
           "--trainer.default_root_dir", raiz]
    if gpu:
        cmd += ["--trainer.precision", "32"]
    run(cmd)
    ult = sorted(raiz.glob("lightning_logs/version_*/checkpoints/last.ckpt"), key=os.path.getmtime)
    if not ult:
        raise SystemExit("el entrenamiento no dejó checkpoint")
    return ult[-1]


# ---------------- 3. exportar para el iPhone ----------------
def exportar(out, ck):
    import onnx

    final = out / "jarvis-voz"
    final.mkdir(exist_ok=True)
    modelo = final / "jarvis.onnx"
    run([sys.executable, "-m", "piper.train.export_onnx", "--checkpoint", ck, "--output-file", modelo])
    cfg = json.loads((out / "config.json").read_text(encoding="utf-8"))
    shutil.copy(out / "config.json", final / "jarvis.onnx.json")
    with open(final / "tokens.txt", "w", encoding="utf-8") as f:
        for s, ids in cfg["phoneme_id_map"].items():
            f.write(f"{s} {ids[0]}\n")
    m = onnx.load(str(modelo))
    meta = {"model_type": "vits", "comment": "piper", "language": "Spanish", "voice": cfg["espeak"]["voice"],
            "has_espeak": 1, "n_speakers": cfg.get("num_speakers", 1), "sample_rate": cfg["audio"]["sample_rate"]}
    for k, v in meta.items():
        p = m.metadata_props.add(); p.key = k; p.value = str(v)
    onnx.save(m, str(modelo))
    if not (final / "espeak-ng-data").exists():
        tb = out / "espeak.tar.bz2"
        urllib.request.urlretrieve(SHERPA_ESPEAK, tb)
        with tarfile.open(tb) as t:
            t.extractall(final)
    log("modelo para el iPhone:", final, f"{modelo.stat().st_size / 1e6:.1f} MB")
    return final


def probar(final, out):
    import sherpa_onnx
    import numpy as np

    cfg = sherpa_onnx.OfflineTtsConfig(model=sherpa_onnx.OfflineTtsModelConfig(
        vits=sherpa_onnx.OfflineTtsVitsModelConfig(model=str(final / "jarvis.onnx"), tokens=str(final / "tokens.txt"),
                                                   data_dir=str(final / "espeak-ng-data")),
        num_threads=2))
    tts = sherpa_onnx.OfflineTts(cfg)
    res = []
    for i, t in enumerate(["Bienvenido de vuelta, señor Leon.",
                           "Hoy la máxima llega a unos ochenta y ocho grados. ¿Desea que le recuerde llevar paraguas?",
                           "Gire a la derecha en doscientos metros y continúe recto."]):
        t0 = time.time()
        a = tts.generate(t, sid=0, speed=1.0)
        dt = time.time() - t0
        dur = len(a.samples) / a.sample_rate
        res.append((t, dt, dur))
        s = np.clip(np.asarray(a.samples), -1, 1)
        with wave.open(str(out / f"prueba_iphone_{i + 1}.wav"), "wb") as wf:
            wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(a.sample_rate)
            wf.writeframes((s * 32767).astype("<i2").tobytes())
        log(f"prueba {i + 1}: {dur:.1f}s de audio en {dt:.2f}s")
    assert all(d > 0.5 for _, _, d in res), "el modelo no generó audio"
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--salida", required=True)
    ap.add_argument("--frases", type=int, default=520)
    ap.add_argument("--horas", type=float, default=9.5)
    ap.add_argument("--epocas", type=int, default=1400)
    ap.add_argument("--prueba", action="store_true")
    a = ap.parse_args()
    out = Path(a.salida).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if a.prueba:
        a.frases, a.epocas, a.horas = min(a.frases, 12), 1, 1.0
    meta = generar(out, a.frases, a.prueba)
    n = len(meta.read_text(encoding="utf-8").splitlines())
    log(f"clips listos: {n}")
    instalar_piper(out)
    ck = checkpoint_es(out)
    ult = entrenar(out, meta, ck, a.horas, a.epocas, a.prueba)
    final = exportar(out, ult)
    probar(final, out)
    shutil.make_archive(str(out / "jarvis-voz"), "zip", final)
    log("LISTO:", out / "jarvis-voz.zip")


if __name__ == "__main__":
    main()

"""Entrena la voz de Jarvis (Piper) en esta PC y la exporta para el iPhone (sherpa-onnx).
python entrenar_voz.py prueba   -> 1 época con pocos datos (verifica todo el camino)
python entrenar_voz.py completo -> entrenamiento de la noche (tiempo máximo en HORAS)"""
import json, os, shutil, subprocess, sys, tarfile, time, urllib.request
from pathlib import Path

AQUI = Path(__file__).resolve().parent
DATOS = AQUI / "datos"
TRAB = AQUI / "trabajo"
MODO = sys.argv[1] if len(sys.argv) > 1 else "prueba"
HORAS = float(os.environ.get("HORAS", "8"))
PY = sys.executable


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def checkpoint():
    from huggingface_hub import hf_hub_download, list_repo_files
    fs = [f for f in list_repo_files("rhasspy/piper-checkpoints", repo_type="dataset")
          if f.endswith(".ckpt") and f.startswith("es/") and "/medium/" in f]
    fs.sort(key=lambda f: (0 if "davefx" in f else 1 if "es_MX" in f else 2, f))
    log("checkpoint base:", fs[0])
    return hf_hub_download("rhasspy/piper-checkpoints", fs[0], repo_type="dataset", cache_dir=str(AQUI / "hf"))


def entrenar():
    raiz = TRAB / MODO
    if MODO == "prueba" and raiz.exists():
        shutil.rmtree(raiz)
    raiz.mkdir(parents=True, exist_ok=True)
    meta = DATOS / "metadata.csv"
    n = len(meta.read_text(encoding="utf-8").splitlines())
    prueba = MODO == "prueba"
    ultimo = sorted(raiz.glob("lightning_logs/version_*/checkpoints/last.ckpt"), key=os.path.getmtime)
    m = int(HORAS * 60)
    cmd = [PY, "-m", "piper.train", "fit",
           "--data.voice_name", "jarvis", "--data.csv_path", str(meta), "--data.audio_dir", str(DATOS / "wavs"),
           "--model.sample_rate", "22050", "--data.espeak_voice", "es",
           "--data.cache_dir", str(raiz / "cache"), "--data.config_path", str(raiz / "config.json"),
           "--data.batch_size", "2" if prueba else "12",
           "--data.num_test_examples", "1" if prueba else "4",
           "--data.validation_split", "0.34" if prueba else "0.04",
           "--model.mos_metric", "none",
           "--trainer.max_epochs", "1" if prueba else "3000",
           "--trainer.max_time", f"{m // 1440:02d}:{m // 60 % 24:02d}:{m % 60:02d}:00",
           "--trainer.accelerator", "gpu", "--trainer.devices", "1", "--trainer.precision", "32",
           "--trainer.check_val_every_n_epoch", "1" if prueba else "10",
           "--trainer.default_root_dir", str(raiz)]
    if ultimo and not prueba:
        cmd += ["--ckpt_path", str(ultimo[-1])]  # reanuda si se cortó
    else:
        cmd += ["--model.warmstart_ckpt", checkpoint()]
    log(f"clips: {n}; entrenando ({MODO})")
    subprocess.run(cmd, check=True)
    ult = sorted(raiz.glob("lightning_logs/version_*/checkpoints/last.ckpt"), key=os.path.getmtime)
    return raiz, ult[-1]


def exportar(raiz, ck):
    import onnx
    out = TRAB / f"jarvis-voz-{MODO}"
    out.mkdir(parents=True, exist_ok=True)
    modelo = out / "jarvis.onnx"
    subprocess.run([PY, "-m", "piper.train.export_onnx", "--checkpoint", str(ck), "--output-file", str(modelo)], check=True)
    cfg = json.loads((raiz / "config.json").read_text(encoding="utf-8"))
    # sherpa-onnx lee un símbolo por línea (un solo carácter) y fin de línea Unix; los diptongos
    # de Piper solo se usan con vowel_clusters (apagado), así que se omiten.
    with open(out / "tokens.txt", "w", encoding="utf-8", newline="\n") as f:
        for s, ids in cfg["phoneme_id_map"].items():
            if len(s) == 1:
                f.write(f"{s} {ids[0]}\n")
    m = onnx.load(str(modelo))
    for k, v in {"model_type": "vits", "comment": "piper", "language": "Spanish", "voice": cfg["espeak"]["voice"],
                 "has_espeak": 1, "n_speakers": cfg.get("num_speakers", 1), "sample_rate": cfg["audio"]["sample_rate"]}.items():
        p = m.metadata_props.add(); p.key = k; p.value = str(v)
    onnx.save(m, str(modelo))
    if not (out / "espeak-ng-data").exists():
        tb = TRAB / "espeak.tar.bz2"
        if not tb.exists():
            urllib.request.urlretrieve("https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/espeak-ng-data.tar.bz2", tb)
        with tarfile.open(tb) as t:
            t.extractall(out)
    log(f"modelo: {modelo.stat().st_size / 1e6:.1f} MB")
    return out


def probar(out):
    import numpy as np, sherpa_onnx, wave
    tts = sherpa_onnx.OfflineTts(sherpa_onnx.OfflineTtsConfig(model=sherpa_onnx.OfflineTtsModelConfig(
        vits=sherpa_onnx.OfflineTtsVitsModelConfig(model=str(out / "jarvis.onnx"), tokens=str(out / "tokens.txt"),
                                                   data_dir=str(out / "espeak-ng-data")), num_threads=2)))
    for i, t in enumerate(["Bienvenido de vuelta, señor Leon.",
                           "¡Excelente, señor! El oro tocó su objetivo.",
                           "Señor, con todo respeto, ese stop está demasiado cerca."]):
        t0 = time.time(); a = tts.generate(t, sid=0, speed=1.0); dt = time.time() - t0
        s = np.clip(np.asarray(a.samples), -1, 1)
        with wave.open(str(out.parent / f"prueba_{MODO}_{i + 1}.wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(a.sample_rate)
            w.writeframes((s * 32767).astype("<i2").tobytes())
        log(f"prueba {i + 1}: {len(s) / a.sample_rate:.1f}s de audio en {dt:.2f}s")
    shutil.make_archive(str(TRAB / f"jarvis-voz-{MODO}"), "zip", out)
    log("LISTO", TRAB / f"jarvis-voz-{MODO}.zip")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "solo-exportar":
        raiz = TRAB / MODO
        ck = sorted(raiz.glob("lightning_logs/version_*/checkpoints/last.ckpt"), key=os.path.getmtime)[-1]
        probar(exportar(raiz, ck)); sys.exit(0)
    raiz, ck = entrenar()
    probar(exportar(raiz, ck))

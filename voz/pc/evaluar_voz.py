"""Busca la versión MÁS NATURAL de la voz de Jarvis sin reentrenar: prueba varios checkpoints y ajustes del
motor del iPhone (sherpa-onnx) y los califica con UTMOS (naturalidad, 1-5) y Whisper (que diga bien el texto).
Resultado: trabajo/eval/ranking.txt y los mejores audios en Descargas/Jarvis/pruebas_voz."""
import json, os, shutil, subprocess, sys, time, wave
from pathlib import Path
import numpy as np, torch

AQUI = Path(__file__).resolve().parent
TRAB = AQUI / "trabajo"
EVAL = TRAB / "eval"
SALIDA = Path(os.environ["USERPROFILE"]) / "Downloads" / "Jarvis" / "pruebas_voz"
CK = TRAB / "completo"
FRASES = [
    "Buenos días, señor Leon. Son las seis y media y el día está despejado.",
    "¡Excelente noticia, señor! La operación cerró en ganancia.",
    "Cuidado, señor. Hay tráfico pesado a dos kilómetros.",
    "Le recuerdo que tiene una reunión a las tres de la tarde. ¿Quiere que le avise media hora antes?",
]
AJUSTES = {  # nombre: (noise_scale, noise_scale_w, length_scale)
    "estandar": (0.667, 0.8, 1.0),
    "estable": (0.5, 0.6, 1.0),
    "expresiva": (0.75, 0.95, 1.0),
    "expresiva_agil": (0.75, 0.95, 0.94),
    "suave": (0.6, 0.85, 0.97),
}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def exportar(ck, nombre):
    out = EVAL / nombre
    if (out / "jarvis.onnx").exists():
        return out
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, "-m", "piper.train.export_onnx", "--checkpoint", str(ck), "--output-file",
                    str(out / "jarvis.onnx")], check=True, capture_output=True)
    import onnx
    cfg = json.loads((CK / "config.json").read_text(encoding="utf-8"))
    with open(out / "tokens.txt", "w", encoding="utf-8", newline="\n") as f:
        for s, ids in cfg["phoneme_id_map"].items():
            if len(s) == 1:
                f.write(f"{s} {ids[0]}\n")
    m = onnx.load(str(out / "jarvis.onnx"))
    for k, v in {"model_type": "vits", "comment": "piper", "language": "Spanish", "voice": cfg["espeak"]["voice"],
                 "has_espeak": 1, "n_speakers": 1, "sample_rate": cfg["audio"]["sample_rate"]}.items():
        p = m.metadata_props.add(); p.key = k; p.value = str(v)
    onnx.save(m, str(out / "jarvis.onnx"))
    return out


def main():
    import sherpa_onnx
    from faster_whisper import WhisperModel
    sys.path.insert(0, str(AQUI))
    from filtrar import wer
    utmos = torch.hub.load("tarepan/SpeechMOS:v1.2.0", "utmos22_strong", trust_repo=True).eval()
    asr = WhisperModel("small", device="cpu", compute_type="int8", cpu_threads=4)
    espeak = TRAB / "jarvis-voz-completo" / "espeak-ng-data"
    cks = {"final": next(CK.glob("lightning_logs/version_*/checkpoints/last.ckpt"))}
    for c in sorted(CK.glob("lightning_logs/version_*/checkpoints/epoch=*.ckpt")):
        ep = int(c.name.split("=")[1].split("-")[0])
        if ep in (369, 749):
            cks[f"epoca{ep}"] = c
    resultados = []
    EVAL.mkdir(parents=True, exist_ok=True)
    for nck, ck in cks.items():
        d = exportar(ck, nck)
        log("modelo", nck)
        for naj, (ns, nsw, ls) in AJUSTES.items():
            tts = sherpa_onnx.OfflineTts(sherpa_onnx.OfflineTtsConfig(model=sherpa_onnx.OfflineTtsModelConfig(
                vits=sherpa_onnx.OfflineTtsVitsModelConfig(model=str(d / "jarvis.onnx"), tokens=str(d / "tokens.txt"),
                                                           data_dir=str(espeak), noise_scale=ns, noise_scale_w=nsw,
                                                           length_scale=ls), num_threads=2)))
            moss, wers, audios = [], [], []
            for t in FRASES:
                a = tts.generate(t, sid=0, speed=1.0)
                s = np.asarray(a.samples, dtype=np.float32)
                moss.append(float(utmos(torch.from_numpy(s).unsqueeze(0), a.sample_rate).mean()))
                tmp = EVAL / "tmp.wav"
                with wave.open(str(tmp), "wb") as w:
                    w.setnchannels(1); w.setsampwidth(2); w.setframerate(a.sample_rate)
                    w.writeframes((np.clip(s, -1, 1) * 32767).astype("<i2").tobytes())
                segs, _ = asr.transcribe(str(tmp), language="es", beam_size=1)
                wers.append(wer(t, " ".join(x.text for x in segs)))
                audios.append(s); audios.append(np.zeros(int(a.sample_rate * 0.45), np.float32))
            mos, w_ = float(np.mean(moss)), float(np.mean(wers))
            resultados.append((mos - 2 * w_, mos, w_, nck, naj, np.concatenate(audios), a.sample_rate))
            log(f"  {naj:15s} naturalidad {mos:.2f}  errores {w_:.0%}")
    # referencia: la voz original (XTTS) con la misma escala
    ref = []
    for f in sorted((Path(os.environ["USERPROFILE"]) / "Downloads" / "Jarvis" / "muestras").glob("*.wav")):
        import librosa
        y, sr = librosa.load(str(f), sr=16000)
        ref.append(float(utmos(torch.from_numpy(y).unsqueeze(0), 16000).mean()))
    resultados.sort(key=lambda r: -r[0])
    lines = [f"Voz original XTTS (referencia): naturalidad {np.mean(ref):.2f}" if ref else "sin referencia"]
    lines += [f"{i + 1}. {r[3]} + {r[4]}: naturalidad {r[1]:.2f}, errores {r[2]:.0%}" for i, r in enumerate(resultados)]
    (EVAL / "ranking.txt").write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines), flush=True)
    if SALIDA.exists():
        shutil.rmtree(SALIDA)
    SALIDA.mkdir(parents=True)
    for i, r in enumerate(resultados[:4]):
        with wave.open(str(SALIDA / f"opcion_{i + 1}_{r[3]}_{r[4]}.wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(r[6])
            w.writeframes((np.clip(r[5], -1, 1) * 32767).astype("<i2").tobytes())
    json.dump([{"modelo": r[3], "ajuste": r[4], "parametros": AJUSTES[r[4]], "naturalidad": r[1], "errores": r[2]}
               for r in resultados], open(EVAL / "ranking.json", "w"), indent=1)
    log("LISTO")


if __name__ == "__main__":
    main()

"""Revisa cada clip con reconocimiento de voz (Whisper) y descarta los que no dicen exactamente su texto
(balbuceos, palabras repetidas o cortadas). Escribe datos/metadata_limpio.csv."""
import re, time, unicodedata
from pathlib import Path

AQUI = Path(__file__).resolve().parent
DATOS = AQUI / "datos"


def norm(t):
    t = unicodedata.normalize("NFD", t.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9 ]+", " ", t).split()


NUMS = set("cero uno una dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince dieciseis diecisiete dieciocho diecinueve veinte veintitres treinta cuarenta cincuenta sesenta setenta ochenta noventa cien ciento doscientos cuatrocientos seiscientos mil coma y por media cuarto punto".split())


def wer(ref, hyp):
    # Whisper escribe los números con cifras: se ignoran números en ambos lados para no castigar eso.
    r = [w for w in norm(ref) if w not in NUMS]
    h = [w for w in norm(hyp) if not w.isdigit() and w not in NUMS]
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r))


def main():
    from faster_whisper import WhisperModel
    m = WhisperModel("small", device="cpu", compute_type="int8", cpu_threads=4)
    filas = [l.split("|", 1) for l in (DATOS / "metadata.csv").read_text(encoding="utf-8").splitlines() if "|" in l]
    buenas, malas, t0 = [], [], time.time()
    for k, (wav, texto) in enumerate(filas):
        segs, _ = m.transcribe(str(DATOS / "wavs" / wav), language="es", beam_size=1, vad_filter=False,
                               condition_on_previous_text=False)
        oido = " ".join(s.text for s in segs)
        e = wer(texto, oido)
        (buenas if e <= 0.2 else malas).append((wav, texto, oido, e))
        if k % 50 == 0:
            print(time.strftime("%H:%M:%S"), f"{k}/{len(filas)} revisados", flush=True)
    (DATOS / "metadata_limpio.csv").write_text("".join(f"{w}|{t}\n" for w, t, _, _ in buenas), encoding="utf-8")
    with open(DATOS / "descartados.txt", "w", encoding="utf-8") as f:
        for w, t, o, e in malas:
            f.write(f"{w} ({e:.0%})\n  texto: {t}\n  oido:  {o.strip()}\n")
    print(time.strftime("%H:%M:%S"), f"FILTRO: {len(buenas)} buenos, {len(malas)} descartados ({time.time() - t0:.0f}s)", flush=True)


if __name__ == "__main__":
    main()

"""Voz 3 de Jarvis: 3 veces más datos y entrenamiento largo, sin pelear la tarjeta de video con otros proyectos.
1) Espera a que la GPU esté libre.  2) ~2400 frases nuevas, naturales y variadas (Tatoeba, español).
3) Las genera con la voz aprobada (XTTS, 3 a la vez, con vigilante).  4) Whisper descarta las imperfectas.
5) Entrena el modelo "alta" partiendo del de la noche 1, con TODO.  6) Exporta, prueba y deja muestras A/B en
   Descargas\\Jarvis\\pruebas_voz3 para que Leon compare antes de instalar nada.
Se ejecuta con el Python del entrenamiento (entreno)."""
import bz2, os, random, re, subprocess, sys, time, urllib.request, shutil
from pathlib import Path

AQUI = Path(__file__).resolve().parent
DATOS = AQUI / "datos"
VENV_XTTS = AQUI / "venv" / "Scripts" / "python.exe"
PY = sys.executable
SALIDA = Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Downloads" / "Jarvis" / "pruebas_voz3"
LOG = AQUI / "noche3.log"
PARTES = [("frases_noche3_a.txt", "f"), ("frases_noche3_b.txt", "g"), ("frases_noche3_c.txt", "h")]


def log(*a):
    linea = " ".join(str(x) for x in (time.strftime("%Y-%m-%d %H:%M:%S"),) + a)
    print(linea, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(linea + "\n")


def gpu():
    try:
        o = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu,memory.used", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=20).stdout.strip().splitlines()[0]
        u, m = [int(x) for x in o.split(",")]
        return u, m
    except Exception:
        return 0, 0


def esperar_gpu_libre():
    """No empieza mientras otro programa use la tarjeta (p. ej. el proyecto Brillando)."""
    libres = 0
    while libres < 3:
        u, m = gpu()
        if u < 15 and m < 3000:
            libres += 1
        else:
            libres = 0
            log(f"GPU ocupada por otro programa (uso {u}%, memoria {m} MB): espero")
        time.sleep(60)
    log("GPU libre: empiezo")


def frases():
    if all((AQUI / f).exists() for f, _ in PARTES):
        return
    tb = AQUI / "spa_sentences.tsv.bz2"
    if not tb.exists():
        log("descargando frases en español (Tatoeba, CC-BY)")
        urllib.request.urlretrieve("https://downloads.tatoeba.org/exports/per_language/spa/spa_sentences.tsv.bz2", tb)
    ya = set()
    for f in ("jarvis_frases.txt", "frases_corpus.txt", "jarvis_extra.txt", "frases_noche2.txt"):
        if (AQUI / f).exists():
            ya |= {l.strip().lower() for l in (AQUI / f).read_text(encoding="utf-8").splitlines()}
    ok = re.compile(r"^[A-ZÁÉÍÓÚÑ¿¡][A-Za-zÁÉÍÓÚÜÑáéíóúüñ ,;:¿?¡!.'-]+[.?!]$")
    cand = []
    with bz2.open(tb, "rt", encoding="utf-8") as f:
        for linea in f:
            p = linea.rstrip("\n").split("\t")
            if len(p) < 3:
                continue
            t = p[2].strip()
            n = len(t.split())
            if 7 <= n <= 24 and ok.match(t) and t.lower() not in ya and "Tom" not in t and "Mary" not in t:
                cand.append(t)
    random.Random(7).shuffle(cand)
    # variedad: preguntas, exclamaciones y afirmaciones mezcladas (como en una conversación real)
    preg = [t for t in cand if t.endswith("?")][:600]
    excl = [t for t in cand if t.endswith("!")][:300]
    afir = [t for t in cand if t.endswith(".")][: 2400 - len(preg) - len(excl)]
    todas = preg + excl + afir
    random.Random(11).shuffle(todas)
    k = len(todas) // 3
    for j, (nombre, _) in enumerate(PARTES):
        trozo = todas[j * k:(j + 1) * k] if j < 2 else todas[2 * k:]
        (AQUI / nombre).write_text("\n".join(trozo) + "\n", encoding="utf-8")
    log(f"frases nuevas: {len(todas)} ({len(preg)} preguntas, {len(excl)} exclamaciones)")


def lineas_meta():
    m = DATOS / "metadata.csv"
    return len(m.read_text(encoding="utf-8").splitlines()) if m.exists() else 0


def generar():
    def lanzar():
        return [subprocess.Popen([str(VENV_XTTS), str(AQUI / "generar_datos.py"), "100000", nombre, pref], cwd=str(AQUI))
                for nombre, pref in PARTES]
    procs, ultimo, visto = lanzar(), lineas_meta(), time.time()
    while any(p.poll() is None for p in procs):
        time.sleep(30)
        n = lineas_meta()
        if n != ultimo:
            ultimo, visto = n, time.time()
        elif time.time() - visto > 540:  # 9 min sin avanzar: se reinician (retoman donde quedaron)
            log("generación trabada: reinicio")
            for p in procs:
                subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], capture_output=True)
            time.sleep(10)
            procs, visto = lanzar(), time.time()
    log(f"generación terminada: {lineas_meta()} clips en total")


def entrenar():
    env = dict(os.environ, HORAS=os.environ.get("HORAS", "10"), SIN_GENERAR="1")
    r = subprocess.run([PY, str(AQUI / "entrenar_voz.py"), "alta"], cwd=str(AQUI), env=env)
    log("entrenamiento terminó con código", r.returncode)


def muestras():
    SALIDA.mkdir(parents=True, exist_ok=True)
    trab = AQUI / "trabajo"
    for i in (1, 2, 3):
        for modo, etiqueta in (("alta", "NUEVA"), ("completo", "anterior")):
            f = trab / f"prueba_{modo}_{i}.wav"
            if f.exists():
                shutil.copy(f, SALIDA / f"{i}_{etiqueta}.wav")
    log("muestras en", SALIDA)


if __name__ == "__main__":
    log("=== voz 3: inicio ===")
    esperar_gpu_libre()
    frases()
    generar()
    esperar_gpu_libre()
    entrenar()
    muestras()
    log("=== voz 3: LISTO ===")
    try:
        import ctypes
        ctypes.windll.user32.MessageBoxW(0, "Voz 3 de Jarvis lista. Escriba a Claude: 'voz 3 lista'.", "Jarvis - voz", 0x40)
    except Exception:
        pass

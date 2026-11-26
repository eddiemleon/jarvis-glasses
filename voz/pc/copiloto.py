"""Copiloto de Jarvis: UN solo chat permanente de Claude Code en esta PC (con la suscripción de Leon).
Recoge lo que Leon dice por las gafas (y la foto de lo que ven) desde el servidor de Jarvis, se lo pasa a Claude
SIEMPRE en el mismo chat (--resume) y devuelve la respuesta para que Jarvis se la lea.
La PC se conecta hacia el servidor: no abre puertos. Solo biblioteca estándar de Python.
Ver el chat completo en la PC:  claude --resume  (sesión guardada en copiloto\\sesion.txt)."""
import base64, json, os, shutil, subprocess, sys, time, urllib.request, urllib.error
from pathlib import Path

AQUI = Path(__file__).resolve().parent
DIR = AQUI / "copiloto"
FOTOS = DIR / "fotos"
SESION = DIR / "sesion.txt"
LOG = DIR / "copiloto.log"
INSTRUCCIONES = (
    "Eres el copiloto personal de Leon. Te habla por voz desde sus gafas Ray-Ban Meta; Jarvis transcribe y te pasa "
    "a veces una foto de lo que él ve (léela con Read). Tu respuesta se la lee Jarvis en voz alta: responde en español, "
    "de usted, en frases habladas, sin markdown, tablas ni listas, y breve (menos de 120 palabras) salvo que pida detalle. "
    "Este es un chat continuo: recuerda todo lo anterior. Puedes buscar en internet. No modifiques archivos de la PC."
)


def log(*a):
    DIR.mkdir(parents=True, exist_ok=True)
    linea = time.strftime("%Y-%m-%d %H:%M:%S ") + " ".join(str(x) for x in a)
    print(linea, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(linea + "\n")


def cfg():
    c = {}
    for l in (AQUI / "config.txt").read_text(encoding="utf-8").splitlines():
        if "=" in l:
            k, v = l.split("=", 1)
            c[k.strip()] = v.strip()
    return c["JARVIS_URL"].rstrip("/"), c["JARVIS_TOKEN"]


def claude_exe():
    p = Path(os.environ.get("USERPROFILE", "")) / ".local" / "bin" / "claude.exe"
    return str(p) if p.exists() else (shutil.which("claude") or "")


def preguntar(texto, foto):
    exe = claude_exe()
    if not exe:
        return "No encuentro Claude Code instalado en la PC."
    prompt = texto if not foto else f"{texto}\n\n[Foto de lo que Leon ve ahora mismo: {foto} — léela con Read]"
    cmd = [exe, "-p", prompt, "--output-format", "json", "--allowedTools", "Read WebSearch WebFetch",
           "--add-dir", str(FOTOS), "--append-system-prompt", INSTRUCCIONES]
    sid = SESION.read_text().strip() if SESION.exists() else ""
    if sid:
        cmd += ["--resume", sid]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="ignore", timeout=600, cwd=str(DIR),
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    try:
        d = json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        if sid:  # la sesión guardada ya no existe: se empieza una nueva (una sola vez)
            log("sesión no válida, se crea una nueva:", (r.stderr or r.stdout)[-300:])
            SESION.unlink(missing_ok=True)
            return preguntar(texto, foto)
        return "El copiloto tuvo un error: " + (r.stderr or r.stdout or "sin salida")[-200:]
    if d.get("session_id"):
        SESION.write_text(d["session_id"])
    return d.get("result") or "Sin respuesta."


def main():
    FOTOS.mkdir(parents=True, exist_ok=True)
    url, tok = cfg()
    h = {"Authorization": f"Bearer {tok}"}
    log("copiloto activo; esperando mensajes de las gafas")
    while True:
        try:
            req = urllib.request.Request(url + "/copiloto/next", headers=h)
            with urllib.request.urlopen(req, timeout=40) as r:
                if r.status == 204:
                    continue
                m = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            log("servidor respondió", e.code); time.sleep(10); continue
        except Exception as e:
            log("sin conexión con el servidor:", e); time.sleep(10); continue
        foto = None
        if m.get("imagen"):
            foto = FOTOS / f"{time.strftime('%Y%m%d_%H%M%S')}.jpg"
            foto.write_bytes(base64.b64decode(m["imagen"]))
        log("Leon:", m.get("texto", "")[:200], "(con foto)" if foto else "")
        t0 = time.time()
        try:
            resp = preguntar(m.get("texto", ""), str(foto) if foto else None)
        except subprocess.TimeoutExpired:
            resp = "El copiloto tardó demasiado en responder."
        log(f"Claude ({time.time() - t0:.0f} s):", resp[:300])
        body = json.dumps({"id": m.get("id"), "texto": resp}).encode("utf-8")
        for _ in range(3):
            try:
                urllib.request.urlopen(urllib.request.Request(url + "/copiloto/reply", data=body, method="POST",
                                                              headers={**h, "Content-Type": "application/json"}), timeout=30)
                break
            except Exception as e:
                log("no pude entregar la respuesta:", e); time.sleep(5)


if __name__ == "__main__":
    main()

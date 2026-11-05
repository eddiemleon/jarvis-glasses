"""Crea jarvis_voz_kaggle.ipynb: un solo archivo con todo adentro (script, frases y voz de referencia)."""
import base64
import json
from pathlib import Path

AQUI = Path(__file__).resolve().parent
archivos = {
    "entrenar.py": AQUI / "entrenar.py",
    "jarvis_frases.txt": AQUI / "jarvis_frases.txt",
    "frases_corpus.txt": AQUI / "frases_corpus.txt",
    "referencia.wav": AQUI.parent / "referencia.wav",
}
b64 = {k: base64.b64encode(v.read_bytes()).decode() for k, v in archivos.items()}

def code(src):
    return {"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [], "source": src}

def md(src):
    return {"cell_type": "markdown", "metadata": {}, "source": src}

celdas = [
    md("# Voz de Jarvis para el iPhone\n"
       "Entrena la voz de Jarvis una sola vez (unas 9-10 horas, solo). Requisitos: **Accelerator: GPU T4** y **Internet: On**.\n"
       "Al terminar, descargue **jarvis-voz.zip** de la pestaña *Output*."),
    code("import base64, os, pathlib\n"
         "d = pathlib.Path('/kaggle/working/voz'); d.mkdir(parents=True, exist_ok=True)\n"
         f"ARCHIVOS = {json.dumps(b64)}\n"
         "for n, c in ARCHIVOS.items():\n"
         "    (d / n).write_bytes(base64.b64decode(c))\n"
         "print(sorted(os.listdir(d)))\n"
         "import torch; print('GPU:', torch.cuda.is_available() and torch.cuda.get_device_name(0))\n"
         "assert torch.cuda.is_available(), 'Active la GPU: Settings > Accelerator > GPU T4'"),
    code("!apt-get install -y -qq build-essential cmake ninja-build > /dev/null\n"
         "!pip install -q coqui-tts six librosa huggingface_hub onnx sherpa-onnx==1.12.40"),
    code("import os; os.environ['COQUI_TOS_AGREED'] = '1'\n"
         "!cd /kaggle/working/voz && python entrenar.py --salida /tmp/salida --frases 520 --horas 9.0 --epocas 1400"),
    code("import shutil, glob\n"
         "shutil.copy('/tmp/salida/jarvis-voz.zip', '/kaggle/working/jarvis-voz.zip')\n"
         "for f in glob.glob('/tmp/salida/prueba_iphone_*.wav'): shutil.copy(f, '/kaggle/working/')\n"
         "shutil.rmtree('/kaggle/working/voz', ignore_errors=True)\n"
         "print('LISTO: descargue jarvis-voz.zip en la pestaña Output')"),
]
nb = {"cells": celdas, "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
                                    "language_info": {"name": "python"},
                                    "kaggle": {"accelerator": "nvidiaTeslaT4", "isInternetEnabled": True, "isGpuEnabled": True}},
      "nbformat": 4, "nbformat_minor": 4}
salida = AQUI / "jarvis_voz_kaggle.ipynb"
salida.write_text(json.dumps(nb, ensure_ascii=False), encoding="utf-8")
print(salida, f"{salida.stat().st_size / 1e6:.1f} MB")

# Jarvis — instalación en 4 pasos (sin Mac, sin terminal)

1. **Servidor (2 min):** sube esta carpeta a tu GitHub → render.com → *New → Blueprint* → elige el repo → pega tu `ANTHROPIC_API_KEY` (y opcional `GEMINI_API_KEY` de respaldo) → Deploy. La contraseña se crea sola.
2. **App (10 min, automático):** en GitHub → pestaña *Actions* → *Build IPA* corre solo al subir; descarga `Jarvis-unsigned.ipa` e instálalo con **Sideloadly** (gratis, Windows/Mac) usando tu Apple ID.
3. **Conectar:** en Render → *Logs* copia el "ENLACE DE CONEXIÓN" y ábrelo en el iPhone → botón **Conectar la app**. Ya no escribes URL ni contraseña.
4. **Gafas:** en la app Meta AI activa *Developer Mode*, abre Jarvis y toca *Conectar gafas*. Di "Jarvis".

**Nuevo:** en Ajustes de iOS → Jarvis, acepte **Calendarios (acceso total)** y **Fotos (agregar)** cuando se lo pida. El servidor se crea en la región **Virginia** (la más cercana a Puerto Rico) para menos retraso en la transmisión.

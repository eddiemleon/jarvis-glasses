# Jarvis — instalación (sin Mac, sin terminal)

La app ya se compila sola en una Mac de GitHub y se prueba con las gafas simuladas oficiales de Meta cada vez que cambia el código.

## 1. Servidor (5 min)
render.com → *New → Blueprint* → elija el repositorio `jarvis-glasses` → pegue su `ANTHROPIC_API_KEY` → *Deploy*.
La contraseña se crea sola. El servidor queda en Virginia (la región más cercana a Puerto Rico).

## 2. App en el iPhone (10 min)
1. Descargue **Jarvis-unsigned.ipa** desde la sección **Releases** del repositorio (a la derecha, "Jarvis - última versión").
2. Instale **Sideloadly** en su PC (sideloadly.io), conecte el iPhone por cable, arrastre el `.ipa`, ponga su Apple ID y pulse *Start*.
3. En el iPhone: *Ajustes → General → VPN y gestión de dispositivos* → confíe en su Apple ID. Active también *Ajustes → Privacidad → Modo desarrollador*.
4. Con un Apple ID gratis la app caduca a los 7 días: Sideloadly la renueva con un clic.

## 3. Conectar la app con el servidor (1 min)
En Render → *Logs*, copie el **ENLACE DE CONEXIÓN**, ábralo en el iPhone y pulse **Conectar la app**.

## 4. Gafas (2 min)
App **Meta AI** → *Ajustes → Tus gafas → Modo desarrollador* (actívelo). Abra Jarvis → *Ajustes* → **Registrar con Meta AI** → **Permiso de cámara**. Diga "Jarvis".

## Con el teléfono bloqueado
Deje Jarvis abierta y bloquee el teléfono: sigue escuchando (verá el punto naranja del micrófono). Ponga la ubicación en **Siempre** y apague el **Modo de bajo consumo**. No cierre la app desde el selector de apps.

Acepte **Calendarios** y **Fotos** cuando se los pida.

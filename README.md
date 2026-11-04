# Jarvis para Ray-Ban Meta Gen 2

Tu asistente tipo Jarvis en las gafas: dices **"Jarvis"** y te atiende por los parlantes de las gafas, con el teléfono bloqueado en el bolsillo.

```
 Gafas (micrófono/cámara/parlantes)
        │ Bluetooth
 App Jarvis en el iPhone  ── escucha "Jarvis" en el propio teléfono, GPS, voz
        │ internet (WebSocket cifrado)
 Servidor Jarvis (tuyo)  ── IA (cerebros configurables), herramientas, alertas TradingView,
        │                    WhatsApp Business, recordatorios, enlace de transmisión en vivo
        └──► navegador de cualquier otro celular/PC (video + audio en vivo)
```

## Qué hace

| Función | Cómo se usa |
|---|---|
| IA conversacional (el cerebro principal se elige solo; los demás entran solos si falla) | "Jarvis, ¿cómo está el oro?" · sigue escuchando 7 s para que continúes sin repetir "Jarvis" |
| Ver lo que ves | "Jarvis, ¿qué es esto?" / "léeme este cartel" (foto desde las gafas → IA) |
| Navegación por voz (GPS del iPhone) | "Jarvis, llévame a Plaza Las Américas" |
| Alertas de TradingView por voz | Webhook de TradingView → el servidor → te lo dice al oído, aunque el teléfono esté bloqueado |
| WhatsApp Business | Te lee los mensajes; "respóndele que llego en 10" → lee el borrador y **solo envía si confirmas** |
| Recordatorios | "Jarvis, recuérdame en 20 minutos revisar el horno" |
| Memoria | "Jarvis, recuerda que mi stop en oro es 8 dólares" |
| **Transmisión en vivo (tipo AirPlay)** | Pestaña **Cámara** → calidad → *Iniciar transmisión* (o "Jarvis, transmite lo que veo") → enlace: cualquier celular o PC ve y oye en tiempo real lo que ven las gafas. Siempre el cuadro más reciente: si la red se atrasa se saltan cuadros, no se acumula retraso |
| **Foto en máxima calidad** | Botón *Foto máxima* o "Jarvis, toma una foto": resolución completa del sensor, se guarda en Fotos del iPhone y, si está transmitiendo, le llega a quien mira (botón Ver/Descargar) |
| **Memoria visual** | "Jarvis, recuerda dónde dejé las llaves" / "dónde estacioné" → foto + lugar + hora. Luego: "¿dónde dejé las llaves?" |
| **Rutinas y briefing** | "Jarvis, de lunes a viernes a las 7 dame el briefing" (agenda, recordatorios, alertas, WhatsApp, oro, clima) o cualquier tarea a una hora fija |
| **Calendario del iPhone** | "¿Qué tengo hoy?" · "Agéndame dentista el jueves a las 3" |
| **Intérprete en vivo** | "Jarvis, tradúceme del inglés" → oye a la otra persona y le dice la traducción al oído, frase por frase. Diga "Jarvis" para salir. Inglés, francés, italiano, portugués, alemán, japonés, chino, coreano |
| Más volumen | Voz con ganancia + limitador y volumen del iPhone al máximo (ver límites abajo) |
| "Hey Meta, abre Jarvis" | Lanza la app desde las gafas |
| Pausa de privacidad | "Jarvis, no me escuches por una hora" |

## Lo que debes saber (sin adornos)

1. **"Hey Meta" sigue siendo Meta AI.** No se puede reemplazar ni interceptar. Hay dos activadores: *"Hey Meta"* → Meta AI; *"Jarvis"* → esta app. (Y *"Hey Meta, abre Jarvis"* sí lanza esta app.)
2. **No se puede saltar el límite de volumen de fábrica de las gafas** (firmware cifrado y firmado). Lo que sí hace la app: sube el volumen del iPhone al máximo y aplica +9 dB de ganancia con limitador (ajustable hasta +18 dB). Suena notablemente más fuerte dentro del límite.
3. **Teléfono bloqueado y en el bolsillo:** funciona con el modo de audio en segundo plano de iOS (verás el punto naranja del micrófono siempre encendido). iOS puede cerrar la app si la memoria está justa, y las llamadas telefónicas la interrumpen un momento: prueba un día completo antes de depender de ella. Gasta más batería (escucha continua).
4. **Calidad de audio:** mientras la app escucha, iOS usa el perfil Bluetooth de manos libres (HFP, 16 kHz): la voz se oye bien pero la **música** pierde calidad. Si vas a escuchar música, apaga la escucha (botón *Escuchando* → *Apagado*).
5. **La IA se configura sola:** pegas las claves que tengas y Jarvis elige el cerebro **principal** y el mejor modelo de cada servicio. Hoy Claude es de lo más capaz que existe, pero **no existe una IA gratuita, ilimitada y a la vez equivalente**, y yo no puedo entrenar un modelo propio que lo supere. Lo que el proyecto sí resuelve es que **nunca te quedes sin cerebro**: puedes conectar varios (Claude, Gemini, OpenAI, OpenRouter, Groq u Ollama) y si el principal se queda sin créditos, te limita o se cae, pasa solo al siguiente y te avisa por voz. Ver sección *Cerebros*.
6. **SDK de Meta en vista previa:** el kit para desarrolladores está en *developer preview*; sirve para uso personal en Modo desarrollador, no para publicar en la App Store.
7. **Calidad de cámara (límite real):** Meta solo entrega a apps externas video de hasta **720×1280 a 30 cuadros/s** (opción *Máxima*); más no es posible por el ancho de banda del Bluetooth y el firmware firmado. Meta advierte que a máxima resolución el Bluetooth comprime más: si se ve peor, use *Equilibrada*. La **foto** sí sale a resolución completa (API de foto que Meta marca como experimental; si falla, la app toma la foto desde el video automáticamente).
8. **Retraso de la transmisión:** cero retraso no existe (gafas → Bluetooth → iPhone → internet → otro celular). El sistema nunca acumula atraso, y el servidor en Render se crea en **Virginia**, la región más cercana a Puerto Rico (Render no deja cambiar la región después: si ya lo creó en Oregón, cree el servicio de nuevo).
9. **Compilada y probada automáticamente:** cada cambio se compila en una Mac de GitHub y se prueba con las **gafas simuladas oficiales de Meta** (arranque del SDK, detección de gafas, sesión, cámara en las 3 calidades, foto en máxima calidad). El servidor tiene 67 pruebas (`npm test`). Límite honesto: el simulador de Meta tiene un error conocido que no entrega cuadros de video simulados, así que el video en sí solo se confirma con sus gafas reales.

---

## Paso 1 — Servidor (15 min)

Necesitas un servidor con **HTTPS público** (TradingView, WhatsApp y el enlace en vivo lo requieren). Node 20+ sin dependencias.

```bash
cd server
cp .env.example .env        # rellena JARVIS_TOKEN y ANTHROPIC_API_KEY como mínimo
node --env-file=.env src/server.js
curl http://localhost:8080/health
```

Opciones para publicarlo:
- **Railway / Render / Fly.io (recomendado):** sube la carpeta `server`, comando de inicio `node src/server.js`, pon las variables de `.env` en su panel y añade un volumen en `/data` (variable `DATA_DIR=/data`) para que memoria y recordatorios sobrevivan. Hay `Dockerfile` listo.
- **En tu casa:** `node --env-file=.env src/server.js` + `cloudflared tunnel --url http://localhost:8080` (te da una URL https).
- **Docker:** `docker build -t jarvis server && docker run -d -p 8080:8080 --env-file server/.env -v jarvis-data:/data jarvis`

Genera el token: `openssl rand -hex 24`. Guárdalo: lo pondrás en la app.

## Paso 2 — Instalar la app en el iPhone

Necesitas un Apple ID (gratis sirve; con cuenta gratis la app caduca a los 7 días y la reinstalas).

**A) Sin Mac (GitHub Actions + Sideloadly)** — ya está preparado:
1. Crea un repositorio **privado** en GitHub y sube todo este proyecto.
2. Pestaña **Actions → "Build IPA (sin firmar)" → Run workflow**. Tarda ~10 min.
3. Descarga el artefacto `Jarvis-unsigned-ipa` (`Jarvis-unsigned.ipa`).
4. Instálalo con [Sideloadly](https://sideloadly.io) (Windows/Mac) o AltStore: conecta el iPhone, arrastra el `.ipa`, pon tu Apple ID. En el iPhone: *Ajustes → General → VPN y gestión de dispositivos* → confiar.

**B) Con Mac:** `brew install xcodegen && cd ios && xcodegen generate && open Jarvis.xcodeproj` → *Signing & Capabilities* → elige tu Team → cambia el *Bundle Identifier* por uno tuyo (p. ej. `com.tunombre.jarvis`) → ▶ en tu iPhone (necesita Xcode 26.4 o superior por el SDK de Meta).

## Paso 3 — Conectar con las gafas (Meta)

1. En el iPhone, app **Meta AI → Ajustes → Tus gafas → Modo desarrollador** (actívalo).
2. Abre **Jarvis → Ajustes → Registrar con Meta AI** (salta a Meta AI y vuelve). Luego **Permiso de cámara**.
3. Con las gafas puestas y conectadas, di "Hey Meta, abre Jarvis" para probar el lanzamiento por voz.

## Paso 4 — Configurar la app

1. **Ajustes → Servidor:** URL (`https://tu-servidor`) y la contraseña (`JARVIS_TOKEN`). Debe decir *Conectado*.
2. Acepta **micrófono**, **reconocimiento de voz** y **ubicación**. Luego en *Ajustes de iOS → Jarvis → Ubicación → Siempre* y activa *Actualización en segundo plano*.
3. Mejor voz: *iOS → Ajustes → Accesibilidad → Contenido hablado → Voces → Español* → descarga una **Premium/Mejorada** y elígela en *Jarvis → Ajustes → Voz*. Para un acento más natural aún, pon `ELEVENLABS_*` en el servidor.
4. Desactiva el *Modo de bajo consumo* mientras la uses.
5. Pulsa **Probar voz** y di "Jarvis, ¿qué hora es?".

## TradingView

En la alerta → **Notifications → Webhook URL**: `https://TU-SERVIDOR/webhook/tradingview?secret=VALOR_DE_TV_SECRET` y en el mensaje:
```json
{"symbol":"{{ticker}}","action":"{{strategy.order.action}}","price":"{{close}}","message":"Cruce de medias en {{interval}}"}
```
(Requiere plan de TradingView con webhooks.) Para otras automatizaciones (Atajos de iOS, Zapier): `POST /push` con `Authorization: Bearer JARVIS_TOKEN` y `{"text":"..."}` y Jarvis lo dice en tus gafas.

## WhatsApp Business

Usa la **API en la nube de WhatsApp** (developers.facebook.com): crea una app → añade *WhatsApp* → tu número → crea un **token permanente** (usuario del sistema) → en *Configuración → Webhook*: URL `https://TU-SERVIDOR/webhook/whatsapp`, token de verificación = `WA_VERIFY_TOKEN`, suscríbete a **messages**. Variables: `WA_TOKEN`, `WA_PHONE_ID`, `WA_APP_SECRET`. Límites de Meta: el número no puede estar a la vez en la app de WhatsApp Business normal, y solo puedes responder en texto libre dentro de las 24 h del último mensaje del cliente.

## Transmisión en vivo

Pestaña **Cámara** → duración → **Iniciar transmisión** → *Compartir*. Cualquiera con el enlace ve el video y (tocando "Activar sonido") oye el micrófono de tus gafas, en el navegador, sin instalar nada. También por voz: "Jarvis, transmite lo que veo por una hora". El enlace es secreto (128 bits), expira y se desactiva al detener. Solo hay una transmisión a la vez. La calidad (~360×640, ~10 cuadros/s) la limita el Bluetooth de las gafas. **Avisa a quien grabes:** en muchos lugares grabar el audio de otras personas exige su consentimiento.

## Cerebros: automático, sin elegir nada

- **Solo pega claves** en `.env` (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`, `OLLAMA_URL`). Al arrancar, Jarvis consulta a cada servicio qué modelos tiene y se queda con el más capaz; no hay que escribir nombres de modelo.
- **Orden automático:** Claude → Gemini → OpenAI → OpenRouter → Groq → Ollama. El primero con clave es el principal. Con Claude, usa Sonnet para charla rápida y **Opus automáticamente** en preguntas complejas (`JARVIS_MODEL` es opcional y fuerza un solo modelo).
- **Cambio automático:** si el principal da error de créditos, límite o caída, Jarvis pasa al siguiente, **te lo dice por voz**, no vuelve a probar el caído durante un rato (60 min si es por créditos) y mantiene herramientas y visión. Solo Claude tiene búsqueda web integrada; con otro cerebro no la hay.
- **Claude sin sustos de crédito:** en console.anthropic.com activa la **recarga automática** y un **límite de gasto mensual** con alerta por correo.
- **Gratis o casi:** Gemini tiene nivel gratuito en su API; OpenRouter/Groq ofrecen modelos abiertos baratos; con una PC potente, Ollama es gratis e ilimitado pero menos capaz.
- **Consumo:** `GET /usage` (con `Authorization: Bearer JARVIS_TOKEN`) muestra llamadas y tokens por cerebro y cuáles están apartados.

## Problemas frecuentes

| Síntoma | Causa / arreglo |
|---|---|
| El Actions o Xcode falla compilando un archivo | Abre el log, copia el error y pásamelo: es casi seguro un nombre de la API de Meta que cambió. Si falla `GlassesVoice.swift` (API experimental de "Hey Meta, abre Jarvis"), puedes borrar ese archivo y la línea `voice.start()`/`voice.onLaunch` de `AppModel.swift`. |
| "Sin mic de gafas" | Las gafas deben estar conectadas por Bluetooth al iPhone; reconecta y revisa que *Meta AI* las vea. |
| No me oye "Jarvis" | Di "Jarvis" y pausa un instante; activa *Dictado en español* en iOS; prueba otro idioma (es-MX/es-ES) en Ajustes. |
| Se calla tras un rato con el teléfono bloqueado | Quita el *Modo de bajo consumo*, no cierres la app desde el selector, y pon ubicación en *Siempre*. |
| Foto/transmisión: "permiso de cámara" | *Ajustes → Permiso de cámara* y acepta en Meta AI. |
| La voz de navegación sale en inglés | Las indicaciones las genera Apple en el idioma del iPhone: ponlo en español. |
| "Sin permiso para el calendario" | *Ajustes de iOS → Jarvis → Calendarios → Acceso total*. |
| El intérprete no entiende a la otra persona | En iOS: *Ajustes → General → Teclado → Dictado* y añada ese idioma. Funciona frase por frase: si hablan mientras Jarvis traduce, esa frase se pierde. |
| La transmisión se ve entrecortada | Use calidad *Fluida* o *Equilibrada*; el visor muestra los cuadros por segundo reales arriba a la derecha. |

## Estructura

```
server/   Node sin dependencias: WebSocket, IA con varios cerebros, herramientas, webhooks, visor en vivo
  src/ ... test/ (npm test)    .env.example    Dockerfile
ios/      App SwiftUI (project.yml → xcodegen)   Jarvis/*.swift
.github/workflows/build-ipa.yml   compilación en la nube sin Mac
_previous/ (en ios/ y server/)    restos de una versión anterior hallada en la carpeta; no se usan
```

## Seguridad

Token largo y secreto; solo HTTPS; las claves viven únicamente en el servidor. Los mensajes de WhatsApp, alertas y texto en fotos se tratan como **datos, no órdenes** (protección contra instrucciones ocultas), y WhatsApp nunca se envía sin tu confirmación hablada en un turno posterior. No compartas el enlace de transmisión con quien no debas.

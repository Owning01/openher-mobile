# OpenHer Mobile — SUPER PLAN

> App Android **nueva**, en Flutter, **cliente delgado** que habla directo con el server
> de opencode (v2, `/api/*`). No depende de OpenHer ni de `openher-desktop.exe`.
>
> Contrato de API: [`API_CONTRACT.md`](./API_CONTRACT.md) — todo medido contra el server real.
> Maqueta navegable: `../prototype/mobile.html`.
>
> Estado: plan aprobado para ejecución por fases. 2026-09-28.

---

## 0. Decisiones (las que no se re-discuten en cada fase)

| # | Decisión | Por qué | Alternativa descartada |
|---|---|---|---|
| D1 | **Sólo dialecto v2** (`/api/*`) | El server es v2; mantener los dos dialects duplica modelos, repos y tests | Portar el soporte dual del escritorio |
| D2 | **Credenciales por UI** (`flutter_secure_storage`) | `service.json` no existe en opencode2 y en Android no hay disco del PC | Leer un archivo del desktop |
| D3 | **Stream global** `/api/event` + filtro por sesión en el cliente | El stream por sesión **da 404 medido** en `:4098`; el global trae `durable.seq` y sirve para toda la app con un solo socket (ver API_CONTRACT §7.1) | `/api/session/{id}/event?after=` (404 en este build) |
| D4 | **POST y después escuchar** | El POST del prompt no devuelve el turno; es el único patrón posible | Esperar el turno en el POST (bloquea la UI) |
| D5 | **Bottom nav de 4 destinos** + hojas inferiores | Un pulgar, una tarea por pantalla; la activity-bar de 12 items no es táctil | Reusar la grilla de paneles del escritorio |
| D6 | **Tokens del escritorio reusados** | `tokens.dart` es un espejo exacto de `tokens.css`; el HTML ya los usa | Diseñar una paleta nueva |
| D7 | **Cero dependencias nuevas** salvo `flutter_secure_storage` + `speech_to_text` | Ponytail: stdlib antes que dependencia | Un router, un state manager, un包 de UI kit |
| D8 | **3 canales de error, todos visibles** | El escritorio se come `session.error` en silencio: bug conocido, no se replica | Sólo `info.error` |

---

## 1. Objetivo y criterio de éxito

**Objetivo:** una app Android que abra una sesión de opencode, la lea, la siga en vivo,
permita chatear con ella y ver la actividad del turno, tan rápido y lisa como la de escritorio.

**Definition of Done global** (medible, no subjetiva):

| Métrica | Objetivo | Cómo se mide |
|---|---|---|
| Arranque → lista de sesiones visible | < 400 ms en servidor local, < 1.2 s en remoto | `Stopwatch` + primer frame con contenido |
| Abrir una sesión → primeros mensajes | < 250 ms (local) |同上, con `limit=30` |
| Frame mientras streamea | 60 fps, sin jank > 16 ms | timeline de Flutter en modo profile |
| Delta de texto → paint | < 50 ms | throttle de deltas a 20 fps |
| Cierre de pantalla / cambio de tab | < 100 ms | sin I/O sincrónico en `dispose` |
| Memoria con sesión de 500 mensajes | < 250 MB | `adb shell dumpsys meminfo` |
| Funciona con el server apagándose a mitad del turno | sí, sin crashear, con aviso | test manual + test de integración |

---

## 2. Arquitectura

### 2.1 Capas (MVVM + repos, igual que el escritorio — no inventar otra)

```
lib/
  core/
    config/      server_config.dart      host, puerto, user, pass, dialecto detectado
    network/     api_client.dart         GET/POST + unwrap {data} + guarda anti-HTML
                 sse_client.dart         stream por sesión, ?auth_token, ?after=, backoff
                 auth.dart               Basic + token query
    storage/     secure_creds.dart       flutter_secure_storage
                 prefs.dart              tema, texto, modo de datos, último directorio
  domain/
    models/      session.dart  message.dart  tool.dart  event.dart
                 (sealed classes, discriminated por 'type' — igual que el server)
  data/
    repositories/  session_repository.dart  message_repository.dart  file_repository.dart
  ui/
    core/        tokens.dart  theme.dart  app_toast.dart  motion.dart
    features/
      connect/   connect_screen.dart       (host/puerto/user/pass)
      sessions/  sessions_view.dart       (lista)
      chat/      chat_view.dart  chat_viewmodel.dart  composer.dart
                 message_bubble.dart  turn_activity.dart  tool_card.dart
                 question_sheet.dart  permission_sheet.dart  model_sheet.dart
      files/     files_view.dart
      settings/  settings_view.dart
      navigation/app_nav.dart             (sustituye al AppNav del escritorio)
```

### 2.2 Los modelos siguen al server, no al desktop

El server v2 manda `content[]` embebido dentro del mensaje. El escritorio lo **achata** a
`parts[]` (`message.dart:348-504` `_fallbackPartsV2`) para no reescribir el renderer.
**El móvil no necesita ese shim**: se parsea `content[]` directo y se renderiza. Menos
código y menos surprise. (El shim del escritorio existe por compatibilidad histórica.)

```
Message = sealed
├─ UserMessage       { id, time, text, files[], agents? }
├─ AssistantMessage  { id, time, agent, model, content[], finish?, cost?, tokens?, error? }
├─ SystemMessage     { id, time, text }
├─ SyntheticMessage  { id, time, sessionID, text }
├─ CompactionMessage { id, time, reason, summary, recent }
├─ AgentSwitched     { id, time, agent }
├─ ModelSwitched     { id, time, model }
└─ ShellMessage      { id, time, callID, command, output }

AssistantContent = TextContent | ReasoningContent | ToolContent
ToolState = Pending | Running | Completed | Error   // completed usa content[], NO output:string
```

### 2.3 Streaming: máquina de estados

```
polling ──connect──> streaming ──error──> reconnecting ──5 intentos──> polling
                        │                        │
                        └──── live ──────────────┘
```
- `streaming`: SSE en `/api/session/{id}/event?after=<último seq>`.
- Reconnect: backoff `1s * 1.8^n`, tope 30 s, jitter ±30 % (copiado de `sse_client.dart:396-404`).
- `polling`: `GET message?order=desc&limit=30` cada 2 s **sólo con la app en foreground**
  y el chat visible (en background el socket se pausa: batería).
- Heartbeat v2 = comentario SSE `: heartbeat` cada 15 s ⇒ watchdog a 45 s, y el parser
  tiene que ignorar comentarios o se rompe.

### 2.4 Fin de turno (idéntico al escritorio, ya probado)

`working` = último assistant con `time.completed == null` **o** status `busy|running|retry`.
`idle` = status `idle|completed|done|success|succeeded` **y** último assistant con
`time.completed != null`. El botón Detener sigue visible hasta esa evidencia real.

---

## 3. Pantallas (4 destinos + hojas)

| # | Pantalla | Origen en el escritorio | Qué cambia en móvil |
|---|---|---|---|
| 1 | **Sesiones** | `SessionPanel` del sidebar | Lista a pantalla completa; grupos por fecha; long-press → menú; swipe → archivar; pull-to-refresh; dot "En ejecución" vía `/api/session/active` |
| 2 | **Chat** | `ChatView` completo | App bar de 56 px en vez de 38 px + 12 botones; el overflow de 12 items pasa a hoja; diff lateral → hoja a pantalla completa; tooltips → sin tooltip (info en la hoja) |
| 3 | **Archivos** | `ExplorerPanel` | Breadcrumb scrollable; long-press → hoja con `Añadir al chat`; sin split ni drag&drop |
| 4 | **Ajustes** | `SettingsView` (13 categorías) | Las 13 en una lista; **sustituye** a Ajustes+Servidor+Remoto; credenciales en secure storage; `Probar conexión` con el probe de §1.6 |

**Hojas inferiores (bottom sheets), no diálogos flotantes** (el pulgar llega abajo):
acción del chat · modelo/agente · pregunta · permiso · confirmación · diff.

**Se elimina del móvil** (no tiene equivalente táctil): actividad de 12 items, sidebar
redimensionable, grid de paneles y splits, arrastre de pestañas, window controls, barra de
estado, autoscroll con botón central, RAM chip, hover, doble clic.

---

## 4. Performance: el contrato

El chat de escritorio yaanolizó tres veces por rendimiento (memo de markdown, keep-alive,
paginación). Móvil es **más** lento (GPU y ancho de banda menores), así que el presupuesto
es explícito y cada regla tiene su razón:

| Regla | Cómo | Por qué |
|---|---|---|
| **Markdown memoizado por firma** | `_MarkdownText` devuelve la misma instancia si no cambió la firma; se excluyen callbacks | Es el costo #1 de un chat con 500 mensajes. Reusa el patrón ya validado (`message_bubble.dart`) |
| **Deltas a 20 fps** | Buffer 50 ms y repintar sólo la última burbuja | Un delta por token = 60 rebuilds/s de markdown |
| **Página inicial 30** | `limit=30` + `cursor` para "cargar 30 anteriores" | 500 msgs de golpe = jank y memoria |
| **Prefetch al scrollear** | Cuando faltan 5 ítems, pedir la página siguiente | El scroll nunca espera red |
| **`RepaintBoundary` por burbuja** | Envolver cada mensaje | Un delta no repinta la lista entera |
| **Caja de actividad con `Offstage`, no `CollapsibleBody`** | Toggle instantáneo sin reconstruir | Reusa la corrección ya medida del escritorio |
| **Sin `BackdropFilter` en listas** | Sólo en el bottom nav y en hojas | `BackdropFilter` sobre scroll es el #1 de drops en gama media |
| **Imágenes: thumbnail + cache en disco** | `cacheWidth` al decode | Decodificar un PNG de 4000 px a pantalla de 350 px = OOM |
| **Sin I/O en `build`/`dispose`** | Todo async con `mounted` check | El cierre lento de pestañas fue exactamente esto |
| **Timeres con `TickerMode`/visibilidad** | Pausar SSE y polling si la pantalla no está visible | Batería |
| **`cacheExtent` corto (250 px)** | | Menos offscreen construido |
| **Sin sombras grandes** | `AppShadows.sm/md`; `lg` sólo en hojas | Sombras grandes sonrops de GPU |

**Métrica de jank:** en modo profile, 0 frames > 16 ms al scrollear una sesión de 500
mensajes con streaming activo.

---

## 5. Fases (DAG)

```
M0 Scaffold ──> M1 Tokens+tema ──> M2 Cliente+modelos ──> M3 Sesiones
                                                        └─> M4 Chat: leer
                                                              └─> M5 Chat: enviar+streaming
                                                                    └─> M6 Caja de actividad + tools
                                                                          └─> M7 Hojas (pregunta/permiso/modelo)
                                                                                └─> M8 Archivos
                                                                                └─> M9 Ajustes+conectar
                                                                                      └─> M10 Pulido+release
```

Cada fase cierra con: `flutter analyze` limpio, tests de la fase en verde, y el
**tribunal** (critic + challenger + auditor). Nadie aprueba su propio trabajo.

| Fase | Entregable | Gate |
|---|---|---|
| **M0** | `flutter create` + android config (minSdk, permisos, app name, ícono) |Compila y arranca en emulador |
| **M1** | `tokens.dart` (port de `tokens.dart` del escritorio) + `theme.dart` claro/oscuro | Test de contraste ≥4.5:1 |
| **M2** | `ApiClient` (unwrap `{data}`, guarda anti-HTML, timeout), `SseClient` (por sesión, `?auth_token`, `?after=`, backoff, watchdog de heartbeat), modelos sellados | Tests con `MockClient` real: 200, 401, 404, HTML-200-trampa, timeout, SSE con comentario |
| **M3** | `SessionsView` + repo + `Conectar` (probe `/api/location`) | Test de la trampa HTML-200; test de credenciales |
| **M4** | `ChatView` lectura: lista, markdown memo, cursor, follow-tail, carga anteriores | Test de scroll (patrón ya existente `chat_scroll_test.dart`) |
| **M5** | Composer + envío + streaming + Detener + conexión de pantalla | Test de fin de turno y de reconexión con `?after=` |
| **M6** | `TurnActivity` + `ToolCard` + 3 canales de error | Test de cada canal de error por separado |
| **M7** | Hojas: acción, modelo/agente, pregunta, permiso, confirmación | Test de pregunta con `answers` mal formado |
| **M8** | `FilesView` (`/api/fs/list`, `/api/fs/find`) + `Añadir al chat` | Test de path con espacios y no-UTF8 |
| **M9** | `SettingsView` + secure storage + `Probar conexión` | Test: no se loguea la password |
| **M10** | Pulido: jank, a11y (contraste, 44 px, TalkBack), oscuro, release | Timeline de 60 fps + APK debuggable=false |

---

## 6. Riesgos y trampas (medidas, no supuestas)

| Riesgo | Impacto | Mitigación |
|---|---|---|
| `auth_token` en la URL queda en logs | Filtración de credenciales | Nunca loguear la URL completa; redactar en el logger |
| El catch-all devuelve HTML 200 | Parser revienta con `FormatException` | `ApiClient` rechaza `text/html` explícitamente y devuelve un error tipado |
| Heartbeat v2 es un **comentario** | Parser colgado si no se ignoran comentarios | Parser SSE que salta líneas `:` y watchdog de 45 s |
| `{data}` vs array pelado | `TypeError` en cada respuesta | `unwrapData` en una sola función; tests de ambos dialectos |
| Deltas perdidos al cambiar de app | Turno seemingly colgado | `?after=<seq>` en reconexión + re-snapshot si la seq no sirve |
| `service.json` no existe en opencode2 | App que no conecta | Credenciales por UI; nunca leer ese archivo |
| `/api/health` no existe en este build | Probe que siempre da 404 | Probe real: `/api/location` (§1.6) |
| Teclado tapa el composer | No se ve lo que escribís | `resizeToAvoidBottomInset` + `Scaffold` + scroll del composer; probar con teclado real |
| `speech_to_text` en Android necesita permiso | Mic mudo | Pedir `RECORD_AUDIO` en runtime y explicar si se niega |
| Markdown con tablas largas | Overflow horizontal en 360 px | `SingleChildScrollView` horizontal en tablas y código |
| Decodificar imágenes grandes | OOM | `cacheWidth` + cache en disco |

---

## 7. Cómo se verifica (por el tribunal, no por el que escribe)

- **Critic**: ¿respeta las capas? ¿el modelo duplica el del server? ¿acoplamiento?
- **Challenger**: ¿qué pasa con respuesta HTML, 401, 500, stream cortado a mitad, token,
  mensaje de 10 MB, cursor inválido, sesión borrada en otro cliente, path con espacios,
  red-off, doble toque en Enviar?
- **Auditor**: salida **real** de `flutter test` y de `flutter analyze`; cero tests
  mockeados que "siempre pasan"; prohibido editar un test existente para que pase.
- **Success Auditor** (M10): la app real en emulador, sesión real del server real, con
  capturas de las 4 pantallas y de un turno con herramientas.

---

## 8. Lo que NO se hace (fuera de alcance de la v1)

- Dialecto v1 del server · PTY/terminal · editor de código · debate · kanban · imagegen ·
  plugins · learning · hub · MCP · tray · remoto por Tailscale · multi-proyecto.
- Cualquier dependencia de OpenHer (`:4848`, `:4849`, `acme`).
- Tests de golden: el golden en CI sobre Android es frágil; se prueba en emulador real.

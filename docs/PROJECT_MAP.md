# PROJECT_MAP — OpenHer Mobile

> Estado **actual** de `G:\Proyectos\openher-mobile`. Reemplazar, nunca acumular historia.
> Bitácora: [`PROJECT_MEMORY.md`](./PROJECT_MEMORY.md).

## Qué es esto

App **Android** en Flutter. Cliente delgado que habla **directo con el server de opencode**
(dialecto v2, `/api/*`). **No** depende de OpenHer ni de `openher-desktop.exe`.

App **id**: `ai.openher.openher_mobile` · versión `1.2.0+7` (`versionCode=7`).

## Estructura

| Ruta | Qué hay |
|---|---|
| `lib/core/network/` | `api_client.dart` (REST v2), `sse_client.dart` (stream global), `server_config.dart` |
| `lib/core/storage/` | `creds_store.dart` (secure storage), `prefs_store.dart` (capas, tema) |
| `lib/core/update/` | `update_service.dart`: manifiesto, descarga, instalación vía canal nativo |
| `lib/data/connectivity/` | `network_monitor.dart` + `DataPolicy`: modo bajo consumo **sólo** con datos móviles. Cellular: poll 12 s, página de **8** mensajes (de 15), sin streaming, sin imágenes |
| `lib/data/repositories/` | `session_repository`, `file_repository`, `catalog_repository` |
| `lib/domain/models/` | `session`, `message`, `tool`, `event`, `errors`, `agent_catalog`, `model_catalog`, `turn_activity` |
| `lib/ui/core/` | `tokens.dart`, `theme.dart`, `theme_variants.dart` (61 paletas), `layer_gate.dart`, `app_icon.dart`, `low_data_banner.dart`, `update_banner.dart` |
| `lib/ui/features/chat/` | `chat_view`, `chat_viewmodel`, `composer`, **`composer_suggestions`** (disparador `/` y `@`, sin `BuildContext`), `message_bubble`, `code_highlight` (resaltado de sintaxis con `highlight` y los tokens `--code-*`), `squares_spinner`, `turn_activity`, `tool_card`, `model_sheet`, `agent_sheet` |
| `lib/ui/features/` | `sessions/`, `files/`, `settings/`, `connect/`, `navigation/`, `plan/` |
| `docs/API_CONTRACT.md` | Contrato **medido** contra el server real |
| `docs/SUPER_PLAN.md` | Decisiones, arquitectura, fases M0–M10 |
| `prototype/mobile.html` | Maqueta navegable con toggles de capas |
| `scripts/publish-update.ps1` | Compila, sube APK + manifiesto, **verifica con `curl`** y **exige PowerShell 7+** |

**Tamaños medidos:** 51 archivos Dart en `lib/` (21.861 líneas), 50 archivos de test (18.809
líneas), 41 iconos SVG, 10 goldens en `test/goldens/`, **837 (6 skipped) tests** (6 skipped),
`flutter analyze lib` en cero errores y cero warnings.

## Capas

`spec/layers.json` (y su copia **idéntica** en `assets/spec/layers.json`, verificado con
comparación byte a byte) tiene cuatro secciones:

| Sección | Qué es | Cuántas |
|---|---|---|
| `_meta` | metadatos de la spec | 7 claves |
| `layers` | el catálogo por clave | **94 claves**, 4 en `false` |
| `disabled` | las 4 apagadas por diseño | 8 claves |
| `flutter_map` | qué capa va a qué widget | 12 claves |

`LayerCatalog` las carga y `LayerGate` es fail-open. `test/layer_contract_test.dart` falla si
una capa declarada no tiene `LayerGate`, o si una apagada no lo tiene.

**Las 4 apagadas** (se pueden prender en vivo desde Ajustes → Capas de la UI):
`chat.appbar.subtitle`, `chat.composer.counter`, `chat.composer.tsl`, `chat.header.progress`.

## Decisiones cerradas

| # | Decisión |
|---|---|
| D1 | Sólo dialecto v2 (`/api/*`); si el server es v1, error explícito |
| D2 | Credenciales por UI → `flutter_secure_storage`; `service.json` **no** existe en opencode2 |
| D3 | Stream **global** `/api/event` (el por sesión da 404), filtrado por sesión en el cliente, con dedupe por `id` de evento |
| D4 | POST del prompt y después escuchar; el POST no devuelve el turno |
| D5 | Bottom nav de 4 destinos + hojas inferiores |
| D6 | Tokens y **variantes de tema** reusados del escritorio (espejo de `tokens.css`) |
| D7 | Deps directos: `http`, `flutter_secure_storage`, `speech_to_text`, `flutter_svg`, `shared_preferences`, `flutter_markdown_plus`, `highlight`, `connectivity_plus`, `image_picker`, `video_player`, `pdfrx`, `html`, `url_launcher`, `share_plus` (hoja Descargar). De test: `image_picker_platform_interface` y `plugin_platform_interface`, para fchear la plataforma del Clip |
| D8 | Los 3 canales de error visibles (el escritorio se come `session.error`) |
| D9 | Modo de bajo consumo **automático** sólo con red celular; el usuario puede desactivarlo a mano |
| D10 | Autoupdate contra el manifiesto de la release, sin diálogos ni bloqueos. Un fallo del **chequeo** no se muestra; un fallo de **descarga** sí, con botón de **Volver a descargar** (`UpdateState.canRetry` = `failed && info != null && error != null`). Una descarga que no termina **borra el archivo a medias**: si no, pasa el piso de 2 MB de `_alreadyDownloaded` y el instalador recibe un APK truncado |
| D11 | El visor de archivos decide **por extensión**, no por el botón que se apretó: `domain/models/file_type.dart` + `ui/features/files/file_preview.dart` |
| D12 | El Clip abre el selector **multiple** (`pickMultiImage`): las fotos se acumulan en `_pending`, se ven en la tira del composer y se manda **una sola** lista. El shell es el unico que pasa `attachments` y `onRemoveAttachment`; `onSend` no las vuelve a mezclar |
| D13 | Todo mensaje con texto es **seleccionable** (el del usuario con `SelectableText`, el markdown con `selectable: true`, el bloque de código con `SelectableText.rich`) y trae un botón `more-horizontal` con **Copiar mensaje** y, en los del usuario, **Deshacer y editar**. Deshacer = `revert/stage` + `revert/commit` y **devuelve el texto al input** vía `ChatComposer.controller`, que el shell crea y libera |
| D14 | El long-press sobre un mensaje es del sistema (seleccionar fragmento), **no** del menu: los dos compiten por la misma arena de gestos y gana el hijo. Por eso el menu va en botón |
| D15 | Un mensaje **en cola** (`UserMessage.pendingSend`) se ve gris con borde y tres botones de **solo icono**: editar, eliminar, enviar. Es alcanzable porque el botón del composer hace **dos** cosas según el input: vacío = Detener, con texto = Enviar en cola. Sin ese cambio el camino era código muerto: `pendingSend` no lo leía nadie y `_submit` llamaba `onStop` siempre con `working` |
| D16 | La card de la pregunta sale del evento `form.created` con `metadata.kind == "question"` (vía `pendingQuestion`: `requestId` = form id, `fieldKey` = clave del campo) y va fija **abajo**, encima del composer. La sesión va anidada (`data.form.sessionID`). Reply por `POST /form/{id}/reply {answer:{key:value}}` (value, no label), con caída al camino viejo y al prompt. El `question.asked` se conserva como fallback aunque este build ya no lo emite (2026-10-09: 0 frames en 680+) |
| D17 | La caja del turno (`TurnActivityBox`) corta la lista de herramientas en `kToolListMaxHeight = 900` px, con scroll interno. 900 px lógicos es más que la pantalla de un teléfono, y por eso el scroll interno se queda |
| D18 | `groupSessions` ordena cada bucket por `updatedMs` **descendente**. La sesión corriendo lleva una luz que recorre el **título** (`ShaderMask` + degradado lineal, franja de 0.28 del ancho), movida por **un solo** `AnimationController` de 1400 ms en `SessionsViewState`, el mismo período que `SquaresSpinner` y `_PulseDot`. El reloj es `AnimationController?` perezoso, no `late final`: con `late final` el `dispose()` lo crearía con el elemento desmontado |
| D19 | Las rutas de imagen del texto del agente se pintan como miniaturas de 72 px (`imagePathsIn` + `MessageImages`), al final del texto y solo con el turno terminado. El agente manda rutas **desnudas**, no markdown (medido). Se expanden al 75% del **alto de pantalla**, con `BoxFit.contain`. Los bytes vienen de `GET /api/fs/read/<path>` con el header Basic, que pasa el shell |
| D20 | `SessionsView.onAction` es **`required`** a propósito: era opcional y el shell no lo pasaba, así que el swipe y las seis acciones del menú no hacían nada y nada lo delataba (los tests del widget se lo pasan ellos). Con `required`, olvidarlo es un error de compilación. `DELETE /api/session/{id}` → **204 vacío** (medido), sin `directory`; la fila sale de la lista **después** de que el server contestó |
| D21 | Visor de planes html-plan (`ui/features/plan/`): parsea el **mismo** `plan.html` (nada duplicado) y lo pinta nativo con las decisiones y el formato Respond de la skill. Entrada por botón `Ver plan` en la burbuja cuando el texto trae una ruta `.html` (absoluta o relativa); si no es plan, cae a `FilePreview` |
| D22 | Links http/https en el chat preguntan antes de salir (`Abrir enlace` con la URL visible); `file://` y rutas nunca salen. Recencia efectiva en Recientes: lo en curso y lo tocado ordenan primero sin mover de grupo ni mentir la hora |

## Contrato: lo que hay que no olvidar

- **Auth:** Basic `opencode:<OPENCODE_SERVER_PASSWORD>`; el user se compara **siempre**; default `"opencode"`.
- **Probe de versión:** `GET /api/location` (NO `/api/health`: da 404 en este build).
  Sin red el probe dice `NetworkError` tal cual: envolverlo en
  `UnsupportedServerError` mentía ("no es v2" con Tailscale caído, 2026-10-07).
- **Trampa:** todo path desconocido devuelve **HTML 200** (catch-all del SPA) → el parser
  rechaza `text/html`. Un **5xx con HTML** es error de server, no el catch-all: se clasifica el
  5xx antes del sniff de HTML, o se pierde el retry.
- **Heartbeat v2:** comentario SSE `: heartbeat`, no un evento. El tipo del evento va **dentro**
  del `data` (no hay líneas `event:`).
- **Mensajes v2:** `content[]` embebido (text/reasoning/tool), no `parts[]`.
- **Fin de turno:** `session.execution.started` / `.succeeded` **y** `time.completed`/`finish`.
  `session.status` e `session.idle` **no existen** en v2 (medido, capturando el stream).
- **Cierre de turno en modo polling:** el endpoint de mensajes inserta un `{"type":"idle"}`; esa es
  la única señal de fin cuando no hay SSE (modo de bajo consumo).
- **Paginación (medido con 200 mensajes):** `order=desc` = los más nuevos; `cursor.previous` va
  hacia lo **nuevo** (0 ítems desde la última), `cursor.next` va hacia lo **atrás**. Con cursor,
  `order` **no** se manda (`InvalidCursorError`). Las páginas llegan de más nuevo a más viejo,
  **incluida la de `previous`** (medido: se tomó una página vieja, se pidió su `previous` y
  volvieron los 15 del más nuevo al más viejo). Un poll vacío trae `previous: null`, y eso
  significa "nada más nuevo por ahora", no "no hay cursor".
- **Prompt con la sesión ocupada:** `/api/session/{id}/prompt` declara **409 Conflict**. Por eso
  mandar mientras el agente trabaja es un caso real, y el mensaje **no se borra**: queda en
  pantalla marcado `notDelivered` con reintento a un toque.
- **Bodies:** `POST /api/session/{id}/prompt` exige `text` en la **raíz**; `createSession` quiere
  `location` como **objeto** `{directory}`; `compact` y `revert/commit` exigen un body `{}`;
  `revert/stage` exige `messageID`. Sin body: 400 `Expected object`.
- **204:** los endpoints de cambio (`/agent`, `/model`, `interrupt`, `/compact`) devuelven **204
  sin cuerpo**; van por `postJson`, nunca por `_object`.
- **Deltas:** se enrutan por `assistantMessageID` del evento, no "al último mensaje".
- **Preguntas:** no hay endpoint listable (`/api/question/request` → 404). Se responde por
  `POST /api/session/{id}/question/{requestID}/reply`, con fallback a prompt.
- **Stream:** nunca mandar `?sessionID=` (400, query no declarada) ni `?after=` (no existe).
- **Modelos y agentes:** `GET /api/model` (102 modelos) y `GET /api/agent` (26 crudos, 20
  elegibles). Los **niveles de pensamiento son las `variants`** del modelo, no un campo aparte.
  Un agente **no** trae modelo.
- **Herramientas agrupadas:** una caja por **turno**, montada en el primer assistant del turno
  (los resultados de shell nunca la poseen). Dueño y absorciones: `lib/domain/models/turn_activity.dart`.
- **Costo de los mensajes (medido 2026-09-29 con `test/data_probe_test.dart`):** una página de
  `message` pesa **entre 17 KB y 220 KB** según la conversación. El server ya devuelve
  `cursor.previous`, y `?cursor=` con 0 mensajes pesa **50 B** contra **25.511 B** de la página
  completa: **510x**. El poll del chat **ya usa el cursor** (`_pollNewer`), y `refresh()` sigue
  siendo la página entera porque es la verdad de fondo al volver a primer plano. El orden de la
  respuesta con `previous` es **DESC**, igual que `order:'desc'`.
  **El stream es global** y trae los eventos de todas las sesiones, que
  el cliente filtra **después** de descargarlos; no hay endpoint por sesión.
- **Los 4 cursores del server:** la respuesta trae `cursor.previous` y `cursor.next`. `previous` va
  hacia lo **nuevo**, `next` hacia lo **atrás**, y con cursor **no** se puede mandar `order`
  (400). Cuando no hay nada nuevo, `previous` viene **`null`**: eso significa "no hay nada más
  nuevo *por ahora*", **no** "no hay cursor", y hay que **conservar el cursor viejo**.
  Dueño de los dos: `_newerCursor` (poll) y `_earlierCursor` (botón de anteriores).
- **El polling sigue a la pestaña visible:** las 4 pestañas viven en un `IndexedStack`, así que
  `dispose` no se llama al cambiar de pestaña. Chat y sessions reciben `visible` del shell y frenan
  su poll con `setVisible` / `didUpdateWidget`. Sin eso, el poll de `/api/session/active` (62 B
  cada 5 s) seguía corriendo con el chat al frente.
- **Subagentes:** `GET /api/session` trae `parentID` **sólo cuando no está vacío**. Principales =
  la clave ausente; subagentes = la clave con un `ses_…`. Medido sobre 1000 sesiones: 483 sin la
  clave, 517 con la clave, y el spot-check contra `GET /api/session/{id}` coincidió. El filtro sale
  **gratis**, sin requests extra. Regla del escritorio, textual (`web/src/components/SessionList.tsx`):
  "Recientes lista SOLO sesiones principales (sin parentID), ni hijas con padre vivo ni huérfanas".
  La app lo lleva con un interruptor porque un subagente a veces es justo lo que se quiere abrir.
- **Favoritas:** **no hay ninguna en el server** (medido 2026-09-29: `GET /shell/fs/favorites` devuelve
  el HTML del SPA y el `openapi.json` no menciona `favorite`). El escritorio las guarda en
  `localStorage[STORAGE_KEYS.FAVORITES]` como `string[]` **ordenado**
  (`web/src/hooks/useSessions.ts`); la app lo porta a `shared_preferences` con la misma forma.
  No hay puente entre las dos listas: son dos almacenes distintos.
- **Visor de archivos:** los bytes salen de **`GET /api/fs/read/<path>`**, que **medido**
  devuelve los bytes **crudos** con el `Content-Type` correcto (verificado con un APK de
  56 MB = `application/vnd.android.package-archive`, y con PNG, SVG, PDF y `.md`). No hay otra
  vía: `/api/fs/raw/*`, `/api/fs/download/*` y `/api/file/*` dan **404**, y cualquier ruta sin
  prefijo cae en el catch-all del SPA (HTML 200). Acepta `\` y `/` en el path (probado).
  Sirve **cualquier disco** (`C:/Windows`, `G:/Proyectos/...`, medido 2026-10-08):
  el `read` no está atado al `location`. Un `.html` genuino viene como
  `text/html` igual que el catch-all, así que `_sendBytes` decide por el cuerpo
  (`esShellDelSpa`: marca `v2-background-bg-deep` del shell real), nunca por el
  header solo.
- **`GET /api/fs/list` devuelve solo `path` y `type`** (medido): ni mime, ni tamaño, ni nombre.
  Por eso la clasificación va por extensión, y una extensión desconocida sale `binary` con un
  aviso, en vez de renderizar bytes como texto.
- Los cargadores de red del visor (imagen, svg, video, pdf) necesitan el header Basic
  explícito; sin él el server responde 401. Lo arma `ServerConfig.binaryHeaders`.
- **`?auth_token=<base64(user:pass)>` autentica en todo `/api/*`, incluido `fs/read`** (medido:
  200 con y sin header, 401 sin ninguno) y el server **no emite cookie**. Por eso el HTML se puede
  abrir en el navegador del sistema y por eso se **ignora** el `&style` de sus `<link>`: un CSS
  externo no es un `.html` y el server lo sirve literal. El costo es que la password viaja en la URL,
  así que la app nunca la copia al portapapeles.

## Server de desarrollo

`127.0.0.1:4098` · usuario `opencode` · password en
`%USERPROFILE%\.config\opencode\service.json` (**la app no lo lee**: va por UI → secure storage).

## Comandos

```powershell
$env:ProgramFiles(x86) = (Join-Path $env:TEMP 'vs_shim')   # solo para flutter test/analyze
flutter analyze
flutter test
# regenerar los PNG del spinner (los compara como golden; sin el flag fallan)
flutter test test/squares_spinner_test.dart --update-goldens
# build + publicar (el script exige PowerShell 7+, o se niega a correr)
pwsh -File .\scripts\publish-update.ps1 -Notes "..."
```

Build de Android: `ANDROID_HOME=G:\Android\SDK`, `JAVA_HOME=G:\Android\Android Studio\jbr`,
`kotlin.incremental=false` en `android/gradle.properties` (la caché incremental falla en este disco).

## Trampas conocidas

- **La pantalla de sesiones pagina con `cursor` hasta el tope de 20 páginas**
  (`SessionRepository.listAll`): 2.000 sesiones en esta máquina, 654 principales. Antes pedía
  una sola página de 100 y mostraba 59 principales — 595 invisibles sin aviso. Cuesta
  ~981 KB, pero **una vez** al crear la pantalla: el shell al volver de la pestaña sólo llama
  `pollActive()` (62 B), y `load()` no se repite. Los únicos callers de `listAll` son la
  pantalla de sesiones; `list` (una página) sigue existiendo para lo puntual.
- **El markdown del chat se pinta con los tokens `--code-*`** (`code_highlight.dart`): el
  bloque de codigo es un `RichText` con los spans de `highlight`, la cursiva en
  `--warning`, el codigo inline en `--success` y la cita en `tertiary`. Los tokens
  `--code-*` existen en `tokens.dart` **desde el primer dia**: lo que faltaba era el
  paquete `highlight` en el `pubspec` y un `RichText` en vez de un `Text`.
- **`session.tokens` NO es el contexto**: es un contador **acumulado** de toda la sesión. Medido:
  marcaba 19.892.436 donde el contexto real era 195.089 (**115x**). El contexto es
  `TokenUsage.context` = `input + cache.read + reasoning` del **último** assistant; `cache.write`
  queda fuera (lo relee el próximo turno) y `output` también (es lo generado). El getter del VM es
  `contextTokens`; **no** existe `serverTokens` (se borró para que el nombre viejo no quedara con
  la definición nueva).
- **`GET /api/command` devuelve 3 comandos** (`init`, `review`, `debate`) y es la lista completa.
  El cliente web los mezcla con 13 hardcodeados (`compact`, `undo`, `redo`, `themes`, `history`, …)
  que dan **404**: por eso "no funcionan". En la app `compact`/`undo`/`redo` se ofrecen aparte y van
  a su endpoint real (`POST /compact`, `POST /revert/stage` + `/revert/commit`), no a
  `POST /session/{id}/command`.
- **`POST /session/{id}/command` exige `{name, text}`** (`name`, no `command`; los dos
  requeridos) y el `name` va **sin barra** porque el lookup del server es exacto.
- **`/api/mcp/resource` devuelve un objeto, no una lista**: `data` es
  `{resources[], templates[]}`. Una comprensión de lista da un menú vacío **en silencio**.
- **Un `directory` inexistente da 500**, no lista vacía. Y `/api/skill` pesa **490 KB**: se carga
  una vez por chat, nunca por tecla.
- **`revert/commit` responde 204**, no 200. `revert/stage` exige `{messageID}`; `{}` da 400.
- Un golden sin `RepaintBoundary` se come la pantalla entera. `matchesGoldenFile` sube hasta
  el borde del nodo más cercano: sin un `RepaintBoundary` ceñido, los 800x600 del test default
  entran en el PNG (medido: 41x19 de grilla en un archivo de 800x600).
- **Editar Dart con un script Python: `io.open(p,'w')` trunca el archivo** y un error posterior lo
  deja en **0 bytes**. Hay que armar el contenido entero y escribir una sola vez. Y copiar
  indentación a ojo falla en silencio.
- Un spinner tiene que verificarse **mirándolo**: la primera versión de `SquaresSpinner` tenía la
  onda al revés y el frente deslizándose entre cuadrados, y ambos defectos pasaban el test de
  "son 8 cuadrados". `test/goldens/` tiene un golden por cada uno de los 8 pasos del ciclo.
- Un guard que mira el canal **alfa** es vacío si los colores son opacos: el spinner mezcla dos
  colores sólidos, así que los 8 alfa dan 1.0. Hay que medir **luminancia**.
- **Un guard verde no es un guard: hay que romperlo y verlo morir.** Y hay que romperlo en el
  punto donde el otro camino no lo tapa. Ejemplo medido: `_accept` sin limpiar el disparador
  pasaba el test con `/` porque la regla de "comando ya elegido" cerraba el menú igual; con `@` el
  bug aparece. En un test de widget, `LayerCatalog.forTest({'chat.composer': true})` **apaga** todo
  el compositor (`isOn` es `false` para keys ausentes), el `TextField` no existe y los tests
  **pasan sin encontrar nada**: hay que listar las 12 keys del composer, como hace
  `chat_render_test.dart`.
- `/api/health` no existe ⇒ `/api/location`.
- Un control dibujado sin destino es un bug, no un TODO. `FileAction.diff` sigue sin destino
  y **lo dice** con un toast; `FileAction.open` ya no.
- `LayerCatalog.isOn` es `_overrides[key] ?? _defaults[key] ?? false`: una clave **desconocida
  apaga el control en silencio**. Por eso `test/layer_keys_test.dart` compara cada `LayerGate` y
  cada `isOn` contra `spec/layers.json`: sin ese gate, un typo deja un botón invisible y la app
  "anda". La spec tiene 94 claves y un contrato que las cuenta: una capa nueva se agrega ahí
  primero, no después.
- El APK se compila **arm64-only** (`publish-update.ps1`): 26,8 MB contra 73,6 MB del universal.
  Medido en el publicado: `arm64-v8a` 24,8 MB y 0,1 MB de restos en las otras dos ABIs.
- `flutter build apk` compila **feliz** un manifest inválido. El parser de Android solo avisa al
  instalar (`INSTALL_PARSE_FAILED_MANIFEST_MALFORMED`). Antes de publicar: `aapt2 dump xmltree
  --file AndroidManifest.xml <apk>` y mirá que no haya dos `action` seguidos.
- PowerShell 5.1 devuelve **500** contra el redirect de assets de GitHub aunque la URL responda
  200: toda verificación de red por script va con `curl.exe`, no con `Invoke-RestMethod`.
- **`publish-update.ps1 -Version` no bumpea `pubspec.yaml`.** Nombra los releases y escribe
  `latest.json` bien, pero el APK compilado conserva el `versionCode` viejo (medido: release
  v1.7.0 sirviendo `versionCode=11` con el manifiesto anunciando 12). El autoupdate entonces
  ofrece la descarga para siempre, porque la versión interna nunca alcanza a la del manifiesto.
  **Hay que bumpear `pubspec.yaml` antes de compilar.**
- **GitHub sirve el asset viejo desde caché** si se re-sube con el mismo nombre: la verificación
  tiene que llevar un cache-buster (`?nc=<epoch>`), si no lee la versión anterior y hace creer
  que la publicación falló.
- **`Start-Process -ArgumentList` parte los argumentos por espacios**: un `-Notes "a b c"` hay
  que entrecomillarlo o el script aborta con *"No se encuentra ningún parámetro posicional"*.
- Windows PowerShell 5.1 **no se puede desinstalar**: es componente del SO y su binario está en
  control de `TrustedInstaller`. La defensa es negarse a correr bajo 5.1, no borrarlo.
- Un **test** que afirma algo que la medición desmentió se adjudica **en el lugar**, con el motivo
  escrito en el archivo. Editar un test para que pase está prohibido; corregir su premisa no.
- `dart format lib test` reescribe archivos de otros si hay trabajo sin commitear: commitear
  antes de formatear.

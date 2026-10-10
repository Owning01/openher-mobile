# PROJECT_MEMORY — OpenHer Mobile

Bitácora append-only. Una entrada por trabajo sustantivo.

---

## 2026-09-28 — Diseño de las vistas mobile (fase de diseño, sin código aún)

- **Qué:** se diseñó la app Android mobile como cliente delgado **directo al server
  opencode** (no a OpenHer). Se creó el proyecto `G:\Proyectos\openher-mobile` con el
  contrato de API medido, el super plan y una maqueta HTML navegable con toggles de capas.
- **Por qué:** el usuario pidió vistas mobile que se vean bien, carguen rápido, y un plan
  maestro antes de escribir código. Se eligió hablar directo a `:4098` para no arrastrar la
  dependencia de OpenHer (`:4848`/`:4849`).
- **Evidencia:** servidor real `127.0.0.1:4098` medido con `Invoke-RestMethod`:
  - `GET /api/session` → `200`; `GET /api/session/{id}/message` → `200` con
    `{data,cursor}` y `content[]` embebido (generación **v2**, no la v1 `parts[]`).
  - `GET /api/session/active` → `200` con sesiones `running` reales.
  - Auth: `opencode:<password>` → `200`; otra → `401`.
  - `GET /api/health` → **404**; `GET /api/location` → **200** ⇒ ése es el probe real.
  - `GET /vcs/diff` sin `mode` → 400; con `?mode=working` → 200.
- **Sorpresas / trampas descubiertas:**
  - `service.json` **NO existe en opencode2** (es convención de OpenHer). La auth real
    viene de `OPENCODE_SERVER_PASSWORD` / `OPENCODE_SERVER_USERNAME` (default `opencode`).
    En Android no hay disco del PC ⇒ credenciales por UI + secure storage.
  - El catch-all del SPA devuelve **HTML 200** en paths desconocidos ⇒ `FormatException`
    si el parser no rechaza `text/html`.
  - El heartbeat v2 es un **comentario SSE** (`: heartbeat`), no un evento.
  - La atribución de "otro agente" **no es un campo `from` del server**: en opencode2 sale
    de `assistant.agent` + `mode:"subagent"` + el tool `subagent` (`input.description`).
    (El `metadata.from` que usa la web es un campo *local* de OpenHer, añadido por plugins.)
  - El cliente de escritorio **descarta `session.error`** (sin case en `_onSseEvent`):
    bug conocido; el móvil lo maneja (canal C).
- **Pendiente:** el prototipo HTML lo está construyendo un worker; después, tribunal
  (critic/challenger/auditor) y recién entonces M0 (`flutter create`).

## 2026-09-28 — M0 arranque + spec de capas congelada (el usuario aprobó la maqueta)

- **Qué:** el usuario exportó la config de capas del prototipo (94 total, 90 activas) y
  dijo "armá todo". Se congeló `spec/layers.json` como contrato de diseño, se creó el
  proyecto Flutter (`flutter create`, org `ai.openher`), se configuró Android y se
  despachó el enjambre de M1/M2.
- **Capas apagadas (4) — NO se implementan:** `chat.appbar.subtitle`, `chat.composer.counter`,
  `chat.composer.tsl`, `chat.header.progress`. Es decir: sin subtítulo de modelo en el app bar,
  sin contador de caracteres, sin chip TSL, sin barra de progreso del turno.
- **Por qué congelarla en JSON:** convierte "saqué lo que no quiero" en una regla
  verificable. `test/layer_contract_test.dart` falla si una capa activa no tiene archivo, o
  si una apagada aparece mapeada. Es un test que hoy falla a propósito (meta) y cada fase lo
  reduce.
- **Evidencia:** `flutter create` OK; `flutter pub get` → 55 deps. Deps agregadas: `http`,
  `flutter_secure_storage`, `speech_to_text`, `flutter_svg`, `shared_preferences`.
  Android: label "OpenHer Mobile", permisos INTERNET/ACCESS_NETWORK_STATE/RECORD_AUDIO,
  `network_security_config.xml` para cleartext en loopback/LAN/Tailscale (el server es HTTP
  plano; Android 9+ lo bloquea).
- **Decisiones de ejecución:** enjambre con propiedad exclusiva de archivos:
  Worker-Theme (`lib/ui/core/{tokens,theme}.dart` + tests), Worker-Models
  (`lib/domain/models/*.dart` + test), Worker-Network (`lib/core/network/*.dart` + 2 tests).
  Yo: pubspec, manifest, network config, spec y el test de contrato de capas.
- **Trampa del enjambre:** los tres workers escriben a la vez; `flutter analyze` a mitad de
  camino muestra errores transitorios (p.ej. `tokens.dart` a medio importar). No corregir
  archivos de otro worker: se verifican al final.
- **Pendiente:** tribunal sobre M1/M2 (critic/challenger/auditor) antes de M3.

## 2026-09-28 — M0–M3 construidos, repo en GitHub, enjambre de UI en marcha

- **Qué:** `flutter create` + tokens/tema (M1) + modelos y cliente REST/SSE (M2) + shell
  con bottom-nav, Conectar, Ajustes y lista de Sesiones (M3). Todo commiteado por fase.
  Repo creado: `Owning01/openher-mobile` (público, sin push todavía — el push es uno solo
  al final). Workers de Chat y Archivos en paralelo.
- **Decisión corregida por medición (D3):** el stream por sesión `/api/session/{id}/event`
  **da 404** en `:4098`. El que funciona es el **global `/api/event`** (con `durable.seq`).
  El probe real es `/api/location`, no `/api/health`.
- **Por qué las capas importan:** la spec de 94 capas congelada hace que "saqué lo que no
  quiero" sea un test (`layer_contract_test.dart`) y un toggle en vivo en Ajustes, no una
  promesa. `LayerGate` implementa `PreferredSizeWidget` para poder apagar un AppBar entero.
- **Evidencia:** 152 tests en verde tras M2; el arranque de la app (sin credenciales ⇒
  pantalla Conectar) verificado con `test/widget_test.dart`. El worker Connect/Settings
  entregó 52 tests. M3 commiteado (`cc82efd`).
- **Worker de red cancelado a mitad:** dejó api_client/sse_client/tests escritos pero con
  la API de errores adivinada. Los alineé a `errors.dart` real y corregí 3 tests que
  asumían v1. El modelo de errores ahora incluye `UnsupportedServerError` (para el probe).
- **Trampa de integración:** el viewmodel de sessions importaba `sessionrepository.dart`
  (sin underscore): en Windows no falla, pero rompe el build case-sensitive. Corregido.
- **Pendiente:** Chat (worker) y Archivos (worker) → tribunal → APK release → push único →
  APK a `Owning01/mis-apps`.

## 2026-09-28 — Serie de bugs vivos: siete correcciones, todas medidas

- **El envío fallaba por tres bugs encadenados**, y ninguno era de Flutter. `Content-Type:
  application/json` nunca se mandaba en los POST (415); el prompt exigía `text` en la **raíz**
  (`Missing key at ["text"]`, 400); y `createSession` mandaba `location` como string donde el
  schema v2 quiere `{directory}`. El 2 y el 3 explican el "se borra del chat": el POST fallaba
  y la burbuja optimista se descartaba en silencio. Verificado punta a punta contra `:4098`.
- **Botones muertos, todos del mismo tipo:** `onDictate`, `onPickAgent`, `onAction` y `onAttach`
  existían en el composer y en la vista y **nadie los pasaba**. Los cuatro eran controles
  dibujados sin nada detrás. El patrón se repitió cinco veces: un callback declarado en el
  widget y nunca conectado. Queda como regla: un `onX` sin su `call` en el constructor es un bug.
- **Cargar mensajes anteriores no fallaba: devolvía una página vacía.** `cursor.previous` va hacia
  lo **nuevo** y `cursor.next` hacia lo **atrás** (medido con 200 mensajes). Además la página
  llega de más nuevo a más viejo y se insertaba sin invertir, así que el bloque quedaba al revés.
- **`session.status` e `session.idle` no existen en v2.** El botón Detener se quedaba pegado
  porque el flag de turno nunca se cerraba. Lo real es `session.execution.started/succeeded`, y
  en modo polling el cierre llega en el mensaje `{"type":"idle"}` de la página.
- **Compactar y Deshacer:** faltaban los bodies. `compact` sin body da 400 `Expected object`; con
  `{}` da 200. `revert/stage` exige `messageID`.
- **Herramientas agrupadas por turno**, al pie de la letra de
  `opencode-remote-android/web/src/utils/turnActivity.ts` (leído, 107 líneas): una caja por turno,
  montada en el primer assistant, con los resultados de shell fuera de la propiedad. Antes había
  una caja por mensaje y se abría sola mientras el turno trabajaba.
- **Un spinner eterno:** un tool en `running` con el turno ya cerrado es uno interrumpido que el
  server dejó colgado. Ahora el `ToolCard` sabe si el turno vive.
- **Auditoría del stream:** de 24 tipos de evento que manda el server, la app atendía 11. Faltaban
  los dos que se ven: `session.usage.updated` (el costo y el contexto quedaban congelados) y
  `session.renamed` (el server titula solo y el chat mostraba `ses_0acd172…`).
- **Un RangeError real de la app** lo encontró un test: `messages[index]` sin descontar las filas de
  encabezado reventaba la pantalla con el aviso de reintento visible.
- **Evidencia:** 686 tests en verde, `analyze lib` en cero. APK 1.2.0+7 publicado y verificado con
  `aapt2`; releases anteriores borradas en ambos repos. Commits `5dbc557`, `72c9661`.

## 2026-09-28 — Autoupdate, modo de datos móviles, modelos, agentes y 61 temas

- **Autoupdate silencioso** contra `releases/latest/download/latest.json`, comparado por
  `versionCode` leído del paquete instalado (Android rechaza un code igual o menor). Banda no
  bloqueante, sin diálogos. Con datos móviles no baja solo: son 53 MB y la decisión es del usuario.
  Plataforma: `REQUEST_INSTALL_PACKAGES`, `FileProvider` y canal `ai.openher/install`.
- **Modo de bajo consumo automático sólo con red celular** (`connectivity_plus`): sin streaming,
  polling de 2 s a 12 s, página de 30 a 15, imágenes apagadas. La red manda; el override solo
  puede **bajar**.
- **102 modelos y 20 agentes** conectados a la sesión viva. Los niveles de pensamiento son las
  `variants` del modelo, no un campo aparte; 75 de 102 modelos las tienen. De las 12 acciones del
  menú, 7 se fueron: el dialecto v2 no expone endpoint para ninguna y un botón inerte promete
  algo que no se puede cumplir.
- **61 temas de color** portados del escritorio (33 oscuros + 28 claros), con selector en Ajustes.
  `light()`/`dark()` pasan por el mismo `_base(palette)`: una variante cambia colores y no puede
  cambiar layout.
- **Pendiente que se dejó anotado:** el scope de código no se recolorea con la variante
  (`message_bubble` lee `AppColors.*CodeBg` de los tokens). Es del owner de chat.

## 2026-09-28 — Enseña: medir contra el server, no contra el spec

- El módulo entero falló en vivo por haber escrito el cliente **leyendo el spec**. Los tres
  content-type/body/location, el cursor al revés, `order`+`cursor`, el 204 sin cuerpo, los
  `variants` como niveles de pensamiento: todos salieron de medir, ninguno de leer.
- Regla que queda: **toda afirmación sobre el server se mide con un comando antes de escribirla**,
  y cuando aparece un bug cuya premisa contradice un test, se adjudica en el lugar con la
  evidencia escrita en el archivo.
- El test que afirmaba "`session.execution.*` no está en el protocolo" era el que ocultaba el
  botón Detener. Editar tests para que pasen está prohibido; corregir una premisa que la
  medición desmentió es lo contrario, siempre que quede escrito por qué.
- Trampa de proceso que costó trabajo: `dart format lib test` reescribió archivos de otro agente.
  La causa fue correr el formateo global con trabajo sin commitear en el árbol.

## 2026-09-28 — Visor de archivos + dos bugs de release que rompian la instalacion

- **Que se pide**: ver imagen, video, audio, PDF, markdown y codigo desde Archivos.
  `FileAction.open` existia desde el primer dia como un boton **muerto** ("se muestran, pero no se
  pueden apretar"): el quinto caso del patron de control dibujado sin destino.
- **La medicion que lo habilita**: `GET /api/fs/read/<path>` **no es un endpoint de texto, devuelve
  los bytes crudos con el `Content-Type` correcto**. Probado con un APK de 56 MB
  (`application/vnd.android.package-archive`, 56.318.889 bytes), un PNG, un SVG, un PDF y un `.md`.
  No hay otra via: `/api/fs/raw/*`, `/api/fs/download/*` y `/api/file/*` dan 404, y las rutas sin
  prefijo caen en el catch-all del SPA. Acepta `\` y `/` (server Windows manda `\`).
- **Que se agrego**: `domain/models/file_type.dart` (clasificador por extension, 9 tipos) y
  `ui/features/files/file_preview.dart` (el visor). Deps: `video_player` 2.14.0 y `pdfrx` 2.4.8.
  `ServerConfig.fileUrl` + `binaryHeaders` para la URL y el header Basic.
- **BUG CRITICO, encontrado al instalar**: el `<queries>` del manifest tenia **un `<intent>` con dos
  `<action>`** (`PICK` + `GET_CONTENT`). Android rechaza el APK entero con
  `INSTALL_PARSE_FAILED_MANIFEST_MALFORMED: intent tag may have at most one action` (medido con
  `aapt2 dump xmltree` y al instalar). **1.1.0 y 1.2.0 nunca fueron instalables**: el telefono seguia
  en 1.0.0+5 y yo creia que estaba en 1.2.0. Arreglado partiendolo en dos `<intent>`.
  Lección: `flutter build apk` compila happily un manifest invalido; solo `pm install` lo dice.
- **APK 73,6 MB -> 26,8 MB**: el universal empaqueta 3 ABIs y `libpdfium.so` solo son 16,4 MB (3
  copias). `publish-update.ps1` ahora compila `--target-platform android-arm64`, con el costo
  anotado (se pierde 32 bits y emulador).
- **Trampa de pdfrx**: la version 2.4.8 NO tiene `Pdfrx.instantiate` ni `PdfrxDocument.uriParser`;
  son `PdfViewer.uri(uri, headers: ...)` y `PdfDocument.openUri`. Acepta headers, asi que no hace
  falta el truco del `auth_token` en el query.
- **Sin verificar**: el visor **no se pudo probar en el handset** - el Xiaomi quedo `offline` para
  adb en el medio de la sesion. El codigo esta medido contra el server y con `flutter analyze` y los
  686 tests en verde, pero el render en pantalla no esta comprobado.
- **Pendiente**: `FileAction.diff` sigue sin destino (ahora lo dice con un toast en vez de fingir).

## 2026-09-29 — HTML al navegador, filtro de subagentes, favoritas y aviso de Tailscale

- **Visor de HTML**: se parsea el DOM con `html` (Dart puro) y se dibuja con widgets; hay toggle
  **Vista/Fuente**. El escritorio **no** hace esto (`mediaKindFromPath` cae `.html` en `text`): es
  capacidad nueva. El `.html` además se puede **abrir en el navegador del sistema** (acción
  `FileAction.openInBrowser`), que es donde hay CSS y JS de verdad.
- **CORRECCION IMPORTANTE, medí mal dos veces**: (1) dije que `?auth_token=` daba 404; era porque
  no pasé `location[directory]`. Repetido bien: **funciona en todo `/api/*`**, incluido `fs/read`,
  y el server **no emite cookie**. (2) dije que `parentID` no venía en la lista; sí viene, y **se
  omite cuando está vacío**. Miré una sesión principal y concluí que el campo no existía. Las dos
  decisiones que tomé sobre esas premisas estaban mal.
- **El filtro de subagentes es gratis**: `parentID` en la lista, 483 principales / 517 subagentes
  sobre 1000, sin un request extra. Regla textual del escritorio (`SessionList.tsx`): principales =
  `!parentID`, ni hijas con padre vivo ni huérfanas. La app suma un interruptor para verlos.
- **Favoritas**: un `string[]` **ordenado** de ids en `shared_preferences` — port exacto de
  `useLocalStorage(FAVORITES_KEY, [])` del escritorio. Sección FAVORITAS arriba, y una sesión
  marcada **no** se repite en su día. El server no tiene favoritas (medido), así que las del
  escritorio y las del celu son listas distintas: no hay puente.
- **Aviso de Tailscale**: en Android **Tailscale se registra como VPN** (medido: hay un
  `NetworkAgent` de VPN en `dumpsys connectivity` y el ícono VPN en el status bar), así que la señal
  es `ConnectivityResult.vpn`, sin ping ni heurística. Se avisa **sólo** si el server no responde
  **y** no hay VPN: con VPN prendida el problema es el server y culpar a Tailscale sería mentira.
  El botón abre `tailscale://` y, si no está, la ficha en Play. `url_launcher` ya estaba en el APK
  como transitiva.
- **BUG QUE SOLO APARECIÓ EN EL TELÉFONO**: `FileAction.open` y `diff` estaban con
  `onPressed: null`, o sea `clickable="false"` en el árbol de accesibilidad: el visor era
  **inalcanzable al toque** aunque `analyze` y los tests de contenido estuvieran en verde. Hay un
  guard (`ninguna accion de la hoja queda sin destino`) que se verificó rompiéndolo a propósito.
- **Guard systemic nuevo**: `test/layer_keys_test.dart` compara cada `LayerGate`/`isOn` contra
  `spec/layers.json`. Encontró que `isOn` devuelve `false` para claves desconocidas, así que un
  typo deja un control **invisible sin error**. Se verificó rompiéndolo.
- **Workspace del E2E**: el server sirve desde su cwd (el home), no desde el proyecto, así que el
  material de prueba vive en `%USERPROFILE%\openher_e2e\`. `adb reverse tcp:4098 tcp:4098` es lo
  que hace que el teléfono llegue al server.
- **Sin verificar en el handset**: la lista de sesiones filtrada, las favoritas y la banda de
  Tailscale (el Xiaomi se desconectó de USB al final de la sesión). El visor de HTML **sí** quedó
  verificado con capturas.

## 2026-09-29 — Sonda de datos: cuanto consume la app y donde se puede recortar

- **La sonda**: `test/data_probe_test.dart`. Levanta un `HttpServer` local que **reenvía** cada
  request al server real y anota bytes de subida y bajada, y después maneja las **clases reales**
  (`ApiClient`, `SessionRepository`, `ChatViewModel`) contra ese espejo. Cada byte queda atribuido
  a la llamada que lo pidió. Corre con `flutter test` (un `dart run` no puede: el código de la app
  tira de `dart:ui` vía `connectivity_plus`). Con `--dart-define=PROBE_THROTTLE_KBPS=128` simula
  una radio, y ahí también mide **tiempo**, no sólo bytes.
- **HALLAZGO 1 — el poll de cellular se lleva la página entera**. `GET message?order=desc&limit=15`
  pesa entre **17 KB y 220 KB** según la conversación (medido en varias corridas sobre sesiones
  reales). Con el timer real del viewmodel (`DataPolicy.lowData()`, 12 s) eso son **8 a 66 MB por
  hora**, y **47 a 400 MB** si el chat queda abierto 6 h. La carga inicial son 2 requests.
- **HALLAZGO 2 — hay una optimización de 2.268x y ya estáAlmost hecha**. El server devuelve
  `cursor.previous` en cada página y `GET message?cursor=<previous>` devuelve **0 mensajes y 50
  bytes** cuando no hay nada nuevo. La app usa `limit`+`order=desc` y descarta el cursor. Medido en
  la misma sesión: **113,4 KB el refetch contra 50 B con el cursor**.
- **HALLAZGO 3 — el stream es global y no se puede filtrar en el server**. `/api/event` trae los
  eventos de **todas** las sesiones y el filtrado es del cliente, así que los bytes de las sesiones
  ajenas ya se descargaron. Medido: 172,3 KB en 20 s repartidos en **5 sesiones**, de los cuales sólo
  4,7 KB eran de la sesión abierta: ~97% del tráfico se descarga para tirarlo. Con el server
  quieto el stream es sólo heartbeat, así que **no se puede fijar un total**: depende de la
  actividad. No hay endpoint por sesión (medido: el `?sessionID=` global da 400), así que el
  recorte es del lado del cliente.
- **Lo que SÍ anda bien**: con streaming (wifi) la app **no pollaea** (medido: 0 polls en 26 s,
  por diseño: `if (!streamingEnabled) _startPolling()`), la subida es **0 B** (todo GET sin body), y
  la latencia en loopback es 11-18 ms.
- **Trampa de la sonda (mía, dos veces)**: el espejo anota los hits **asíncrono**, así que un
  `reset()` sin asentar mete requests de la medición anterior. Pasó dos veces: el poll salió "x2" y
  el cursor "172 KB" donde iban 50 B. Ahora hay un `settle()` antes y después de cada medición, y un
  assert que exige **exactamente 1 request** por poll: un `0 B` sin request registrado es un
  defecto de la sonda, no una medición.
- **Confusión que casi reporto como bug**: la primera corrida dio 0 polls y parecía que el polling
  no arrancaba. No era así: `_startPolling` sale de `setVisible(true)` (lo llama `chat_view` en su
  `initState`), no de `load()`. La sonda no lo llamaba.

## 2026-09-29 — Mensajes en cola, spinner de 8 cuadrados, y el poll con cursor

- **Los mensajes en cola se perdían** (el bug reportado): al mandar con el agente trabajando, el
  server responde **409 Conflict** (declarado en el spec de `/api/session/{id}/prompt`) y la app
  **borraba el mensaje optimista**. El texto que el usuario acababa de escribir desaparecía sin
  rastro. Ahora `send()` marca `UserMessage.notDelivered` y lo deja en pantalla con un chip
  "No se envío · Reintentar" **dentro de la burbuja** (un banner no diría cuál de los mensajes
  falló). `retrySend(id)` vuelve a hacer el POST. Hay un test nuevo del reintento.
- **Test adjudicado, no editado para pasar**: `chat_viewmodel_test.dart` afirmaba que un 429
  tenía que *sacar* la burbuja optimista, y eso era lo implementado. La medición lo desmentía.
  Se reescribió **en el lugar, con el motivo escrito en el archivo**, y se agregó el caso del
  reintento al lado.
- **Spinner rectangular de 8 cuadrados** (`lib/ui/features/chat/squares_spinner.dart`), en el pie
  de la lista mientras el agente piensa. Va **sin `LayerGate`**: la línea de progreso de 2 px
  vivía en `chat.header.progress`, que es una de las 4 capas apagadas del catálogo, y por eso
  no se veía nunca.
- **Dos defectos del spinner que sólo aparecieron al mirar la imagen** (`test/goldens/`):
  1. La primera versión usaba `d = head - index`, con lo cual **todo** cuadrado por delante del
     frente salía en brillo pleno: la grilla se veía entera encendida y no se leía movimiento.
  2. El frente **se deslizaba** entre cuadrados, así que en las fases intermedias ninguno
     llegaba a brillo pleno (máximo ~0.72) y en tema oscuro la grilla se **desaparecía**. Ahora
     la cabeza **salta** (`.round()`), y la distancia es **módulo `squares`**: el final del
     ciclo y el principio dan la misma imagen, así que el reinicio no se ve.
- **Medido, no estimado**: contraste entre la cabeza y la grilla 92.7 en claro y 120.6 en oscuro
  (luminancia 0..255). La versión con gris translúcido daba 25.6: la grilla pesaba más que la
  cabeza. La grilla en reposo pasó a ser un **tinte del fondo** (`Color.lerp(surface, …)`), que
  funciona igual en los dos temas.
- **El poll del chat no re-descarga la página**: era un `refresh()` de 25.511 bytes cada 2 s. Ahora
  pregunta con `cursor.previous`, que sin nada nuevo pesa **50 bytes**: **510x**. Medido contra el
  server real, no estimado. `refresh()` sigue siendo la verdad de fondo para `setVisible` y los
  eventos del stream.
- **La trampa de esta optimización** (y el guard que la cubre): cuando no hay nada nuevo el server
  devuelve `0 ítems` y **`cursor.previous: null`**. Null ahí significa "no hay nada más nuevo *por
  ahora*", **no** "no hay cursor". Si se guardara el null, el poll volvería a la página completa
  de 25 KB en cada vuelta y la optimización se apagaría sola, en silencio. El cursor viejo **se
  conserva**. El guard (`test/poll_cost_test.dart`) afirma el invariante real: *una vez que el
  ancla está, no vuelve a pedir la página completa*. Mirar sólo "cada poll trae cursor" NO
  alcanza, porque al perderse el ancla el poll cae a la página completa, **que restaura** el
  cursor: la regresión se camufla en una vuelta.
- **Orden de la respuesta con `previous`**: **DESC** (medido: se tomó una página vieja, se le
  pidió su `previous` y volvieron los 15 mensajes del más nuevo al más viejo), o sea igual que
  `order:'desc'`. Por eso el `.reversed`, igual que en `_fetch`.
- **El poll de `/api/session/active` corría con el chat al frente**: las 4 pestañas viven en un
  `IndexedStack`, así que `dispose` no se llama al cambiar de pestaña. `SessionsView` arrancaba el
  poll en su `initState` sin saber si estaba visible: 62 B cada 5 s (~45 KB/h) que nadie mira.
  Ahora el polling lo maneja `_SessionsTab`, que sí recibe `visible`, en `initState` y
  `didUpdateWidget` (y repregunta `pollActive()` al volver al frente).
- **Página en datos móviles de 15 a 8 mensajes**: medido, la página de 15 pesa 25.511 B, o sea
  ~1.700 B por mensaje. 8 son ~13,6 KB (53% menos) y salen 5 KB más baratos que 5. Con cursor,
  `pageSize` sólo afecta la carga inicial; los anteriores van con `loadEarlier`.
- **Errores míos que costaron tiempo, para no repetirlos**: (1) `io.open(p,'w')` **trunca** el
  archivo y un error posterior lo deja en **0 bytes**: armá el contenido entero y escribí una
  sola vez. (2) Leer la indentación a ojo y escribir `6 espacios` donde eran `4` falla en
  silencio. (3) Dos veces se me colaron caracteres CJK en comentarios.
- **Estado**: `flutter analyze` limpio; suite completa **759 verdes, 6 skipped** (incluye 5 guards
  nuevos del poll, 6 del spinner y 2 de la cola, todos verificados rompiéndolos).
- **Lo que NO se pudo verificar**: el APK no se corrió en un teléfono real. El Xiaomi
  `aaiz5tbuq8dqyxqs` sigue cayéndose de USB/adb, así que el spinner y el chip de reintento están
  verificados **por golden y por test**, no en pantalla.

## 2026-09-29 — Publicado 1.7.0+12: el bump de versión no lo hacía el script

- **Al publicar, `publish-update.ps1 -Version 1.7.0+12` NO bumpea `pubspec.yaml`.** Nombra los
  releases y escribe `latest.json` correctamente, pero el APK compilado conserva el `versionCode`
  viejo. Medido: el release v1.7.0 quedó sirviendo `versionCode=11` / `versionName=1.6.0` con el
  manifiesto anunciando 12 / 1.7.0.
- **Cómo rompe**: el autoupdate compara la versión del manifiesto contra la interna. Como la
  interna nunca llega a la del manifiesto, la app **ofrece la actualización para siempre** y
  vuelve a descargar el mismo APK. Es la peor falla posible en autoupdate: no se ve, sólo se
  siente en la factura de datos.
- **Corregido**: `pubspec.yaml` en `1.7.0+12`, recompilado y republicado. Verificado con `aapt2`
  **sobre el archivo BAJADO del release** (no sobre el local): `versionCode=12`,
  `versionName=1.7.0`, 28.581.299 bytes, descargable desde los dos repos.
- **La verificación del propio script dio un falso negativo** la primera vez: el error fue
  *"el manifiesto publicado dice versionCode 11 y esperábamos 12"*, cuando el manifiesto ya
  decía 12. Es **caché de GitHub**: el asset re-subido con el mismo nombre se sirve viejo. Hay que
  verificar con cache-buster. La segunda corrida, con el pubspec ya bumpeado, dio
  "OK 1.7.0 (12) publicado y verificado".
- **Manifest verificado antes de publicar** (la trampa del APK no instalable): 12 `<intent>` en
  `<queries>`, **todos con exactamente 1 `<action>`**. arm64 pesa 26.495.544 B; armeabi-v7a y
  x86_64 son restos de 86 KB y 123 KB. APK final 27,26 MB.
- **Dos trampas de Powershell**: `Start-Process -ArgumentList` parte los argumentos por espacios,
  así que un `-Notes "a b c"` hay que entrequillarlo (si no, *"No se encuentra ningún parámetro
  posicional que acepte el argumento"*), y `Set-Content -Encoding UTF8` mete **BOM** en los
  archivos de mensaje de commit, que queda pegado al asunto en `git log`.
- **El commit del arreglo del botón Detener se coló** en el commit de performance: los dos cambios
  están en `_fetch`. Lo rehíce como un commit `fix+perf` con el mensaje exacto, porque partirlo
  exigía cirugía de hunks sobre el mismo método y dejaba estados intermedios que no compilan.
- **Estado final**: 5 commits, un solo push, `flutter analyze` limpio, **759 tests verdes
  (6 skipped)**, árbol limpio, publicado en `Owning01/openher-mobile` (v1.7.0) y en
  `Owning01/mis-apps` (openher-mobile-v1.7.0).
- **Lo que sigue sin poder verificarse**: nada se probó en un teléfono real. El Xiaomi
  `aaiz5tbuq8dqyxqs` sigue sin aparecer en `adb devices`. El spinner y el chip de reintento están
  verificados por golden y por test, no en pantalla. La primera vez que se abra el APK hay que
  mirar esos dos elementos.

## 2026-09-29 — Los comandos `/` y `@` no existían, y el contexto mintía por 115x

- **El menú de `/` y `@` no estaba implementado.** No era un bug de lógica: `composer.dart`
  no tenía ninguna noción de disparador, y `api_client.dart` no tenía `listCommands`,
  `listSkills` ni `listMcpResources`. `grep` sobre `lib/` encontrava `command` sólo en el
  modelo del mensaje de shell.
- **El server expone 3 comandos, no los 16 que anuncia el cliente web.** `GET /api/command`
  devuelve `init`, `review` y `debate`. El cliente web de OpenHer los mezcla con 13
  hardcodeados en `composerData.ts` (`compact`, `undo`, `redo`, `themes`, `history`, …) y por
  eso "no funcionan": medido, todos dan **404** en `POST /api/session/{id}/command`. La app
  muestra la lista del server y, aparte, ofrece `compact`/`undo`/`redo` porque esos **sí
  existen**, como endpoints (`POST /compact`, `POST /revert/stage` + `/revert/commit`).
- **Contrato de `/command`, medido del OpenAPI del server** (`GET /openapi.json`): el body
  exige `{name, text}`, ambos requeridos, `additionalProperties: false`. El campo se llama
  **`name`**, no `command` (mandar `command` da 400 `Missing key ["name"]`), y el `name` va
  **sin barra** porque el lookup del server es exacto (`/review` da 404). El strip va en
  `ApiClient.runCommand` y no en el caller, porque la UI pasa lo que el usuario escribió.
- **El contexto mentía por 115x.** `serverTokens` devolvía `session.tokens` —un **contador
  acumulado** de toda la vida de la sesión— con la etiqueta "contexto". Medido sobre
  `ses_f685c4cfdffe7Bp2IL`: la app mostraba `19.892.436` donde el contexto real era **195.089**.
  El contexto es el prompt del **último** assistant: `input + cache.read + reasoning`.
  `cache.write` queda fuera (lo relee el próximo turno) y `output` también (es lo generado).
  El getter nuevo es `TokenUsage.context`; `contextTokens` lo usa, y `serverTokens` desapareció
  para que no quedara el nombre viejo con la definición nueva.
- **Había un tercer bug de contexto, más chiquito y peor**: el valor vivo del SSE
  (`_applyUsage`) sumaba `input + output + cache.read` y el respaldo sumaba el acumulado de
  la sesión. O sea el **mismo rótulo significaba dos cosas** según el SSE estuviera conectado o
  no. Ahora los dos caminos usan `TokenUsage.context`.
- **El porcentaje se agregó y es el número que sirve**: sin ventana, "195k" no dice si es mucho
  o poco. La ventana sale de `ModelInfo.contextLimit` del catálogo, cacheada por
  `provider/id` (dos providers pueden tener modelos con el mismo id y ventanas distintas).
- **El disparador se detecta en un archivo aparte** (`composer_suggestions.dart`) sin
  `BuildContext`, porque la parte con reglas se rompe en silencio y probarla exige montar el
  árbol de widgets entero, lo que vuelve tautológico el test. Reglas medidas contra el cliente
  web: `/` y `@`
  sólo al principio o tras espacio (si no, `http://` y `C:/Users` abren el menú), y con un
  espacio el comando ya está elegido y el menú **no** se reabre — sin eso el Enter queda
  atrapado en un ciclo completar→reabrir→completar y hay que apretarlo dos o tres veces.
- **Las fuentes del `@` pesan mucho**: `/api/skill` son **490 KB** y `/api/agent` 87 KB. Se
  cargan una vez por chat; los archivos van con debounce de 150 ms y descarte por token, para
  que una búsqueda lenta que llega tarde no pise el resultado de la nueva.
- **`/api/mcp/resource` devuelve un objeto, no una lista**: `data` es
  `{resources[], templates[]}`. Una comprensión de lista sobre eso daría un menú vacío
  **en silencio**, que es el peor modo de falla.
- **Un `directory` inexistente da 500, no lista vacía.** Se distingue de la lista vacía
  legítima (200 + `data: []`). El aviso de error va **una vez** por disparador
  (`_suggestionsFailed`), porque el menú se pide al tipear y sin eso el mismo error saldría
  en pantalla en cada tecla.
- **`revert/commit` responde 204, no 200.** El test acepta cualquier 2xx para no atar la app a
  un detalle del server que puede cambiar; `postJson` ya tolera el 204.
- **Guard verificados rompiéndolos** (7 de 7 muerden): el `name` con barra, el 404 del comando
  tragado, el `mcp/resource` leído como lista, el menú reabriendose con espacio, `/compact` yendo
  al endpoint de comandos, la frontera del disparador, el rango comiéndose la frase de atrás,
  y `_accept` sin limpiar el disparador. Este último necesitó un test con `@` y no con `/`:
  con barra, la regla de "comando ya elegido" cerraba el menú **igual** y el bug pasaba
  inadvertido. Un guard verde no es un guard: hay que Romperlo y verlo.
- **Trampa de este día — el catálogo de capas en un test nuevo**: probar con
  `LayerCatalog.forTest({'chat.composer': true})` hace que **todo** el compositor desaparezca,
  porque `isOn` devuelve `false` para una key ausente: `.input`, `.send`, `.mic` y
  `.modelbar` quedan apagados, el `TextField` no existe y los tests **pasan sin encontrar
  nada**. Hay que listar las 12 keys del composer, como hace `chat_render_test.dart`.
- **Trampa de encoding, la segunda del día**: `flutter test` escribe bytes que cp1252 no
  decodifica, así que un script Python con `text=True` y `capture_output` tira
  `UnicodeDecodeError` **y se muere sin restaurar los archivos que estaba rompiendo a mano**.
  Hay que `decode('utf-8', 'replace')` y un `try/finally`.
- **Otro patrón de needle que falla en silencio**: los archivos tienen CRLF, así que un
  patrón con `\n` pelado nunca matchea y el script reporta "NO SE PUDO ROMPER" cuando el
  código sí estaba donde debía. Es peor que un error: hace creer que el guard no muerde.
- **Estado**: `flutter analyze` limpio, **837 tests verdes (6 skipped)**, 5 archivos nuevos de
  test y uno de lib. E2E contra el server real en `%TEMP%\e2e_slash.py`: las 4 fuentes, los 3
  caminos de escritura, y el contraste del contexto. **Nada verificado en un teléfono**: el
  Xiaomi `aaiz5tbuq8dqyxqs` sigue sin aparecer en `adb devices`, así que el menú, el spinner
  chico y el layout con el teclado abierto están verificados por test, no en pantalla.

## 2026-09-30 — La pantalla de sesiones traía 59 de 654

- **Síntoma**: "no me está trayendo todas las sesiones". **Causa**: `SessionRepository.list`
  pedía **una** página de 100 y nunca usaba el `cursor`. No era el filtro de la
  pantalla (ese está bien y está medido: `parentID` presente ⇒ subagente, y el
  interruptor está apagado por defecto), era que la lista se cortaba.
- **Medido 2026-09-30 contra el server real**: hay **2.000 sesiones** (654 principales, 1.346
  subagentes). `limit=100` devuelve 100 de las cuales sólo **59 son principales**: **595
  sesiones del usuario quedaban invisibles sin ninguna señal**. Y de esas 100, 41 eran
  subagentes que el interruptor esconde, o sea que la página se llenaba de filas que la
  pantalla descartaba.
- **`/api/session` sí pagina** con `cursor` (medido: dos páginas con `limit=5` y cursor no
  se solapan). El `ApiPage.next` ya existía y estaba en el repo, sin usar: el doc decía
  "no se pagina todavía" y esa frase costó 595 sesiones.
- **`listAll`**: pide página por página, deduplica por id, ordena por actualización, y corta
  cuando `next` viene `null`, cuando el cursor viene **repetido** (el server no avanzó) o
  al llegar a `kSessionAllPages` (20). El corte por cursor repetido es lo que evita el bucle
  infinito si un build futuro devuelve `next` siempre.
- **El cursor viaja opaco**: la app lo reenvía sin decodificarlo. Hay un test que manda un
  `next` que **no es JSON válido** y verifica que igual llega bien al server: si algún
  día lo empieza a interpretar, ese test lo delata.
- **Lo que NO se repitió en cada visita**: el shell sólo llama `pollActive()` (62 B) al
  volver a la pestaña, no `load()`. Los ~981 KB se pagan **una vez** al crear la pantalla y
  otra sólo con pull-to-refresh. Medido: 20 páginas × 100 = 1.004.762 B.
- **Un test existente cAYó y se adjudicó en el sitio**: `sessions_test.dart` pedía
  `expect(lists, 1)` después de `load`, y con paginación son 2. La causa es el **fixture**,
  no la app: `listJson` mete siempre un `cursor.next`, o sea que jura que hay otra página
  aunque la respuesta traiga los mismos ítems. Se midió como delta (`trasCargar`), que es lo
  que el test quería afirmar (que **filtrar es local**), con el motivo escrito en el archivo.
  Cambiar el assert a `2` habría sido tapar el sintoma; cambiarlo a delta conserva la
  garantía original y la hace más precisa.
- **6 guards verificados rompiéndolos, los 6 mueren**: volver a una sola página (el bug
  original), no mandar el cursor, interpretar el cursor, sacar el tope de páginas, no
  deduplicar, y **que la pantalla vuelva a llamar `list()` en vez de `listAll`**. Ese último
  es el que importa: `listAll` puede estar perfecto y el bug seguir vivo si la vista llama al
  método viejo, y ningún test del repositorio lo vería.
- **Trampa de este día**: adivinar la indentación al escribir un needle falla en silencio y el
  script reporta "no encuentro la llamada" cuando el código está ahí. Pasó tres veces
  seguidas (8 espacios donde había 6). Hay que leer el bloque con los caracteres visibles
  antes de escribir el needle, no contar espacios a ojo.
- **Estado**: `flutter analyze` limpio, **849 tests verdes (6 skipped)**. Nada verificado en un
  teléfono: el Xiaomi `aaiz5tbuq8dqyxqs` sigue sin aparecer en `adb devices`.

## 2026-10-01 - El markdown del chat salia sin color, con los tokens ahi sin usarse

- Sintoma: "no me esta dibujando con colores en el chat". **Causa 1**: los tokens
  `--code-*` de `tokens.dart` estaban portados desde `tokens.css` desde el primer dia
  y **nada los leia**. El bloque de codigo se pintaba con un `Text`, que no admite mas
  de un color, asi que salia entero del color del texto. El paquete `highlight` ni
  estaba en el `pubspec`.
- **Causa 2**: en la hoja de markdown faltaba `em` completo (la cursiva salia del
  color del texto, invisible), el codigo inline iba en `--muted-strong` (un gris mas) y
  la cita en `--muted`. El cliente desktop los tiene en `--warning`, `--success` y
  `tertiary`.
- Arreglo: `lib/ui/features/chat/code_highlight.dart` con el mismo `highlight` que el
  desktop, y la paleta leida de los tokens en vez de hex sueltos. `RichText` en lugar
  de `Text`, y el lenguaje se saca de la clase `language-xxx` del `<code>` hijo, que
  sin eso autodetecta.
- El test verifica que se VE, no que la funcion existe: "un bloque de Dart sale con MAS
  DE UN color" y "el texto no se pierde". 5 guards verificados rompiendolos, los 5
  mueren. Un test que solo comprobara `colorFor('keyword') != null` pasaria con un
  resaltador que no pinta nada.
- Un test existente cayo y se adjudico en el sitio: `message_bubble_test.dart` buscaba
  un `Text` y ahora es `RichText`. El criterio no cambio, solo el finder.
- El cache es por (codigo, lenguaje, brillo, estilo base): el `TextSpan` lleva el color
  embebido, asi que servir el de claro en oscuro dejaria el codigo con los colores del
  tema anterior. LRU de 200; los bloques de mas de 20 KB no se parsean (un parse de
  60 KB es medio segundo de jank en un telefono).
- **No hice golden, y es una decision**: en `flutter test` la fuente por defecto es
  Ahem (cada glifo es un rectangulo negro), asi que un golden con texto saldria como un
  bloque y no serviria para mirar. El propio `squares_spinner_test.dart` lo dice.
- **Trampa del dia, la misma por cuarta vez**: adivinar la indentacion al escribir un
  needle falla en silencio. Paso con 8 espacios donde habia 6, con 4 donde habia 2, y con
  la ternaria a 20 donde estaba a 22. Se resuelve editando por **rango de lineas** con
  un ancla buscada por contenido.
- Estado: `flutter analyze` limpio, **865 tests verdes (6 skipped)**.
## 2026-10-02 - Adjuntar varias fotos de una vez (1.12.0+18)

- El Clip usaba `ImagePicker().pickImage`, que devuelve **un** `XFile`. El selector
  de Android colgado de ahi no deja marcar mas de una: habia que apretar el Clip N
  veces para N fotos. Ahora `pickMultiImage`, que abre el modo multiple, y la tanda
  **se agrega** a `_pending` en vez de reemplazar.
- Los no-imagen se rechazan por extension y se avisa **una** vez, no uno por archivo.
- **Dos cosas mas estaban rotas y no se veian**, y aparecieron al conectar el
  composer: (a) `ChatComposer` nunca recibia `attachments:`, asi que las fotos se
  mandaban bien pero no se veian, y la `x` de cada thumb no hacia nada porque
  `onRemoveAttachment` era `null` y el `?.call` se comia el toque en silencio;
  (b) el `onSend` mergeaba `[..._pending, ...files]`, que con `attachments` ya
  conectado mandaba **cada foto dos veces** (mismo uri, mismo nombre, doble
  payload). Ahora `onSend` usa la lista que el composer ya devuelve: una sola
  fuente de verdad y la duplicacion deja de ser representable.
- Guardas: 5 tests en `test/chat_render_test.dart`, grupo `adjuntar varias fotos de
  una`, fcheando `ImagePickerPlatform.instance` y montando el `ChatView` real. Los
  cuatro caminos rotos a proposito: `pickMultiImage`->`pickImage` caen los 5; sin
  `attachments:` caen los 5; el merge de vuelta cae 1 ("3 fotos, no 6"); sin
  `onRemoveAttachment` cae 1 (la `x`).
- **Trampa de `plugin_platform_interface`**: asignar `ImagePickerPlatform.instance`
  con una clase que use `implements` **falla un assert** ("Platform interfaces must
  not be implemented with `implements`"). Hace falta `extends` + `MockPlatformInterfaceMixin`.
- **Trampa de `cross_file`**: `XFile(path, name: 'a.jpg')` **ignora** el `name`; sale
  de `path.split(pathSeparator).last`. En el host de test el separador es `\`, asi que
  una ruta con `/` no se parte y el `name` sale entero: artefacto de Windows, no un
  bug de Android, y el test lo dice para que nadie lo "arregle".
- `ChatComposer.attachmentThumbKey(i)` es nueva: el thumb va en un `KeyedSubtree`
  porque dos tandas pueden traer el mismo archivo y hace falta poder afirmar "hay 6"
  y "el septimo no existe".
- `pubspec.yaml`: `image_picker_platform_interface` y `plugin_platform_interface`
  pasan a `dev_dependencies` (ya eran transitivos) porque el test los importa.
- Pendiente sin tocar: la **tabla** del markdown sigue con
  `tableColumnWidth: IntrinsicColumnWidth()`, que en 360 px manda la tabla a scroll
  lateral sin envolver. El fix medido es `FlexColumnWidth()` + fondo en el
  encabezado + `tableVerticalAlignment: top`, en `message_bubble.dart` L736-744.
  Tambien sigue sin tocarse el aviso de modo de bajo consumo, que molesta.
- Estado: `flutter analyze lib` sin errores ni warnings, **870 tests verdes (6
  skipped)**, publicado 1.12.0+18 (30.023.625 B, 12 intents / 12 actions).

## 2026-10-02 - Copiar y deshacer mensajes (1.13.0+19)

- Cada mensaje con texto tiene un boton `more-horizontal` que abre una hoja con
  **Copiar mensaje**, y en los del usuario tambien **Deshacer y editar**. El
  menu del assistant NO ofrece deshacer: `revert/stage` exige que el ancla sea
  un prompt (medido: sin `messageID` devuelve 400).
- **Por que un boton y no un long-press sobre la burbuja**: el long-press sobre
  el texto ya lo usa el sistema para seleccionar un fragmento, y los dos no
  pueden ganar la misma arena de gestos (gana el hijo, que se registra primero).
  Como copiar *una parte* era lo que mas se usaba, ese se queda con el
  long-press y el menu completo va en boton explicito.
- **Deshacer devuelve el texto al composer**: `_revertTo(id, restore: text)` saca
  el mensaje del server (stage + commit) y empuja el texto al input por
  `ChatComposer.controller`, un `TextEditingController` externo. Sin eso el
  mensaje se perdia para siempre. **No** pide el foco a proposito: en un telefono
  eso abre el teclado encima del chat justo cuando el usuario quiere mirar lo que
  quedo.
- **Tres cosas rotas que salieron al buscar el boton**: (a) el cuerpo del mensaje
  del usuario era un `Text` pelado, no un `SelectableText` — el unico texto del
  chat que no se podia seleccionar (el `SelectableText` que existia estaba en la
  tarjeta de error); (b) el bloque de codigo era un `RichText`, que tampoco se
  puede seleccionar, asi que el codigo era lo unico incopiable a mano; (c) no
  habia ningun camino a copiar un mensaje entero.
- El bloque de codigo paso a `SelectableText.rich`. **No se pierde nada del
  comportamiento viejo**: `SelectableText` no tiene `softWrap`, pero el
  `SingleChildScrollView` horizontal de adentro le da ancho ilimitado, asi que
  la linea larga sigue en una y scrollea igual (medido: 18 px de alto).
- **Trampa de conteo de colores**: `_spanForNode` **anida** los `TextSpan` (el
  nodo de primer nivel suele ser un envoltorio sin clase de token, con el color
  base). Contarlos con `visitChildren` de un nivel da siempre 1 y el test pasa o
  falla por la razon equivocada. Hay que **recursar**.
- **Trampa de fixture**: el parser se come el salto antes del fence de cierre, asi
  que un `void main() {` queda sin llave y el resaltador de Dart no parsea nada
  (sale plano). Con sentencias sueltas el fragmento es valido.
- **El menu de la sesion ya tinha el patron** (`showModalBottomSheet` + filas de
  48 px); `_MessageSheet` lo copia. `Clipboard.setData` + `showSnackBar` tambien
  tenian antecedente (exportar). Un copiado silencioso que falla se lee como que
  la app no hace nada, asi que el copiado **avisa**.
- 5 tests nuevos en `chat_render_test.dart`, grupo `menu del mensaje: copiar y
  deshacer`. Los cuatro caminos rotos a proposito, y cada uno cae en el test que
  le toca: no devolver el texto -> 1; `Text` en vez de `SelectableText` -> 1;
  `RichText` en vez de `SelectableText.rich` -> 1; usuario sin menu -> 3. Los
  finders apuntan por **id de mensaje** (`ValueKey`), no por posicion: la lista
  del chat va invertida y `.first` es el ultimo mensaje.
- **`test/message_bubble_test.dart` tenia `\r\r\n` en 550 lineas** (CR duplicado
  y triplicado, de una vuelta anterior por PowerShell). Dart lo tolera, pero
  rompe cualquier edicion por coincidencia exacta. Normalizado a `\r\n`; por eso
  el diff de ese archivo es de ~1000 lineas. El unico `\r` extra del repo era ese
  archivo.
- Adjudicacion en `message_bubble_test.dart`: el criterio cambio (ya no se afirma
  `softWrap: false` ni que la linea sea mas ancha que el bloque, porque el bloque
  ya scrollea por el `SingleChildScrollView` y no por `softWrap`). Se verifica lo
  que contiene a las dos cosas: texto completo y bloque sin ensanchar la burbuja.
  Mono 11.5, alto 1.55 y el tope de 190 px siguen igual.
- Estado: `flutter analyze lib` sin errores ni warnings, **876 tests verdes (6
  skipped)**, publicado 1.13.0+19 (30.023.625 B, 12 intents / 12 actions).
- Pendiente sin tocar: la **tabla** del markdown sigue con
  `tableColumnWidth: IntrinsicColumnWidth()` (scroll lateral, sin wrap: el fix es
  `FlexColumnWidth()` en `message_bubble.dart` L736-744), y el **aviso de modo de
  bajo consumo** sigue molestando.

## 2026-10-02 - Boton para volver a descargar si la descarga falla (1.13.2+21)

- La banda de autoupdate se escondia sola en `failed`, sin dejar nada: un APK de
  30 MB en datos moviles se corta seguido y el usuario se quedaba sin update
  hasta cerrar y reabrir la app, que era lo unico que reiniciaba el chequeo.
  Ahora hay **Volver a descargar**, con el motivo del fallo en la misma banda.
- **Los dos `failed` no son lo mismo**, y antes se trataban como uno:
  - fallo del **chequeo** (`info == null`): no hay manifest, no hay URL, no hay
    nada que bajar. La banda **sigue escondida**: un boton ahi no podria hacer
    nada.
  - fallo de la **descarga** (`info != null`): sabemos que bajar. Se muestra.
  La regla nueva es `UpdateState.canRetry` (failed && info != null && error != null).
  `showsBannerFor(UpdatePhase)` queda igual y sigue siendo la regla por fase: asi
  el test viejo sigue siendo cierto y no hubo que adjudicarlo.
- **Bug latente que el boton de reintentar hacia alcanzable**: una descarga cortada
  dejaba el archivo **con el nombre correcto**. Si pasaba de los 2 MB de
  `_minApkBytes`, el proximo arranque (o el reintento) lo daba por bueno con
  `_alreadyDownloaded` y se saltaba la descarga: el instalador recibia un APK
  truncado y fallaba sin explicar nada. Ahora `download()` borra el archivo en
  cuanto la descarga no llega a terminarse (`completo` + `finally`).
- **`MockClient` no sirve para simular un corte**: devuelve la respuesta entera de
  una, nunca falla en el medio del `await for`, que es justo donde se corta en
  produccion. El test usa un `http.BaseClient` propio (`_ManifestoYApk`) que
  responde el manifiesto con el JSON y el APK con un `Stream` que emite 3 MB y
  tira `SocketException`. El canal nativo `ai.openher/install` (metodo
  `updatesDir`) se mockea a una carpeta real de `systemTemp`, asi que el borrado
  se verifica en el disco de verdad.
- El test de reintentar cuenta `intentosApk == 2`: **volver a descargar es volver a
  pegarle al server**, no aceptar lo que quedo. Sin esa cuenta el test pasaba
  aunque el reintento aceptara el parcial.
- `UpdateBanner.retryKey` es nueva, y `_Action` ahora acepta `key`. El boton usa
  el icono `refresh` (no hay `refresh-cw` en `assets/icons`).
- 8 tests nuevos en `test/update_test.dart` (3 de la regla `canRetry`, 2 del widget,
  3 del disco). Los tres caminos rotos a proposito: sin borrar el parcial caen 2;
  con `showsBanner` sin `canRetry` caen 2; sin el boton en la UI cae 1.
- Estado: `flutter analyze lib` sin errores ni warnings, **884 tests verdes (6
  skipped)**, publicado 1.13.2+21 (30.023.625 B, 12 intents / 12 actions).

## 2026-10-03 - El mensaje en cola: se ve gris con editar / eliminar / enviar

- **La razon de que "no se visualizaba" no era la UI: era que no se podia
  llegar.** `UserMessage.pendingSend`, `ChatViewModel.pendings`,
  `takePendingText`, `discardPending` y `confirmSend` existian hace dias, pero
  `message_bubble.dart` **no leia `pendingSend` en ningun lado** y, mas grave,
  el composer no dejaba mandar con el turno en curso: `_submit` hacia
  `onStop` siempre que `working`. O sea que la burbuja en cola era codigo
  muerto: nada la creaba.
- El prototipo tampoco encola (`mobile.html:1718`, `doSend` llama
  `stopWorking()` si `working`), asi que no era falta de port: era una pieza que
  nunca existio. La decision es del shell, no del diseno.
- **El boton del composer ahora es de dos cosas**: con el input **vacio** sigue
  siendo Detener (rojo, icono `stop`, atajo de un toque); con **algo escrito**
  es Enviar (`primary`, icono `send`, etiqueta "Enviar en cola") y encola. El
  prototipo y el boton unico no能手 pueden hacer las dos cosas a la vez.
- La burbuja en cola se ve **gris**: `surfaceContainerHighest` + borde
  `outline`, en vez del azul `primary`. El azul dice "el server ya lo tiene", y
  un azul para algo que nadie mando hace que el usuario lo relea creyendolo
  entregado. Los tres botones son **solo icono** (`edit`, `trash`,
  `arrow-upward`), 28 px de alto, y el de enviar va en `primary` porque es la
  accion que el usuario quiere el 80% de las veces. Sin el `⋮` del menu: sus
  tres acciones **son** el menu de ese mensaje.
- Editar reutiliza el canal del "deshacer": el texto vuelve al input por
  `_prefillComposer`, y la burbuja desaparece (lo decide `takePendingText`).
- **`_streamState == StreamState.streaming` NO se metio como condicion.** El
  pedido era "cuando hay un mensaje mio activo **y se establecio conexion con
  el server**", pero agregar ese flag **hace la app menos segura**: durante
  `reconnecting` o `polling` el turno sigue vivo (`working` true) y el mensaje
  se POSTaria, que es exactamente el `delivery: steer` que el codigo ya
  documenta. Se dejo `working` como unico disparador y quedo dicho.
- 9 tests en `test/chat_render_test.dart`, grupo `un mensaje en cola`. Los tres
  caminos rotos a proposito: el composer siempre-Detener cae **8 de 9** (la
  exception es justamente "input vacio sigue siendo Detener"); el pendiente azul
  cae 1; los botones ausentes caen 5.
- Un test caido de paso: `_Action` de `update_banner` y el cuerpo del mensaje
  usan `SelectableText`, y `find.text` no los matchea todos. Se agrego el helper
  `seleccionable(String)` y `cajaDe(tester, texto)` (el `BoxDecoration` de la
  caja que contiene un texto), porque lo que hay que afirmar es el **color**,
  no que widget pinto.
- **Pendiente sin tocar**: la tabla del markdown sigue con
  `tableColumnWidth: IntrinsicColumnWidth()` (scroll lateral, sin wrap) y el
  aviso de modo de bajo consumo sigue molestando.

## 2026-10-05 - Preguntas del agente, caja del turno, y loader + orden en sesiones

### La tarjeta de la pregunta no se veia nunca (medido, no supuesto)

- `MessageBubble.pendingQuestionTool` exigia `tool.state is ToolPending`. **Medido
  contra el server real** (50 sesiones, 4 tools `question`): el estado **nunca** es
  `pending`. Es `running` (la pregunta espera de verdad, `error: null`), o
  `completed` (ya respondida), o `error` con `{"type":"aborted","message":"The
  user dismissed this question"}`.
- Ahora acepta `ToolPending` **o** `ToolRunning`, y **excluye** `error`: repintar
  una pregunta que el usuario acaba de descartar seria ofrecer algo que cerro.
- El `state.input` real llega **parseado** (dict), no como string crudo. Las
  opciones son objetos `{label, description}`, que `_question` ya leia bien.
- El fixture del test que existia usaba `pending`: pasaba en verde con la
  funcion muerta. **Adjudicado en el sitio** con el motivo escrito, y los tres
  estados medidos quedaron cubiertos.

### La caja del turno: 148 -> 900 px, con scroll interno

- El tope de 148 cortaba la lista de herramientas a menos de cinco filas, asi que
  un turno normal de agente (8+ tools) se leia a medias y habia que scrollear
  **dentro** de la caja: un scroll anidado dentro del scroll del chat. Subido a
  900 px **por pedido** (2026-10-03), manteniendo el scroll interno: 900 px
  logicos es mas que la pantalla de un telefono (~873), y sin scroll interno la
  ultima herramienta se iria de vista con el scroll del chat.
- `live_bugs_test.dart` afirmaba `lessThan(260)`, atado al tope viejo.
  **Adjudicado**: lo que ese test protege es que siga siendo un **tope**, no un
  minimo, y eso se sigue verificando contra un techo. El alto real con 14 tools lo
  mide ahora `chat_render_test.dart`.

### Sesiones: luz en el titulo de la que corre, y orden por reciente

- `groupSessions` ordenaba cada grupo como venía del server (el orden de los
  cursores), asi que la sesion que acababas de usar podia quedar debajo de otras
  del mismo dia. Ahora cada bucket se ordena por `updatedMs` **descendente**. El
  orden de los **grupos** no cambio: `SessionBucket.values` ya va de HOY hacia
  atras.
- La sesion corriendo lleva una **luz que recorre el titulo** de 0 a 100 de
  izquierda a derecha: un `ShaderMask` con un degradado lineal cuya franja
  brillante se desplaza, en 0.28 del ancho (el numero del `.shimmer-text` del
  cliente web). Va en el titulo y no en la fila entera porque el titulo es lo que
  se mira al volver de otra pantalla.
- **Un solo `AnimationController` para toda la lista**, en el shell: uno por fila
  arrancaria cuando cada una se monta y quedarian desfasados, y dos sesiones
  corriendo se leerian como dos cargas distintas. Son los mismos **1400 ms** que
  usan `_SquaresSpinner` y `_PulseDot`, para que las tres señales de "esta
  trabajando" laten a la vez.
- **Trampa de `late final` + `dispose()`**: con un `late final` normal, el
  `dispose()` **crea** el controller si nunca se uso, y crearlo con el elemento ya
  desmontado revienta un assert de `TickerProvider` en cada salida de la pantalla
  (tumbaba 4 tests de `sessions_test.dart` y `widget_test.dart`). Por eso es
  `AnimationController? _sweep` con un getter perezoso: ademas, una lista sin
  sesiones vivas no tiene ningun ticker corriendo en segundo plano.

### Guardas

8 tests nuevos. Los cuatro caminos rotos a proposito:

| roto                                            | que cae |
|-------------------------------------------------|---------|
| la card vuelve a exigir `ToolPending`          | 1       |
| el tope de la caja vuelve a 148                | 1 (148 vs >300) |
| el titulo nunca lleva la luz                   | 1       |
| sin sort por fecha en los grupos               | 1       |

- Estado: `flutter analyze lib` sin errores ni warnings, **899 tests verdes (6
  skipped)**.
- Pendiente sin tocar: el **aviso de modo de bajo consumo** sigue molestando.

## 2026-10-06 - Imagenes del agente en el chat: miniaturas que se expanden

- **Medido antes de escribir nada** (60 sesiones del server real): el agente
  **no manda markdown**. 0 imagenes `![]()` y 6 rutas **desnudas** en el texto
  (`bautismoOlivia2021.jpeg`, `rociiorz-20220305-0001.webp`). Por eso un builder
  de `img` de markdown no habria encontrado ninguna: no hay elemento `img` que
  construir. La deteccion se hace **sobre el texto**.
- `imagePathsIn(String)` es pura y testeable: extension en lista cerrada
  (`png jpg jpeg webp gif bmp heic`), corta en los delimitadores de la prosa
  (backticks, comillas, parentesis, corchetes, comas), descarta URIs con
  esquema (no las sirve el server de la sesion y una miniatura rota es peor que
  ninguna) y exige **al menos un caracter** antes del punto.
- `MessageImages`: tira de miniaturas de **72 px de alto** (`BoxFit.cover`), al
  final del texto y no incrustada entre parrafos — el agente nombra las rutas
  dentro de una frase, y una miniatura en medio del renglon rompe el parrafo.
  Solo se pinta con el turno **ya terminado**: con el texto llegando por deltas
  las rutas estan a medias y saldrian miniaturas de nombres truncados.
- Al tocar una miniatura se expande a pantalla completa con `altura = 75% del
  alto de la pantalla` y `BoxFit.contain`. **Porcentaje y no un fijo**: un alto
  en pixeles se veria gigante en un telefono y diminuto en una tablet. El test lo
  verifica midiendo la MISMA imagen en dos alturas de pantalla.
- La carga va con `config.fileUrl(path)` + `config.binaryHeaders`: el server
  sirve los bytes en `GET /api/fs/read/<path>` y **exige el Basic** (sin el,
  401). El canal lo pasa el shell (`_vm.api.config`), que es el unico que tiene
  la config; la burbuja suelta lo recibe en `null` y no pinta nada.
- `errorBuilder` con el **nombre** del archivo: un cuadrado con un icono roto no
  dice cual fallo. Y `frameBuilder` reservando la caja antes de que llegue la
  imagen, para que la tira no empuje el chat hacia abajo al cargar.
- **La spec de capas crecio**: `chat.msg.image` (94 -> 95 capas, 90 -> 91
  activas). Hay que tocar los **cuatro** lugares o cae uno de los gates:
  `spec/layers.json`, `assets/spec/layers.json` (los dos con el `_meta`),
  `layer_contract_test.dart` (los conteos a mano) y `layer_gate_test.dart` (el
  titulo y los `"total"/"active"` del asset). Las 4 capas apagadas siguen siendo
  las 4 aprobadas.
- **Trampa de la guarda no verificada**: el primer break que hice (sacar la
  guarda del nombre) **no tumbo ningun test**, porque la propia regex ya rechaza
  un `.webp` precedido de espacio. La guarda solo es load-bearing cuando hay un
  separador pegado a la extension (`G:\fotos\.png`), y eso no estaba cubierto.
  Se agrego el caso; ahi si muerde.
- 13 tests nuevos en `test/message_images_test.dart` (8 del detector, 5 del
  widget). Estado: `flutter analyze lib` sin errores ni warnings, **912 tests
  verdes (6 skipped)**.
- Pendiente sin tocar: el **aviso de modo de bajo consumo** sigue molestando.
- Publicado **1.15.0+23** (30.023.593 B, 12 intents / 12 actions, zip de 416
  entradas, minSdk 24 / targetSdk 36). Verificado sobre el APK **publicado**
  bajado con cache-buster, no sobre el local.

## 2026-10-06 - Publicado 1.15.0+23

- Version **1.15.0+23** publicada en `Owning01/openher-mobile` y en
  `Owning01/mis-apps`. Verificada sobre el APK **descargado** (con cache-buster,
  no el local): 30.023.593 B, `versionCode=23`, `versionName=1.15.0`, minSdk 24,
  targetSdk 36, zip de 416 entradas, **12 `<intent>` / 12 `<action>` (1:1)**.
- Verificado antes de publicar: `flutter analyze lib` sin errores ni warnings,
  **912 tests verdes (6 skipped)**, y `dart format` sin cambios en los 12
  archivos tocados.
- Ojo con `dart format --output=none --set-exit-if-changed lib test` sobre el
  repo entero: marca **20 archivos cambiados que no son de este trabajo**. Es
  drift de formato preexistente; reformatearlos metería un diff ajeno en el
  commit. Se verifica archivo por archivo.
- Entra en esta release: mensaje en cola (gris + 3 botones de solo icono),
  tarjeta de la pregunta del agente (el server la manda en `running`, no
  `pending`), caja del turno 148 -> 900 px, luz en el titulo de la sesion que
  corre + orden por mas reciente, miniaturas de imagenes del agente
  expandibles, boton de volver a descargar, copiar mensaje y deshacer que
  devuelve el texto al composer.
- **Sin verificar en pantalla**: el Xiaomi sigue sin aparecer en `adb`, asi que
  nada de esto se vio correr en un telefono real. Lo verificado es contra el
  server real y contra el APK publicado.
- Pendiente sin tocar: el **aviso de modo de bajo consumo**.

## 2026-10-06 - Eliminar sesiones: el endpoint existia y el cableado no

### La causa: dos capas, y la de arriba era la que fallaba

- **`app.dart:482` construia `SessionsView(viewmodel: _vm, onOpen: ...)` sin
  `onAction`.** La vista reportaba el swipe y las acciones del menu a un callback
  `null` y volvia: **seis acciones y el swipe no hacian nada**. Eso es lo que se
  veia como "no se pueden eliminar sesiones".
- El doc de `sessions_view.dart` afirmaba que el dialecto v2 **no expone**
  archivar/borrar/renombrar. Ese supuesto nunca se re-midio y era **falso**.

### Medido contra el server real

- `DELETE /api/session/{id}` -> **204 con cuerpo vacio**. Despues `GET` de esa
  sesion da 404 y desaparece de `GET /api/session`. **No necesita `directory`.**
- `PATCH /api/session/{id}` con `{title}` -> la ruta existe (renombrar se puede).
- El discriminador que hace valida la inferencia: con un id falso,
  `DELETE` y `PATCH` contestan **`SessionNotFoundError`** (error de dominio: la
  ruta existe y la sesion no), mientras que `POST .../archive` y
  `POST .../delete` contestan **404 con cuerpo vacio** (ruta inexistente). Sin
  ese control, un 404 se lee como "no existe" y no se distingue.
- La prueba se hizo con **sesiones descartables creadas para eso** (dos) y se
  borraron: no se toco ningun dato real. Confirmado que no quedaron en la lista.
- El contrato fino del cliente web de este repo (`web/src/api/sessions.ts:188`)
  documenta dos cosas mas: que un 200 **sin JSON** hay que tolerarlo como exito,
  y que conviene reintentar **sin `directory`** si el call falla.

### Lo implementado

- `ApiClient.deleteSession` (DELETE + reintento sin `directory`) ->
  `SessionRepository.delete` -> `SessionsViewModel.delete(session)`, que llama
  al server **primero** y recien despues saca la fila de la lista. Al reves, un
  DELETE que falla deja la fila borrada en pantalla y el poll la repinta: el
  borrado fantasma.
- Menu: se agrego `SessionAction.delete` ("Eliminar", rojo, icono `trash`) y
  **el swipe paso de `archive` a `delete`**. `archive` no existe en el server,
  asi que el gesto no podia hacer nada.
- Confirmacion con el **titulo** de la sesion antes de borrar: destructivo e
  irreversible, y con varias sesiones parecidas "seguro?" no alcanza para saber
  cual. El snap-back del swipe sigue: la fila vuelve y la confirmacion sale
  despues.
- Las otras cinco acciones avisan honestamente que el server no las expone, en
  vez de cerrar la hoja sin hacer nada.

### Dos cosas que salieron mal y se corrigieron

- **El menu desbordaba 47 px** con la sexta fila. `showModalBottomSheet` sin
  `isScrollControlled` limita a media pantalla. Ahora scrollea.
- **`dart format lib` reformateo 53 archivos y toco 5 que no eran de este
  trabajo** (drift preexistente: `message.dart`, `chat_viewmodel.dart`,
  `code_highlight.dart`, `composer_suggestions.dart`, `file_preview.dart`).
  Revertidos con `git checkout --`. Es el mismo error que el `json.dumps` de la
  spec: una herramienta reescribiendo archivos que tienen formato propio.
  Formatear **archivo por archivo**, nunca el directorio.

### La guarda que importa no es un test, es el compilador

- El break que sacaba `onAction` de `app.dart` **no tumbo ningun test**: no hay
  ninguno que verifique el cableado del shell, porque los tests del widget se
  pasan `onAction` ellos mismos. Eso es exactamente lo que dejo vivir el bug.
- Se resolvio haciendo `SessionsView.onAction` **`required`**: olvidarlo ahora es
  `missing_required_argument`, un error de compilacion. Verificado rompiendolo:
  el analyzer lo frena. Es la unica clase de guarda que no se puede saltear.
- El `required` destapo **6 llamadas mas** en `sessions_test.dart` que no lo
  pasaban (el compilador haciendo su trabajo, en el mismo commit).
- 6 tests nuevos en `test/sessions_test.dart`, grupo "eliminar una sesion". El
  break de "borra la fila sin llamar al server" cae en 2.
- Estado: `flutter analyze lib` sin errores ni warnings, **915 tests verdes (6
  skipped)**.
- **Sin commitear ni publicar**: pendiente de aprobacion.

## 2026-10-06 - La luz del titulo mas lenta (2800 ms), y por que solo esa

- Pedido: "la animacion de 0 a 100 que sea mas lenta". Estaba en 1400 ms, igual
  que `SquaresSpinner` y `_PulseDot` (que era el pedido anterior: "sincronizado
  con el de los demas"). Ahora son **2800 ms**, el doble.
- **Solo se bajo la luz, no los tres.** Es una decision, no un olvido:
  - La sincronizacion que importaba es la del **lenguaje visual** (una luz que
    trabaja, no tres animaciones distintas) y esa se mantiene.
  - Igualar de nuevo los tres costaria caro por el otro lado: **un spinner de
    2800 ms se lee como una app colgada**, y el spinner esta justamente para
    decir lo contrario.
  - El spinner de cuadrados quedo blindado con `kSquaresSpinnerPeriod` (1400) y
    un test que lo afirma, para que nadie "arregle" la sincronizacion
    alargandolo.
- `SessionsView.titleSweepPeriod` es publica y con nombre: es el numero que
  define cuanto dura una pasada, asi que un cambio de velocidad tiene que ser
  deliberado y visible en el diff.
- Un `AnimationController` sigue siendo **uno solo** para toda la lista (la fase
  compartida entre filas no cambio).
- Test nuevo en `sessions_test.dart`, grupo "la velocidad de la luz del titulo":
  mayor a 1400, menor a 6 s, y el spinner clavado en 1400. El break que devuelve
  la luz a 1400 **cae**.
- Estado: `flutter analyze lib` sin errores ni warnings, **916 tests verdes (6
  skipped)**.
- Sigue **sin commitear ni publicar**: pendiente de aprobacion. Entra en la
  misma release que el borrado de sesiones.

## 2026-10-06 - Adjuntar fotos daba 400, y las miniaturas no cargaban: la causa era la misma

### El 400 al mandar una foto (captura del telefono, 9:07)

- **Medido**: `POST /api/session/{id}/prompt` con `files:[{uri:"G:/.../x.jpeg"}]`
  devuelve `400 InvalidRequestError: Unsupported attachment URI`. Tambien con
  `file://` (`Invalid file URI`), con `content://` y con `http://`.
- **El server no puede leer el disco del telefono**: el contenido tiene que
  viajar en el cuerpo. Con `data:image/jpeg;base64,<bytes>` de una imagen real
  devuelve **200** (probado con un JPEG de 245 KB).
- `files[]` va en la **raiz** del body, no anidado en `prompt` (anidado da
  `Missing key at ["text"]`), y `mime` de mas no molesta.
- Arreglo: `ComposerAttachment.toPromptFile()` paso a **async** y arma el data
  URI leyendo el archivo. `chat_view._enviar` lo espera y, si un adjunto no se
  puede leer, **no manda a medias**: avisa y corta, porque un adjunto que falta
  cambia lo que el modelo ve y el usuario no lo sabria.

### Las miniaturas no cargaban (capturas 2 y 3)

- Se veian las **cajas** con el nombre y el icono, que es mi `errorBuilder`: la
  imagen nunca llegaba.
- **Medido**: `GET /api/fs/read/bautismoOlivia2021.jpeg` -> **404
  FileNotFoundError**; el mismo basename con
  `?location[directory]=<su carpeta>` -> **200 image/jpeg 245128 bytes**. La
  ruta absoluta entera -> **500**.
- Arreglo: el shell arma la URL con `fileUrl(nombre, directory: carpeta)`. Si el
  token trae carpeta, manda la suya; si es un nombre suelto (lo que manda el
  agente), se resuelve contra **la carpeta de la sesion** (`_vm.directory`).
- **Tailscale no era el problema**: el chat carga por el mismo server. Lo que
  fallaba era la resolucion de la ruta.

### Lo que NO se pudo verificar con un test de widget

- `toPromptFile` hace **I/O real** (leer el archivo), y en `flutter_test` el I/O
  real **no completa dentro del zone de async falso**: `readAsBytes` nunca
  vuelve y el POST no sale. El test que observaba el POST fallaba por no haber
  mandado nada, que es lo contrario de lo que probaba.
- **Adjudicado** en `chat_render_test.dart`: ese test ahora verifica lo que el
  bug original rompia y se ve sin red (la tira muestra 3 y ninguna de mas). La
  forma del `files[]` queda pendiente de un `test` comun, donde el I/O si corre.
- **Pendiente declarado**: falta ese test del data URI. No se invento uno que
  pase por la razon equivocada.
- Estado: `flutter analyze lib` sin errores ni warnings, **916 tests verdes (6
  skipped)**.
- **Sin commitear ni publicar.**

## 2026-10-06 - Publicado 1.16.0+24

- Version **1.16.0+24** en `Owning01/openher-mobile` y `Owning01/mis-apps`.
  Verificada sobre el APK **descargado** (cache-buster): 30.023.621 B,
  `versionCode=24`, `versionName=1.16.0`, minSdk 24, targetSdk 36, zip de 416
  entradas, **12 `<intent>` / 12 `<action>` (1:1)**.
- Verificado antes de publicar: `flutter analyze lib` limpio, **916 tests verdes
  (6 skipped)**.
- Entra: adjuntar fotos sin 400 (data URI), miniaturas que cargan (ruta resuelta
  contra la carpeta de la sesion), eliminar sesiones con confirmacion y
  `onAction` requerido, y la luz del titulo a 2800 ms.
- **Sin verificar en pantalla**: el Xiaomi sigue sin aparecer en `adb`. Lo que
  falta probar con el telefono en mano es **adjuntar una foto y verla en el
  chat**: es lo unico de esta release que no se pudo ejercitar aca, porque
  `flutter_test` no puede esperar I/O real.
- Pendiente declarado: falta el test del data URI en un `test` comun (donde el
  I/O real si corre). No se invento uno que pase por la razon equivocada.
- Pendiente sin tocar: el **aviso de modo de bajo consumo**.
- **Trampa repetida**: la vez pasada otro agente se llevo mis 17 archivos con un
  `git commit` sin pathspec mientras estaban staged. Esta vez se commiteo
  inmediatamente despues del `git add`.

## 2026-10-07 — Abrir archivos de un disco: imposible porque el server no resuelve la ruta absoluta

- El navegador lista discos, carpetas y archivos, pero tocar un archivo no
  abría nada. TOCABASE en el log del server: `GET /api/fs/read/G:\...\foto.jpg`
  contesta **500**.
- **Medido**: `/api/fs/read/<nombre>?location[directory]=<carpeta-absoluta>`
  contesta **200** con el archivo; la ruta absoluta entera contesta 500.
- Causa: `FilePreview` armaba la URL con la ruta absoluta entera y **sin**
  `directory`. Ahora recibe el path y el `directory` por separado: en un disco
  le pasa el nombre del archivo y la carpeta actual; en la raíz del `location`
  sigue pasando el path del nodo como siempre.
- 912 tests verdes, `flutter analyze lib` limpio. Publicado 1.17.1+26.

## 2026-10-07 — Botón Descargar en Archivos (sin commitear ni publicar)

- La hoja de acciones suma **Descargar** (`FileAction.download`, icono `download`):
  baja los bytes por `GET /api/fs/read` y abre el compartir del sistema, donde
  el usuario guarda (Descargas, Drive, WhatsApp). La app no elige destino: en
  Android no hay carpeta propia sin permisos extra.
- Camino nuevo: `ApiClient.readFileBytes` (bytes crudos, sin `jsonDecode`;
  misma clasificación de errores y un reintento, como `getJson`) →
  `FileRepository.downloadBytes` → temp `OpenHer-<nombre>` → `SharePlus`.
- Fallos tipados antes que código: 404 → `ApiError`, 401 → `AuthError`, HTML del
  catch-all → `HtmlFallbackError` (no compartir el index como archivo), sin red
  → `NetworkError`. El nombre al temporal es solo el basename: un `../` no sale.
- Misma resolución de ruta que Abrir: en disco, nombre + `location[directory]`
  (la absoluta da 500, medido 2026-10-06).
- Nueva dep `share_plus: ^12.0.2` (API `SharePlus.instance.share`; el `Share`
  estático está deprecado en v12). `XFile` sale del mismo import.
- Tests: 4 nuevos en `files_test.dart` (bytes exactos + URL con location, 404,
  HTML, 401). La guarda de la hoja (`ninguna accion queda sin destino`, itera
  `FileAction.values`) cubre la fila nueva: roto a propósito (`onPressed: null`)
  y cae; restaurado.
- `flutter analyze` limpio en los 4 archivos; `files_test.dart` 36/36,
  `api_client`+`drives`+`api_measure` 69/69. La suite completa tiene 7 fallos
  **ajenos**: `chat_view.dart`/`message_bubble.dart` no compilan (trabajo sin
  terminar de otro agente en el árbol compartido); no se tocan (un path, un
  escritor). PENDIENTE: commit con pathspec + bump + publicar, cuando se apruebe.

## 2026-10-07 — Pregunta fija abajo + botón Descargar (publicar 1.18.0+27)

- La card de pregunta va fija **abajo** (`_pendingQuestionBar` sobre el
  composer), alimentada por `pendingQuestion` (evento `question.asked`). El
  inline en `MessageBubble` se eliminó: pintaba dos veces lo mismo.
- El árbol traía trabajo a medias de otro agente (`chat_view`, `message_bubble`
  no compilaban: faltaba el import de `errors.dart`, colgaba un `pending` y
  sobraba `_question` muerto). Con autorización del dueño se completó lo mínimo:
  import + `pendingQuestionTool(assistant) == null` + borrar `_question`.
- 6 tests de `chat_render_test.dart` adjudicados **en el lugar**: la card ya no
  sale del tool sino del evento. Los de render ahora emiten `question.asked`;
  los dos de parsing de `input` en string quedaron como unit tests puros de
  `questionItems` (ese camino ya no alimenta UI). Helpers de question movidos
  arriba del primer uso (Dart exige declaración previa).
- Botón **Descargar** en la hoja de Archivos (`FileAction.download`):
  `ApiClient.readFileBytes` (crudo, sin `jsonDecode`, misma clasificación de
  errores) → temp `OpenHer-<nombre>` → `SharePlus.instance.share`. Nueva dep
  `share_plus: ^12.0.2`. 4 tests nuevos en `files_test.dart`; la guarda de la
  hoja cubre la fila (verificado rompiéndola).
- Suite: **928 verdes (6 skipped)**, `flutter analyze lib` sin errores ni
  warnings.

## 2026-10-08 — Freno fuera del location + probe honesto (publicar 1.18.1+28)

- Descargar un archivo fuera del `location` fallaba con `HtmlFallbackError`
  (medido: `fs/read` + `location[directory]=G:/Proyectos/seek-asm` da 200 con
  el HTML del SPA; absoluto en URL da 500; `?path=` da 404/500). El server solo
  sirve bytes dentro de su carpeta: sin cambio de server no hay descarga de
  otros discos.
- Abrir y Descargar frenan antes de la red con aviso
  ("solo funciona dentro de la carpeta del servidor"): `dentroDe` puro en
  `fs_path.dart` + `FileRepository.locationDirectory` cacheado. Sin `location`
  legible se intenta igual (fail-open).
- El probe ya no disfraza `NetworkError` de "no es v2" (tapaba un Tailscale
  caído). El campo host rechaza `IP:puerto` pegado. 2 tests adjudicados en el
  lugar + 4 nuevos; guards rotos y verificados.
- Suite completa verde, analyze sin errores ni warnings.

## 2026-10-08 — Descarga de .html en cualquier disco (publicar 1.18.2+29)

- El freno de 1.18.1 nació de una medición errónea: lo que devolvía HTML era
  el archivo `mockup-bar.html` genuino, no el SPA. `fs/read` sirve cualquier
  disco (medido: `C:/Windows/win.ini`, `G:/.../README.md` y `.exe` dan bytes;
  `location[directory]` absoluto dentro y fuera del root da 200).
- Bug real en `_sendBytes`: `text/html` en el header ⇒ `HtmlFallbackError`.
  Ahora decide el cuerpo (`esShellDelSpa`, marca `v2-background-bg-deep` del
  shell medido en `/` y `/algo`). Un 404 de archivo inexistente ya venía como
  JSON (`FileNotFoundError`), nunca como HTML.
- Revertido el freno entero (`dentroDe`, `locationDirectory`, avisos en Abrir
  y Descargar) y sus 4 tests: bloqueaba descargas que sí funcionan. Test del
  catch-all adjudicado con el shell real; nuevo test de `.html` genuino.
- Suite completa verde, analyze sin errores ni warnings.

## 2026-10-08 — Iconos de Archivos: carpeta ámbar + file en todo (publicar 1.18.3+30)

- La fila usaba `folder`/`file` pero la carpeta iba en gris de chrome.
  Ahora la carpeta va en ámbar (`AppColors.warnOf`, adaptado a claro/oscuro)
  y cada archivo lleva su icono `file` (ya lo tenía: único builder `_row`).
- Test widget: ámbar exacto en claro + presencia del icono en archivo. Guard
  roto y verificado. Suite verde, analyze limpio.

## 2026-10-09 — Preguntas por form.created (card no salía nunca)

- Causa: el server ya no emite `question.asked` (0/688 frames en vivo). La
  pregunta viaja como `form.created` (`data.form` con sesión anidada,
  `metadata.kind == "question"`, fields con `{key,title,description,options:
  [{value,label}]}`) y se responde `POST .../form/{id}/reply {answer:
  {key:value}}` → 204. Medido punta a punta con sesión descartable (el agente
  siguió el turno); la sesión se borró después.
- Fix: `_applyFormCreated` + filtro por sesión anidada + cadena de reply
  (forms → question endpoint → prompt) + `QuestionOption.value` (viaja el
  value, no el label). `form.replied` cierra. Camino viejo conservado.
- Tests: 6 nuevos en viewmodel + 1 de render (card desde form + POST exacto).
  Guard conductual: sin el fix, cero `QuestionCard` (el síntoma del usuario).
- Suite: **940 verdes (6 skipped)**, analyze sin errores ni warnings. Sin
  commitear ni publicar: pendiente OK del dueño (versión 1.19.0+31 propuesta).

## 2026-10-10 — Visor de planes html-plan en la app (publicar 1.20.0+32)

- Skill `html-plan` sin referencias a Claude (js, pack.mjs `--published`,
  SKILL, blocks) + idioma del pedido + formato Dart documentado. `pack`
  verificado con `--lint-only` sobre el ejemplo.
- Port 100%: `ui/features/plan/` (modelo+parser del mismo `plan.html`,
  respuestas con formato Respond, mocks, máquina, calls, schema/code, flow,
  tree, draft, notas, decisions con todos los controles, comentarios, copiar).
- Entrada: `Ver plan` en la burbuja cuando el texto trae una ruta `.html`
  (absoluta o relativa); baja bytes y cae a `FilePreview` si no es plan.
- Suite 955 verdes, analyze limpio.

## 2026-10-10 — Recientes con recencia efectiva + links con confirmación

- Recientes: el server mueve `updated` al final del turno. `pollActive` toca
  lo que arranca a correr y el orden usa recencia efectiva (en curso primero,
  después lo tocado); grupo y hora siguen del server. 3 tests, guards rotos.
- Links http/https del chat preguntan (`Abrir enlace` + URL) antes de salir;
  `file://` y rutas nunca salen. Usuario con URL suelta lleva botón.
  Tests puros + widget (tap real del link). Suite 963, analyze en cero.

## 2026-10-10 — Plan con colores del archivo + hoja Respond arreglada

- El visor usa tema papel espejo de `htmlplan.css` (claro `#FAF9F5`, oscuro
  `#262624`, acento y 5 colores de datos por brillo): lo mismo que el navegador.
- Hoja Respond reescrita (SafeArea + scroll simple): salía vacía y con los
  botones bajo la barra del sistema. Regresión con el plan real empaquetado en
  tema oscuro. Skill: planes en español por defecto.

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

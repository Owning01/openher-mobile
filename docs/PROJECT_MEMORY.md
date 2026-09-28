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

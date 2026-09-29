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
| `lib/data/connectivity/` | `network_monitor.dart` + `DataPolicy`: modo bajo consumo **sólo** con datos móviles |
| `lib/data/repositories/` | `session_repository`, `file_repository`, `catalog_repository` |
| `lib/domain/models/` | `session`, `message`, `tool`, `event`, `errors`, `agent_catalog`, `model_catalog`, `turn_activity` |
| `lib/ui/core/` | `tokens.dart`, `theme.dart`, `theme_variants.dart` (61 paletas), `layer_gate.dart`, `app_icon.dart`, `low_data_banner.dart`, `update_banner.dart` |
| `lib/ui/features/chat/` | `chat_view`, `chat_viewmodel`, `composer`, `message_bubble`, `turn_activity`, `tool_card`, `model_sheet`, `agent_sheet` |
| `lib/ui/features/` | `sessions/`, `files/`, `settings/`, `connect/`, `navigation/` |
| `docs/API_CONTRACT.md` | Contrato **medido** contra el server real |
| `docs/SUPER_PLAN.md` | Decisiones, arquitectura, fases M0–M10 |
| `prototype/mobile.html` | Maqueta navegable con toggles de capas |
| `scripts/publish-update.ps1` | Compila, sube APK + manifiesto, **verifica con `curl`** y **exige PowerShell 7+** |

**Tamaños medidos:** 43 archivos Dart en `lib/` (17.778 líneas), 28 archivos de test (14.860
líneas), 39 iconos SVG, **686 tests**, `flutter analyze lib` en cero errores y cero warnings.

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
| D7 | Deps directos: `http`, `flutter_secure_storage`, `speech_to_text`, `flutter_svg`, `shared_preferences`, `flutter_markdown_plus`, `connectivity_plus`, `image_picker`, `video_player`, `pdfrx`, `html`, `url_launcher` |
| D8 | Los 3 canales de error visibles (el escritorio se come `session.error`) |
| D9 | Modo de bajo consumo **automático** sólo con red celular; el usuario puede desactivarlo a mano |
| D10 | Autoupdate contra el manifiesto de la release, sin diálogos ni bloqueos |
| D11 | El visor de archivos decide **por extensión**, no por el botón que se apretó: `domain/models/file_type.dart` + `ui/features/files/file_preview.dart` |

## Contrato: lo que hay que no olvidar

- **Auth:** Basic `opencode:<OPENCODE_SERVER_PASSWORD>`; el user se compara **siempre**; default `"opencode"`.
- **Probe de versión:** `GET /api/location` (NO `/api/health`: da 404 en este build).
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
  `order` **no** se manda (`InvalidCursorError`). Las páginas llegan de más nuevo a más viejo.
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
# build + publicar (el script exige PowerShell 7+, o se niega a correr)
pwsh -File .\scripts\publish-update.ps1 -Notes "..."
```

Build de Android: `ANDROID_HOME=G:\Android\SDK`, `JAVA_HOME=G:\Android\Android Studio\jbr`,
`kotlin.incremental=false` en `android/gradle.properties` (la caché incremental falla en este disco).

## Trampas conocidas

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
- Windows PowerShell 5.1 **no se puede desinstalar**: es componente del SO y su binario está en
  control de `TrustedInstaller`. La defensa es negarse a correr bajo 5.1, no borrarlo.
- Un **test** que afirma algo que la medición desmentió se adjudica **en el lugar**, con el motivo
  escrito en el archivo. Editar un test para que pase está prohibido; corregir su premisa no.
- `dart format lib test` reescribe archivos de otros si hay trabajo sin commitear: commitear
  antes de formatear.

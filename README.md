# OpenHer Mobile

Cliente **Android** delgado, en Flutter, que habla **directo con el server de
opencode** (dialecto v2, prefijo `/api`). No depende de OpenHer ni de
`openher-desktop.exe`: no usa `:4848` (shell) ni `:4849` (PTY).

<p align="center">
  <img src="prototype/mobile.html" alt="" width="1" height="1" style="display:none">
</p>

## Qué hay adentro

| Carpeta | Qué es |
|---|---|
| `docs/API_CONTRACT.md` | El contrato de la API **medido** contra el server real: auth, envoltorias, mensajes, tools, errores, SSE y una lista de *drift* (lo que no existe y no hay que llamar). |
| `docs/SUPER_PLAN.md` | El plan maestro: decisiones, arquitectura, contrato de performance, fases M0–M10, riesgos. |
| `docs/PROJECT_MAP.md` | Estado actual del proyecto (el índice). |
| `docs/PROJECT_MEMORY.md` | Bitácora: qué pasó y por qué. |
| `spec/layers.json` | La **config de diseño aprobada**: 94 capas de UI, 90 activas. |
| `prototype/mobile.html` | Maqueta navegable (un solo archivo, sin recursos externos) con los toggles de capas. |
| `assets/spec/layers.json` | La misma spec, empaquetada para que la app la lea en runtime. |
| `assets/icons/` | 39 iconos SVG (Lucide 1.5px) extraídos del prototipo. Cero emojis. |

## Las 4 pantallas

`Sesiones` · `Chat` · `Archivos` · `Ajustes`, con bottom-nav de 4 destinos.

## Capas: el diseño es un contrato verificable

`spec/layers.json` sale del prototipo. Las 4 capas apagadas **no se construyen**:

- `chat.appbar.subtitle` — sin subtítulo de modelo en el app bar
- `chat.composer.counter` — sin contador de caracteres
- `chat.composer.tsl` — sin chip TSL (traducir ES→EN)
- `chat.header.progress` — sin barra de progreso del turno

`test/layer_contract_test.dart` falla si una capa activa no tiene archivo o si
se implementa una apagada. Además, dentro de la app, `LayerGate` apaga y enciende
cualquier capa en runtime desde **Ajustes → Capas de la UI**, y el cambio se
persiste.

## Conectar

`service.json` **no existe en opencode2** (es una convención de OpenHer) y en
Android no hay disco del PC, así que la app pide las credenciales en la primera
pantalla y las guarda cifradas (`flutter_secure_storage`):

- Host `127.0.0.1` · Puerto `4098` · Usuario `opencode` · Contraseña: la del
  `opencode serve`.

El probe de versión es `GET /api/location`. **No** `/api/health` (da 404 en el
build medido) ni `/global/health` (devuelve el catch-all del SPA).

## Comandos

```powershell
flutter pub get
flutter test
flutter analyze
flutter run -d <android>
.\tools\build-apk.ps1          # APK release
```

## Decisiones que no se re-discuten

| # | Decisión |
|---|---|
| D1 | Sólo dialecto v2. Si el probe no da v2, aviso explícito (no modo dual). |
| D2 | Credenciales por UI → secure storage. Nunca se lee `service.json`. |
| D3 | Stream global `/api/event` + filtro por sesión en el cliente. El stream por sesión da 404 medido. |
| D4 | El POST del prompt no devuelve el turno: se manda y se escucha el stream. |
| D5 | Bottom-nav de 4 destinos + hojas inferiores. Se elimina activity-bar, grid de paneles y splits. |
| D6 | Tokens de diseño reusados del cliente de escritorio (espejo de `tokens.css`). |
| D7 | Cero dependencias nuevas salvo `http`, `flutter_secure_storage`, `speech_to_text`, `flutter_svg`, `shared_preferences`. |
| D8 | Los 3 canales de error visibles (el cliente de escritorio se come `session.error`). |

## Trampas del server (medidas, no supuestas)

- Todo path desconocido devuelve **HTML 200** (catch-all del SPA).
- El heartbeat v2 es un **comentario SSE** (`: heartbeat`), no un evento.
- Los mensajes v2 traen `content[]` embebido, no `parts[]`.
- `tool.state.completed` usa `content[]`, no `output: String`.
- No mandes `?sessionID=` al stream: es un query no declarado y da **400**.
- `assistant.error` trae `type` (p.ej. `provider.auth`), no `name`.

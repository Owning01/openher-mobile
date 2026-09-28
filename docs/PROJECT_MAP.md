# PROJECT_MAP — OpenHer Mobile

> Estado **actual** de `G:\Proyectos\openher-mobile`. Reemplazar, nunca acumular historia.
> Bitácora: [`PROJECT_MEMORY.md`](./PROJECT_MEMORY.md).

## Qué es esto

App **Android nueva** en Flutter. Cliente delgado que habla **directo con el server de
opencode** (dialecto v2, `/api/*`). **No** depende de OpenHer ni de `openher-desktop.exe`.

## Estructura

| Ruta | Qué hay |
|---|---|
| `docs/API_CONTRACT.md` | Contrato de API **medido** contra el server real (auth, envolturas, mensajes, tools, errores, SSE, drift) |
| `docs/SUPER_PLAN.md` | El plan maestro: decisiones, arquitectura, performance, fases M0–M10, riesgos, tribunal |
| `prototype/mobile.html` | Maqueta navegable con toggles de capas (en construcción) |

Todavía **no** hay código Dart. El proyecto Flutter arranca en la fase M0.

## Decisiones cerradas

| # | Decisión |
|---|---|
| D1 | Sólo dialecto v2 (`/api/*`); si el server es v1, error explícito (no modo dual) |
| D2 | Credenciales por UI → `flutter_secure_storage`; `service.json` **no** existe en opencode2 |
| D3 | Stream por sesión `/api/session/{id}/event?after=` (durable, resumible) |
| D4 | POST del prompt y después escuchar (el POST no devuelve el turno) |
| D5 | Bottom nav de 4 destinos + hojas inferiores; se elimina activity-bar/grid/splits |
| D6 | Tokens reusados del escritorio (espejo de `tokens.css`) |
| D7 | Cero deps nuevas salvo `flutter_secure_storage` (+`speech_to_text` si se dicta) |
| D8 | Los 3 canales de error visibles (el escritorio se come `session.error`) |

## Contrato: lo que hay que no olvidar

- **Auth:** Basic `opencode:<OPENCODE_SERVER_PASSWORD>`; o `?auth_token=base64(user:pass)`
  para el SSE. El user se compara **siempre**; default `"opencode"`.
- **Probe de versión:** `GET /api/location` (NO `/api/health`: da 404 en este build).
- **Trampa:** todo path desconocido devuelve **HTML 200** (catch-all del SPA) → el parser
  rechaza `text/html` explícitamente.
- **Heartbeat v2:** comentario SSE `: heartbeat` cada 15 s, no un evento.
- **Mensajes v2:** `content[]` embebido (text/reasoning/tool), no `parts[]`.
- **Tool completed** usa `content[]`, no `output:string`; `error` es objeto, no string.
- **Fin de turno:** `session.status` + `time.completed`/`finish`; nunca por tiempo.
- **Orden de precedencia de auth:** `?auth_token` (query) gana sobre el header Basic.

## Server de desarrollo

`127.0.0.1:4098` · usuario `opencode` · password: la del `opencode serve` local
(en esta máquina escrita por el sidecar de OpenHer en
`%USERPROFILE%\.config\opencode\service.json`, pero **la app no lo lee**).

## Comandos (cuando exista el proyecto)

```powershell
flutter create . ; flutter run -d <android> ; flutter test ; flutter analyze
```

## Trampas conocidas

- `/api/health` no existe en el build de esta máquina ⇒ usar `/api/location`.
- `sessionID` como query del `/event` ⇒ **400** (query no declarada). Filtrar en el cliente.
- La API "form" (`/api/form/*`) no existe; las preguntas v2 son `/api/question/*`.
- `POST /session {directory}` ignora el body; el directorio va por query/header.

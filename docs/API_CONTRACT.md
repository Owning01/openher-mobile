# OpenHer Mobile — Contrato de API (medido, no supuesto)

> Todo lo de acá está **verificado contra el server real** (`127.0.0.1:4098`) o leyendo el
> código de `G:\Proyectos\opencode2`. Si algo no está verificado, está marcado
> `[POR VERIFICAR]`. No inventes campos: si no está acá, no existe.
>
> Medido: 2026-09-28. Servidor: `opencode 2.x` en `127.0.0.1:4098`.

---

## 1. Conexión y autenticación

### 1.1 Dónde vive la contraseña (IMPORTANTE)

> ⚠️ **opencode2 NO tiene `service.json`.** Búsqueda de texto completo en `packages/**`:
> cero resultados. `opencode serve` no tiene flag `--service`
> (`packages/opencode/src/cli/cmd/serve.ts:6-8`; sólo `--port/--hostname/--mdns/--cors`).
> El `service.json` es una convención del bootstrap de **OpenHer**
> (`opencode-remote-android/desktop-app/src/state.rs:1111`), no de opencode2.
>
> **Consecuencia para la app móvil: NO dependas de `service.json`.** La app corre en
> Android, no puede leer el disco del PC. Las credenciales las da el usuario
> (pantalla "Conectar al servidor") y se guardan en `flutter_secure_storage`.

Fuente real de la auth en opencode2 — variables de entorno (`server/auth.ts:17-20`,
`packages/server/src/auth.ts:20-38`):

| Env | Default | Regla |
|---|---|---|
| `OPENCODE_SERVER_PASSWORD` | — | Si está vacía o ausente ⇒ **la auth se desactiva** |
| `OPENCODE_SERVER_USERNAME` | `"opencode"` | Se compara **siempre**: debe ser exactamente `opencode` |

Comparación: `username === config.username && password === config.password`
(`auth.ts:28-34`). Servidor sin auth ⇒ nunca mandes `Authorization`.

### 1.2 Mecanismo: HTTP Basic, con dos carriers

`middleware/authorization.ts:77-83` (v1) y `packages/server/src/middleware/authorization.ts:29-36`
(idéntica lógica), **en este orden de precedencia**:

1. **`?auth_token=<base64(user:pass)>`** en la query — se chequea **ANTES** del header.
   Es la única forma de autenticar un `EventSource`/WebSocket que no puede setear headers.
   → **En móvil, el SSE va con `auth_token` en la URL** (o con header, que Dart sí puede, pero
   el query param es la vía probada y funciona en ambos).
2. **`Authorization: Basic base64(user:pass)`** — regex `/^Basic\s+(.+)$/i`.
3. Sin credenciales ⇒ `401`.

Decodificado: base64 → split en el **primer** `:`. Sin `:` o base64 inválido ⇒ credencial
vacía ⇒ 401 (`authorization.ts:57-71`).

Respuestas 401: v1 = cuerpo vacío + `www-authenticate: Basic realm="Secure Area"`;
v2 = `401 {_tag:"UnauthorizedError", message:"Authentication required"}`.

Exentos (sin credenciales): `/site.webmanifest`, los PNG del manifest, y el
**WebSocket de PTY cuando trae `?ticket=`** (`shared/pty-ticket.ts:5-15`).

### 1.3 Estado verificado en esta máquina

Medido el 2026-09-28 contra `127.0.0.1:4098`:
- `opencode:<password>` → **200** en `/api/session`, `/api/config`, `/api/provider`.
- otra password → **401**.
- En esta máquina hay un `%USERPROFILE%\.config\opencode\service.json` con
  `{hostname:"0.0.0.0", port:4098, password:<7 chars>}` — lo escribió el sidecar de
  OpenHer. Sirvió para verificar contra el server real, **pero la app móvil no lo lee**
  (no es de opencode2 y en Android no existe ese archivo).

### 1.4 Otros headers que hay que conocer

| Header | Para qué |
|---|---|
| `x-opencode-directory` | alternativa a `?directory=` / `?location[directory]=` |
| `x-opencode-workspace` | header de workspace del SDK v2 |
| `Accept` | `application/json` siempre; `text/event-stream` en el stream |

CORS es permisivo global (`httpapi/server.ts:121-128`) — irrelevante para Flutter nativo.

### 1.5 Detección de versión (no hay negociación)

**No hay header de versión ni param.** El split es **el prefijo de path**, y **ambos
dialectos están vivos en el mismo puerto a la vez** (`public.ts:180-182`:
`isV2ApiPath = p === "/api" || p.startsWith("/api/")`).

| | v1 (legacy) | v2 (actual) |
|---|---|---|
| Prefijo | ninguno (`/session`, `/event`, `/global/health`) | `/api` |
| Health | `GET /global/health` → `{healthy, version}` | `GET /api/health` → `{healthy:true}` |
| Envoltura | arrays pelados | `{data: …, cursor: …}` |
| Query de ubicación | `?directory=` | `?location[directory]=` |
| Ids | `msg…`, `prt…` | `msg_…` |
| Shape de mensaje | `{info, parts[]}` | `content[]` embebido |

Detección (la hace la app oficial, `packages/app/src/utils/server-protocol.ts:24-35`):
```
probe /global/health → si healthy===true ⇒ v1
probe /api/health    → si healthy===true ⇒ v2
```

**Decisión de OpenHer Mobile: v2 únicamente en la v1 del producto** (YAGNI). Si el probe
no devuelve v2, mostrar un error explícito *"servidor opencode v1: no soportado por la app
móvil"* en vez de mantener dos dialectos. El server del usuario (:4098) es v2.

### 1.6 ⚠️ Trampa del probe: el catch-all devuelve HTML 200

Todo path desconocido cae al SPA (`httpapi/server.ts:194-203`), así que un path inventado
devuelve **HTML con status 200**, no 404. Un parser ingenuo revienta.

Medido el 2026-09-28 en `:4098`:

| Probe | Resultado real |
|---|---|
| `GET /api/health` | **404** (¡el spec lo declara, este build no lo tiene!) |
| `GET /global/health` | **200 HTML** (catch-all, no es el endpoint) |
| **`GET /api/location`** | ✅ **200** `{"directory":"C:\\Users\\perca","project":{…}}` |
| `GET /api/session?limit=1` | ✅ 200 `{data:[…],cursor}` |
| `GET /api/session/active` | ✅ 200 `{"data":{"ses_…":{"type":"running"}}}` |
| `GET /api/vcs/diff` (sin `mode`) | 400 — **`mode` es requerido** |
| `GET /api/vcs/diff?mode=working` | ✅ 200 |
| `GET /api/session/{id}/children` | 404 (existe en v1, no en v2) |

⇒ **Probe de versión de la app móvil:** `GET /api/location` con timeout 3 s. Aceptar sólo si
la respuesta es JSON con `directory`. Rechazar explícitamente `content-type: text/html`
(que es la señal del catch-all). Ése es el probe. No `/api/health`.

---

## 2. Envoltura de respuestas

Todas las respuestas de lista son **envolturas con paginación por cursor**:

```jsonc
{ "data": [ ... ], "cursor": { "previous": "<b64>", "next": "<b64>" } }
```

El cursor es base64 de un JSON tipo `{"id":"msg_…","order":"desc","direction":"next"}`.
Úsalo para "cargar anteriores" (paginación hacia atrás) en listas largas.

---

## 3. Modelo de sesión — `GET /api/session`

Elementos reales medidos (v2, `SessionMessage`):

```jsonc
{
  "id": "ses_…",
  "projectID": "…",
  "agent": "build",
  "model": { "id": "space-bunny-free", "providerID": "opencode-go", "variant": "max" },
  "cost": 0.42,
  "tokens": { "input": 1234, "output": 567, "reasoning": 89,
              "cache": { "read": 0, "write": 0 } },
  "time": { "created": 1789605806638, "updated": 1789605806638 },
  "title": "…",
  "parentID": "ses_…",        // hijo = subagente
  "directory": "…",
  "revert": { … }             // presente si hay revert pendiente
}
```

- `parentID` presente ⇒ esa sesión es un **subagente** de otra.
- El estado *trabajando* de una sesión se lee del **SSE** (`session.status`), no de un campo del objeto.

---

## 4. Modelo de mensaje — `GET /api/session/{id}/message`

**OJO — es la generación v2, NO la v1 `parts[]`.** El contenido es un **array embebido**
dentro del mensaje, no partes separadas. Esto es lo que te vas a encontrar en el server real.

Cada elemento de `data[]` es un mensaje con estos tipos (`type`):

| `type` | Para qué es |
|---|---|
| `assistant` | Respuesta del modelo (tiene `content[]`) |
| `user` | Mensaje del usuario |
| `system` | Aviso del sistema (prompt de sistema, notices) |
| `synthetic` | Mensaje inyectado (synthetic, ej. summaries) |
| `compaction` | Resumen de compactación de contexto |
| `agent-switched` | Cambió de agente |
| `model-switched` | Cambió de modelo |
| `idle` | Marcador de fin de turno |

### 4.1 Mensaje assistant (medido)

```jsonc
{
  "id": "msg_0acd172ac001gfp0VexnizMhcZ",
  "time": { "created": …, "streamed": …, "completed": … },
  "type": "assistant",
  "agent": "build",
  "model": { "id": "deepseek-v4.1-flash", "providerID": "opencode-go", "variant": "max" },
  "content": [ … ],           // ← array embebido (v2)
  "finish": "stop",           // "stop" | "tool-calls" | "length" | …
  "rawFinish": "…",
  "cost": 0.011,
  "tokens": { "input": …, "output": …, "reasoning": …, "cache": {…} },
  "error": null | { … }       // error a nivel mensaje
}
```

### 4.2 Elementos de `content[]` (discriminated por `type`)

| `type` | Campos | Nota |
|---|---|---|
| `text` | `text` | respuesta visible al usuario |
| `reasoning` | `text` | el "pensamiento" (se puede colapsar) |
| `tool` | `id`, `name`, `executed`, `state` | ver abajo |

`tool` (medido):
```jsonc
{
  "type": "tool", "id": "call_function_…", "name": "shell",
  "executed": false,          // true = ejecutado por el provider, no por el server
  "state": {
    "status": "running" | "completed" | "error" | "pending",
    "input": { … },           // objeto de argumentos (p.ej. shell→{command,workdir})
    "content": [ { "type": "text", "text": "…" } ],   // salida
    "error": { … }            // sólo si status=error
  }
}
```

Nombres de tool reales observados: `shell`, `read`, `edit`, `subagent`, `skill`,
`question`, `glob`, `grep`, `todowrite`/`todo`, `task`, `write`, `patch`.

### 4.3 Tool `question` (input medido) — para la UI de pregunta

```jsonc
"input": { "questions": [ { "question": "…", "header": "…",
  "options": [ { "label": "…", "description": "…" } ], "multiple": false, "custom": true } ] }
```
Se responde vía el mecanismo de pregunta (ver §6) y vuelve un mensaje `user` con la respuesta.

### 4.4 Tool `subagent` — atribución

`input`: `{ "agent": "explore", "description": "Map …", "prompt": "…" }`.
Esto es lo que hace que en el chat se vea "un subagente está trabajando". **La
atribución de "quién mandó este mensaje" NO es un campo `from`:** se deriva de
- `message.agent` (el agente que produjo el mensaje), y
- la presencia de un tool `subagent` (con su `description` como etiqueta).
Ver `docs/PROJECT_MAP` del desktop: `messageAuthorFrom`.

---

## 5. Errores — TRES canales independientes

| Canal | Dónde | Qué es | ¿Letal? |
|---|---|---|---|
| A. `info.error` en el mensaje assistant | mensaje | `error` del mensaje (p.ej. `APIError`, `ProviderAuthError`, `ContextOverflowError`, `MessageAbortedError`…) | Sí, el turno murió |
| B. `state.status == "error"` en un tool | tool | el tool falló, el turno puede seguir | No, por-tool |
| C. evento `session.error` (SSE) | stream | error transitorio de sesión (p.ej. plugin, skill) | No, avisos |

Nombres de error del assistant (de `v1/session.ts:385-394`): `ProviderAuthError`,
`UnknownError`, `MessageOutputLengthError`, `MessageAbortedError`,
`StructuredOutputError`, `ContextOverflowError`, `ContentFilterError`, `APIError`.

Regla de UI móvil:
- Canal A ⇒ burbuja/card de error prominente con el nombre + mensaje + acción Reintentar.
- Canal B ⇒ el tool card se marca en `--danger` con su error; el turno sigue.
- Canal C ⇒ toast/snackbar no bloqueante.

---

## 6. Preguntas y permisos

Events y respuestas (contrato v1, que es el que se publica — los `.v2.` están declarados
pero **nunca se emiten**):
- `question.asked` `{ id, sessionID, questions: QuestionInfo[], tool? }` — la UI muestra la card.
  `QuestionInfo` = `{ question, header, options:[{label,description}], multiple?, custom? }`.
  Se responde `question.replied { sessionID, requestID, answers: string[][] }`.
- `permission.asked` `{ id, sessionID, permission, patterns[], metadata, always[], tool? }`.
  Se responde `permission.replied { sessionID, requestID, reply: "once"|"always"|"reject" }`.

`[POR VERIFICAR]` los endpoints REST exactos para responder pregunta/permisos (los voy a
confirmar contra el server antes de implementar la fase de sheets).

---

## 7. Eventos en vivo (SSE)

### 7.1 Cuál stream usar (decisión, CORREGIDA por medición)

| Stream | Ruta | Envoltura | Verificado en `:4098` |
|---|---|---|---|
| v2 global | **`GET /api/event`** | `{id, type, data}` + `location` + `durable{aggregateID,seq,version}` | ✅ **200 `text/event-stream`** (947 frames capturados) |
| v2 por sesión | `GET /api/session/{id}/event?after=` | `{id, event, data}` | ❌ **404** en este build |
| v2 por sesión (historia) | `GET /api/session/{id}/history` | `{data, hasMore}` | ❌ **404** en este build |
| v1 global | `GET /event?directory=` | `{id, type, properties}` | (dialecto v1, no usado) |
| busy de la lista | `GET /api/session/active` | `{data:{id:{type:"running"}}}` | ✅ 200 |

> ⚠️ **Corrección 2026-09-28.** El plan original (D3) elegía el stream **por sesión**
> `/api/session/{id}/event?after=` por ser durable y resumible. **Medido: da 404** en el
> build de `:4098` (el spec lo declara, pero el build no lo sirve). El stream que funciona
> es el **global `/api/event`**, que trae además `durable.seq` en cada frame.
>
> **D3bis (decisión vigente):** un solo stream **global** `/api/event` para toda la app, con
> **filtro por sesión del lado del cliente** (el `sessionID` viene dentro del payload).
> Se dedupea por `id` y se usa `durable.seq` para saber hasta dónde se leyó. Al reconectar:
> re-snapshot con `GET /api/session/{id}/message` y seguir. Ventaja extra: **un solo socket
> para toda la app** (también sirve el dot "En ejecución" de la lista), no uno por sesión.
>
> Prohibido mandar `?sessionID=` en el stream: es un query no declarado ⇒ **400**.

### 7.1bis Nombres de evento: lo que emite ESTE build

El spec más nuevo los llama `session.next.*.delta`; **medido en `:4098` el stream emite
`session.text.delta`, `session.reasoning.delta`, `session.tool.input.delta`**
(sin `next.`). Los predicados de `lib/domain/models/event.dart` aceptan **ambos**
conjuntos (`kDeltaEvents` / `kSettledEvents`), así que la app no se rompe si el server
cambia de generación.

`assistant.error` medido: `{"type":"provider.auth","message":"…","status":401}` — o sea
`type`, no `name`. `OcErrorInfo` resuelve `name ?? type` y
`message ?? data.message ?? error ?? text`, con lo que cubre v1, v2 medido y el
`{name:"APIError"}` del SDK.

### 7.2 Frames

Formato de cada frame: `event: message` + `data: <json>`.
- v1: `{"id","type","properties":{…}}` — `properties` es el payload.
  `durable/location/metadata` se descartan en el server (`handlers/event.ts:40`).
- **v2: `{"id","type","data":{…}}` — la clave es `data`, NO `properties`.**
  Ojo: el parser del cliente de escritorio lo resuelve con
  `properties = parsed['properties'] ?? unwrapData(parsed)` (`sse_client.dart:87-98`).
  En móvil hay que hacerlo igual si se quiere leer ambos.
- `/api/session/{id}/event` usa `{id, event, data}` (la clave del tipo es `event`, no `type`).
- Heartbeat: v1 = evento `server.heartbeat` cada **10 s**; **v2 = comentario SSE
  `: heartbeat` cada 15 s** (`packages/server/src/handlers/event.ts:37`) — o sea que un
  parser que no ignore comentarios se rompe con v2.
- Primer frame: `{"type":"server.connected"}`.

### 7.3 Lo que el cliente de escritorio hace MAL (no copiar)

| Bug | Detalle |
|---|---|
| `sessionID` en la query del `/event` | No está declarado en `EventApi` (`groups/event.ts:15`) y el middleware hace **400** con query params no declarados (`workspace-routing.ts:17-21`). El filtro por sesión es **client-side**. |
| `session.error` ignorado | No hay case para ese evento en todo `lib/`: cae al `default` y se descarta. El error sólo aparece indirectamente en el siguiente poll como `info.error`. **La app móvil lo maneja.** |
| `status: "retry"` sin parsear el `action` | `SessionStatus.retry` trae `action:{reason,provider,title,message,label,link}`; el escritorio sólo lee `type`. En móvil, mostrar "Reintentando en Ns — <title>" con el link. |

### 7.4 Fin de turno (regla)

`working` = último assistant con `time.completed == null` **o** `session.status ∈ {busy, running, retry}`.
`idle` = `session.status ∈ {idle, completed, done, success, succeeded}` **y** el último
assistant con `time.completed != null` (o `finish != null`).
Nunca "por tiempo": el botón Detener se mantiene visible hasta esta evidencia real.

### 7.5 Delta es sólo en vivo

`session.next.text.delta` / `reasoning.delta` / `tool.input.delta` son live-only; el valor
completo llega en `text.ended` / `reasoning.ended` y en el mensaje completo. Si se pierden
deltas, se converge igual con un re-fetch; si se pierde el `ended`, no.

---

## 8. Endpoints v2 (`/api/*`) — verificados contra el spec y el server

Fuente de verdad: `packages/sdk/openapi.json` (188 operaciones, generado de
`PublicApi` en `server.ts:67-69`) + `packages/protocol/src/groups/*.ts`.
`?location[directory]=` / `?location[workspace]=` como `deepObject`.

### Sesión (lo que la app móvil usa)

| Método | Path | Body / q | Devuelve | Para qué |
|---|---|---|---|---|
| GET | `/api/health` | — | `{healthy:true}` | probe de versión (§1.5) |
| GET | `/api/location` | `location` | `{directory, workspaceID?, project}` | resuelve el directorio |
| GET | `/api/session` | `limit?`(def 50), `order?(asc\|desc)`, `search?`, `project?`, `subpath?`, `cursor?` | `{data:SessionV2Info[], cursor:{previous?,next?}}` | lista de sesiones |
| POST | `/api/session` | `{id?, agent?, model?:{id,providerID,variant?}, location?}` | `{data}` | crear sesión |
| GET | `/api/session/active` | — | `{data:{sessionID:{type:"running"}}}` | dots "En ejecución" de la lista |
| GET | `/api/session/{id}` | — | `{data}` (404) | una sesión |
| POST | `/api/session/{id}/agent` | `{agent}` | 204 | cambiar agente |
| POST | `/api/session/{id}/model` | `{model:{id,providerID,variant?}}` | 204 | cambiar modelo |
| **POST** | **`/api/session/{id}/prompt`** | `{id?, prompt:{text, files?:[{uri,name}], agents?}, delivery?:steer\|queue, resume?}` | `{data:{id, admittedSeq, …}}` (409 si colisiona el `id`) | **enviar prompt** |
| POST | `/api/session/{id}/interrupt` | — | 204 | **detener** (no-op si ya está idle) |
| POST | `/api/session/{id}/wait` | — | 204 | bloquea hasta idle |
| POST | `/api/session/{id}/compact` | — | 204 | compactar |
| GET | `/api/session/{id}/message` | `limit?`(1..200), `order?`, `cursor?` | `{data:SessionMessage[], cursor}` | **mensajes** |
| GET | `/api/session/{id}/message/{msgID}` | — | `{data}` (404) | un mensaje |
| GET | `/api/session/{id}/context` | — | `{data:SessionMessage[]}` | contexto post-compactación |
| GET | `/api/session/{id}/history` | `limit?`(≤100), `after?` | `{data:SessionDurableEvent[], hasMore}` | página de eventos durables |
| **GET** | **`/api/session/{id}/event`** | `after?` | **SSE `{id,event,data}`** | **stream de la sesión** |
| GET | `/api/session/{id}/revert/stage` → POST | `{messageID*, files?}` | `{data:RevertState}` | revertir |
| POST | `/api/session/{id}/revert/clear` \| `/commit` | — | 204 | |

**Regla de oro del streaming:** el POST del prompt **no** devuelve el turno.
Devuelve el "admite" y listo. Todo el turno llega por el SSE de la sesión.
(En v1 es igual de importante: `POST /session/{id}/message` devuelve un `application/json`
de un solo chunk cuando el turno ya terminó — o sea, es bloqueante; para no bloquear,
`POST /session/{id}/prompt_async` → 204.)

### Archivos, providers, agentes (v2)

| Método | Path | q | Devuelve |
|---|---|---|---|
| GET | `/api/fs/list` | `location`, `path?` | `{location,data}` (lista un dir) |
| GET | `/api/fs/find` | `location`, `query*`, `type?`, `limit?` | `{location,data}` |
| GET | `/api/fs/read/*` | `location` | binario |
| GET | `/api/model` | `location` | `{location,data}` (503 si no está) |
| GET | `/api/provider` \| `/api/provider/{id}` | `location` | `{location,data}` |
| GET | `/api/agent` \| `/api/command` \| `/api/skill` | `location` | `{location,data}` |
| GET | `/api/mcp/resource` | `location` | `{location,data}` y **`data` es un objeto** `{resources[],templates[]}`, NO una lista |
| GET | `/api/question/request`, `/api/session/{id}/question` | `location` | pendientes |
| POST | `/api/session/{id}/question/{requestID}/reply` \| `/reject` | | 204 |
| GET | `/api/permission/request`, `/api/session/{id}/permission` | `location` | pendientes |
| POST | `/api/session/{id}/permission/{requestID}/reply` | `{reply, message?}` | 204 |

### 8.1 Comandos de barra y el menú del compositor (medido 2026-09-29)

El server expone **tres** comandos, y esa es la lista completa:

```
GET /api/command?location[directory]=...
  -> {location, data:[{name, description}]}
     name=init    description="guided AGENTS.md setup"
     name=review  description="review changes [commit|branch|pr], defaults to uncommitted"
     name=debate  description="Mesa de trabajo colaborativa (default isolated)."
```

Con y sin `directory` da lo mismo: el parámetro no filtra nada.

| Método | Path | Body | Devuelve |
|---|---|---|---|
| POST | `/api/session/{id}/command` | **`{name, text}`**, ambos requeridos, `additionalProperties:false` | 204 sin cuerpo |

Dos trampas, ambas medidas:

- El campo se llama **`name`**, no `command`. Mandar `{command, text}` da
  **400 `Missing key ["name"]`**.
- El `name` viaja **sin la barra**: el lookup del server es exacto, así que
  `/review` da **404**. El strip va en `ApiClient.runCommand`, no en el caller.
- Omitir `text` también da **400**: es requerido, no opcional. El cliente manda
  `''` cuando no hay argumentos.

**Lo que NO es un comando.** `compact`, `undo`, `redo`, `summarize`, `help` y
`status` dan **404** en `POST /api/session/{id}/command`: no existen como
comandos. El cliente web de OpenHer los anuncia igual (los tiene hardcodeados
en `composerData.ts`, 13 de ellos) y por eso fallan al usarlos. Los que sí
existen, como endpoints:

| Método | Path | Body | Devuelve |
|---|---|---|---|
| POST | `/api/session/{id}/compact` | `{}` (**sin body da 400**) | 200 con el mensaje `type:"compaction"` |
| POST | `/api/session/{id}/revert/stage` | **`{messageID}`** requerido; `{}` da 400 | 200 |
| POST | `/api/session/{id}/revert/commit` | `{}` | **204** sin cuerpo |

El "deshacer" del server **no es de un paso**: es `stage` + `commit`. No existe
`POST /session/{id}/undo` ni `/redo` (404, medido), y tampoco
`/message/{id}/revert` (404).

`GET /api/session/{id}/context` existe y devuelve el **contenido** del contexto
(el árbol de mensajes con su resumen de compactación), no un número: 331 KB en
una sesión larga. **No** usarlo para el contador de contexto.

### 8.2 Las fuentes del `@` (medido 2026-09-29)

| Método | Path | Devuelve | Tamaño medido |
|---|---|---|---|
| GET | `/api/agent` | 26 agentes, 20 visibles (los `hidden` son internos) | 87 KB |
| GET | `/api/skill` | 32 skills con `id`, `name`, `description` | **490 KB** |
| GET | `/api/fs/find` | hits con `path` y `type` | — |
| GET | `/api/mcp/resource` | `data` = **objeto** `{resources[],templates[]}` | 84 B sin servers |

- `/api/find/file` da **404**. La ruta es `/api/fs/find`.
- Un `directory` que **no existe** da **500**, no una lista vacía. Se distingue
  de una lista vacía legítima (200 + `data: []`), que se pinta como "sin
  coincidencias".

### 8.3 El contexto: `session.tokens` NO es el contexto (medido 2026-09-29)

`session.tokens` es un **contador acumulado** de toda la vida de la sesión:
`input`, `output` y `cache.read` de *todos* los turnos, sumados. Sólo crece.

El contexto de verdad es el prompt del **último** turno del assistant:

```
contexto = assistant.tokens.input
         + assistant.tokens.cache.read
         + assistant.tokens.reasoning
```

`cache.write` queda fuera (lo relee el próximo turno como `cache.read`: sumarlo
cuenta el mismo prefijo dos veces) y `output` también (es lo generado, no lo
cargado).

Medido sobre `ses_f685c4cfdffe7Bp2IL`: `session.tokens` daba `input=19.892.436`
y el contexto real era **195.089** — el número viejo era **115×** inflado.

`/session`, `/session/{id}/message` (→ `{info,parts}[]`, paginado con `Link`/`X-Next-Cursor`),
`/session/{id}/abort`, `/question`, `/question/{req}/reply`, `/permission`, `/file`, `/find`,
`/vcs/*`, `/mcp*`, `/pty*`, `/global/health`, `/event`.

---

## 9. Drift: lo que el cliente de escritorio llama y NO EXISTE (no copiar)

Verificado contra `openapi.json`. Cada uno ya tiene fallback en el escritorio, salvo marcado:

| Llamado por el escritorio | ¿En el spec? | Nota |
|---|---|---|
| `GET /event?...&sessionID=` | **No** | `EventApi` sólo acepta `{directory, workspace}`; query no declarada ⇒ **400**. Filtrar por sesión en el cliente. |
| `GET /api/form/request`, `/api/session/{id}/form/{id}`, `…/reply` | **No** | v2 usa `/api/question/*`. La API "form" no está en el protocol actual. |
| `POST /session {directory}` | Campo inexistente | El directorio va por `?directory` / `x-opencode-directory`; el body lo ignora en silencio. |
| `POST /permission/{id}/reply {approve:bool}` | No | v1 quiere `{reply:"once"\|"always"\|"reject", message?}`. |
| `GET /api/health` → `{pid}` | No | Devuelve `{healthy:true}` solamente (el branch `pid` de la app oficial está roto). |
| `GET /session/{id}/rename`, `GET /session/{id}/diff/{file}`, `GET /vcs/diff/raw?file=`, `GET /api/model/default`, `POST /api/integration/{id}/disconnect`, `GET /api/mcp*` | No | Usar los paths reales de §8. MCP es v1-only. |
| `POST /session/{id}/message` body `{text, modelID, providerID, agent}` | No | El body real (v1) es `{parts[], model:{providerID,modelID}, agent, …}`. |

---

## 9. Reglas para no cometer errores (lecciones del escritorio)

1. **Nunca hardcodear credenciales.** Leer de `service.json` o prompt; `opencode` es el user default.
2. **Autenticación**: si da 401, es la password — no el path.
3. **El server es v2**: los mensajes traen `content[]` embebido y `cursor`. No asumas `parts[]`.
4. **Atribución sin `from`**: derivar de `agent` + tool `subagent`.
5. **Tres canales de error**: assistant.error / tool.state.error / session.error.
6. **Delta es sólo en vivo**: el valor completo llega en `*.ended` o en el `message`/`part.updated`; reconectar = re-snapshot.
7. **Fin de turno** por `session.status` + `time.completed`/`finish`, nunca "por tiempo".
8. **Cero emojis en la UI**: sólo SVG.

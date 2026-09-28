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

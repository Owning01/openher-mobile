# OpenHer Mobile

<p align="center">
  <img src="assets/demo.webp" alt="OpenHer Mobile App Demo" width="340">
</p>

<p align="center">
  <strong>Native & ultra-lightweight Android client for OpenCode</strong><br>
  <em>Your sessions, agents, tools, and code right from your phone</em>
</p>

<p align="center">
  <a href="https://github.com/Owning01/openher-mobile/releases/latest">
    <img src="https://img.shields.io/badge/Download%20APK-Latest%20Release-success?style=for-the-badge&logo=android" alt="Download APK">
  </a>
</p>

<p align="center">
  <a href="#english">English</a> • <a href="#español">Español</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Status-Active%20Beta-orange?style=flat-square" alt="Beta Status">
  <img src="https://img.shields.io/badge/Platform-Android-blue?style=flat-square&logo=android" alt="Android Platform">
  <img src="https://img.shields.io/badge/API-OpenCode%20v2%20REST%20%2B%20SSE-success?style=flat-square" alt="OpenCode v2 API">
</p>

---

<a name="english"></a>
## English

> [!WARNING]
> ### 🚧 Project Status: Active Beta
> **OpenHer Mobile is currently in active Beta development.** Features, performance enhancements, and incremental updates are released regularly. Contributions, feedback, and issue reports are very welcome!

### 📱 What is OpenHer Mobile?

**OpenHer Mobile** brings your **OpenCode** development workflow to your mobile device:

* **Direct API Connection:** Communicates natively with the OpenCode server (v2 dialect under `/api/*`) with zero overhead or heavy desktop dependencies.
* **Real-time Streaming:** Reactive Server-Sent Events (SSE) stream assistant outputs, execution states, and tool runs in real time.
* **Mobile Ergonomics:** Smooth touch interactions, thumb-friendly bottom navigation, adapted dark theme, and low-power/low-data mobile policies.
* **Secure Storage:** All server credentials and session tokens are stored encrypted using Android's Keystore (`flutter_secure_storage`).

---

### 📸 Main Views

| 💬 Sessions | ⚡ Chat & Streaming | 📁 Files | ⚙️ Settings |
|:---:|:---:|:---:|:---:|
| <img src="assets/screenshots/01_sessions.png" width="180" alt="Sessions"> | <img src="assets/screenshots/02_chat.png" width="180" alt="Chat"> | <img src="assets/screenshots/03_files.png" width="180" alt="Files"> | <img src="assets/screenshots/04_settings.png" width="180" alt="Settings"> |
| History, active statuses & search | Live turns, code blocks & tool cards | Remote workspace file explorer | Connection & theme controls |

---

### 🌐 Connecting the App to your OpenCode Server

When opening OpenHer Mobile for the first time, you'll be greeted by the connection setup screen. You will need your running `opencode serve` credentials.

#### 1. Required Connection Details
* **Host / IP:** Your PC's local network IP or your Tailscale IP (see diagram below).
* **Port:** Default is `4098` (or the port specified in `opencode serve`).
* **Username:** Default is `opencode`.
* **Password:** The password set on your server (from `OPENCODE_SERVER_PASSWORD`).

---

#### 2. Network Scenarios: Same Wi-Fi vs Remote (Tailscale)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       SCENARIO A: SAME WI-FI NETWORK                        │
│                                                                             │
│    [ Computer with OpenCode ] ◄────── Local Wi-Fi ──────► [ Mobile Phone ]  │
│             192.168.1.50                                      Host:         │
│             Port: 4098                                    192.168.1.50      │
│                                                            Port: 4098       │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                 SCENARIO B: DIFFERENT NETWORKS / REMOTE (TAILSCALE)         │
│                                                                             │
│  [ Computer at Home / Office ]                          [ Phone on 4G/5G    │
│         Tailscale VPN                                   or another Wi-Fi ]  │
│         100.85.120.45:4098                                Tailscale VPN     │
│                 ▲                                               ▲           │
│                 └─────────── Encrypted Mesh Tunnel (VPN) ───────┘           │
│                                                                             │
│                        In OpenHer Mobile set:                               │
│                         Host: 100.85.120.45                                 │
│                         Port: 4098                                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 💡 Away from home or using cellular data?
If your mobile device is not on the same local Wi-Fi network as your computer:
1. Install **[Tailscale](https://tailscale.com/)** on both your PC and your Android phone.
2. Sign in with the same account on both devices.
3. Copy your PC's **Tailscale IP address** (starts with `100.x.y.z`).
4. In **OpenHer Mobile**, paste that IP into the **Host** field and tap Connect. Done! You now have a private, encrypted connection without needing port forwarding.

---

### 📦 Download & Install

The latest Android APK package is available directly on GitHub Releases:

👉 **[Download Latest OpenHer Mobile APK (Releases)](https://github.com/Owning01/openher-mobile/releases/latest)**

*(Download `app-release.apk` to your phone and install it. Allow installation from unknown sources if prompted).*

---

<a name="español"></a>
## Español

> [!WARNING]
> ### 🚧 Estado del Proyecto: Versión Beta en Desarrollo
> **OpenHer Mobile se encuentra actualmente en fase Beta activa.** La aplicación recibe actualizaciones, mejoras de rendimiento e incrementos continuos. ¡Contribuciones, comentarios y reportes de errores son bienvenidos!

### 📱 ¿Qué es OpenHer Mobile?

**OpenHer Mobile** está diseñado específicamente para llevar el flujo de trabajo de **OpenCode** a tu teléfono:

* **Conexión directa:** Habla de forma nativa con el servidor de OpenCode (dialecto v2 bajo `/api/*`) sin intermediarios ni dependencias pesadas.
* **Streaming en tiempo real:** Flujo reactivo vía SSE (Server-Sent Events) para visualizar las respuestas del asistente, estados de ejecución y herramientas (*tools*) a medida que operan.
* **Ergonomía móvil:** Navegación por gestos, pestañas inferiores accesibles con una mano, tema oscuro adaptado y rendimiento optimizado para bajo consumo de batería y datos móviles.
* **Credenciales seguras:** La autenticación se guarda localmente y cifrada con el almacén seguro de Android (`flutter_secure_storage`).

---

### 📸 Vistas Principales

| 💬 Sesiones | ⚡ Chat & Streaming | 📁 Archivos | ⚙️ Ajustes |
|:---:|:---:|:---:|:---:|
| <img src="assets/screenshots/01_sessions.png" width="180" alt="Sesiones"> | <img src="assets/screenshots/02_chat.png" width="180" alt="Chat"> | <img src="assets/screenshots/03_files.png" width="180" alt="Archivos"> | <img src="assets/screenshots/04_settings.png" width="180" alt="Ajustes"> |
| Historial, estados activos y filtros | Ejecución de turnos, código y tools | Explorador de archivos del proyecto | Configuración de servidor y temas |

---

### 🌐 Cómo Conectar la App al Servidor OpenCode

Al abrir la aplicación por primera vez verás la pantalla de conexión. Para vincularla con tu computadora necesitas los datos con los que corre `opencode serve`.

#### 1. Datos de conexión requeridos
* **Host / IP:** La dirección IP de tu máquina en la red local o tu IP de Tailscale (ver diagrama abajo).
* **Puerto:** Por defecto `4098` (o el puerto configurado en `opencode serve`).
* **Usuario:** Por defecto `opencode`.
* **Contraseña:** La contraseña configurada en tu servidor (variable `OPENCODE_SERVER_PASSWORD`).

---

#### 2. Escenarios de Red: Local vs Fuera de Casa (Tailscale)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       ESCENARIO A: MISMA RED WI-FI                          │
│                                                                             │
│    [ Computadora con OpenCode ] ◄────── Wi-Fi Local ──────► [ Celular ]     │
│             192.168.1.50                                      Host:         │
│             Puerto: 4098                                  192.168.1.50      │
│                                                            Puerto: 4098     │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                   ESCENARIO B: REDES DISTINTAS (TAILSCALE)                  │
│                                                                             │
│  [ Computadora en Casa / Oficina ]                      [ Celular en 4G/5G  │
│         Tailscale VPN                                   o en otra Wi-Fi ]   │
│         100.85.120.45:4098                                Tailscale VPN     │
│                 ▲                                               ▲           │
│                 └─────────── Túnel Seguro Mesh (VPN) ───────────┘           │
│                                                                             │
│                         En la app móvil ingresas:                           │
│                          Host: 100.85.120.45                                │
│                          Puerto: 4098                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 💡 ¿Estás fuera de casa o usando datos móviles?
Si tu teléfono no está conectado a la misma red Wi-Fi que tu computadora:
1. Instala **[Tailscale](https://tailscale.com/)** tanto en tu computadora como en tu celular Android.
2. Inicia sesión con la misma cuenta en ambos dispositivos.
3. Copia la dirección **IP de Tailscale de tu PC** (suele comenzar en `100.x.y.z`).
4. En **OpenHer Mobile**, escribe esa IP en el campo **Host** y conecta. ¡Listo! Tendrás acceso cifrado punto a punto desde cualquier lugar del mundo sin abrir puertos en tu router.

---

### 📦 Descarga e Instalación

El archivo instalable (APK) más reciente para Android está disponible directamente en GitHub:

👉 **[Descargar último APK de OpenHer Mobile (Releases)](https://github.com/Owning01/openher-mobile/releases/latest)**

*(Descarga `app-release.apk` en tu dispositivo Android e instálalo permitiendo la instalación de orígenes desconocidos si tu navegador lo solicita).*

<#
.SYNOPSIS
  Publica el APK y el manifiesto de autoupdate.

.DESCRIPTION
  Sube el APK de release a las releases de GitHub y escribe `latest.json`
  al lado, que es lo que la app lee para saber si hay versión nueva.

  El manifiesto se sube SIEMPRE después del APK, y el tag se mueve al final.
  Ese orden importa: si `latest.json` se publicara antes que el APK, un
  dispositivo que chequea en ese medio minuto descarga un 404 y cree que hay
  una versión nueva que no existe.

.PARAMETER Notes
  Qué cambió. Va al manifiesto (texto plano) y al cuerpo del release.

.PARAMETER SkipBuild
  Publica el APK que ya está en `build\app\outputs\flutter-apk\`, sin recompilar.

.EXAMPLE
  .\scripts\publish-update.ps1 -Notes "modelos, nivel de pensamiento, autoupdate"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Notes,
  [switch]$SkipBuild,
  [string]$Version = ''
)

# --------------------------------------------------------------------------
# Guard de version: este script corre con PowerShell 7 o superior.
#
# Windows PowerShell 5.1 no se puede desinstalar: es un componente del sistema
# operativo, con su binario en control de TrustedInstaller, y Windows Update
# lo sigue usando. Ademas se comporta distinto en justo lo que este script
# hace (redireccion de streams, Invoke-RestMethod, codificacion de salida),
# asi que dejarlo correr en silencio es peor que negarse a correr.
# --------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Host 'Este script necesita PowerShell 7+ y se esta ejecutando bajo 5.1.'
  Write-Host ''
  Write-Host 'Correlo con:  pwsh -File .\publish-update.ps1  <tus argumentos>'
  Write-Host '(en Windows Terminal el perfil por defecto ya es PowerShell 7.6)'
  exit 1
}


$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$root = (Get-Location).Path

if (-not $Version) {
  $line = (Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\S+)\+(\d+)\s*$').Matches[0]
  if (-not $line) { throw 'No se pudo leer `version:` de pubspec.yaml' }
  $Version = "$($line.Groups[1].Value)+$($line.Groups[2].Value)"
}
$versionName = $Version.Split('+')[0]
$versionCode = [int]$Version.Split('+')[1]
$apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'

if (-not $SkipBuild) {
  Write-Host 'Compilando el APK de release (solo arm64)...'
  # **Medido 2026-09-28**: el APK universal pesa 73,6 MB y el de arm64 26,8 MB.
  # La diferencia son 3 copias de `libflutter.so`, `libapp.so` y `libpdfium.so`
  # (el motor de `pdfrx` son 16,4 MB solo). Un APK que baja el celular por datos
  # moviles tiene que ser el chico.
  #
  # Costo real (medido en el APK publicado): `arm64-v8a` pesa 24,8 MB y en
  # `armeabi-v7a` / `x86_64` quedan 0,1 MB de restos (`libdartjni.so` y el
  # helper de pdfrx). El manifest igual los declara, asi que un dispositivo
  # de SOLO 32 bits instalaria y reventaria al arrancar. En la practica no
  # pasa: Android 15+ es 64 bits y el target es 36. Para 32 bits de verdad:
  # `--split-per-abi` con un manifiesto por ABI, no volver al universal.
  & flutter build apk --release --target-platform android-arm64
  if ($LASTEXITCODE -ne 0) { throw "flutter build falló ($LASTEXITCODE)" }
}
if (-not (Test-Path $apk)) { throw "No existe el APK en $apk" }

$mb = [math]::Round((Get-Item $apk).Length / 1MB, 2)
Write-Host "APK $version ($mb MB)"

# El `url` del manifiesto tiene que ser el asset ya subido: por eso el
# manifiesto se arma DESPUES del upload, no antes.
$assets = @{
  'Owning01/openher-mobile'  = "v$versionName"
  'Owning01/mis-apps'       = "openher-mobile-v$versionName"
}
$apkUrl = "https://github.com/Owning01/openher-mobile/releases/download/v$versionName/app-release.apk"

foreach ($entry in $assets.GetEnumerator()) {
  $repo = $entry.Key
  $tag  = $entry.Value
  Write-Host "Publicando en $repo / $tag"

  # `gh release view` escribe "release not found" en stderr cuando no existe, y
  # con `$ErrorActionPreference = 'Stop'` eso corta el script antes de poder
  # crear la release. Por eso la sonda va con la preferencia relajada y decide
  # por el exit code, que es lo unico fiable para un comando nativo.
  $ErrorActionPreference = 'Continue'
  & gh release view $tag -R $repo *> $null
  $exists = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = 'Stop'

  if (-not $exists) {
    & gh release create $tag --repo $repo --title "OpenHer $versionName" --notes $Notes --latest
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear la release $tag en $repo" }
  }

  & gh release upload $tag $apk --repo $repo --clobber
  if ($LASTEXITCODE -ne 0) { throw "Falló el upload del APK a $repo" }
}

# El manifiesto va después del APK, en ambas repos. El archivo tiene que
# llamarse EXACTAMENTE `latest.json`: el nombre del asset es el que la app
# pide en la URL, y `gh` sube el basename del archivo.
$manifest = [ordered]@{
  version      = $versionName
  versionCode  = $versionCode
  url          = $apkUrl
  notes        = $Notes
  published_at = (Get-Date).ToUniversalTime().ToString('o')
}
$json = ($manifest | ConvertTo-Json -Depth 4)
$manifestDir = Join-Path $env:TEMP 'openher-release'
New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null
$manifestPath = Join-Path $manifestDir 'latest.json'
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Manifiesto:`n$json"

foreach ($entry in $assets.GetEnumerator()) {
  & gh release upload $entry.Value $manifestPath --repo $entry.Key --clobber
  if ($LASTEXITCODE -ne 0) { throw "Falló el upload del manifiesto a $($entry.Key)" }
  & gh release edit $entry.Value -R $entry.Key --notes $Notes *> $null
}

# El chequeo final: si el manifiesto no responde 200 con el versionCode
# esperado, el autoupdate está roto para todos los dispositivos que ya tienen
# la app. Mejor fallar acá que descubrirlo cuando alguien abre la app.
#
# Se lee con `curl.exe` y no con `Invoke-RestMethod` a propósito: medido 2026-09-28,
# PowerShell 5.1 devuelve **500** contra el redirect de assets de GitHub
# (`releases/latest/download/...`) aunque la URL responda 200 de verdad. Un
# chequeo que falla cuando todo anda bien entrena al script para que ignore sus
# propios errores, que es peor que no chequear.
$latest = 'https://github.com/Owning01/openher-mobile/releases/latest/download/latest.json'
$body = Join-Path $env:TEMP 'openher-latest-check.json'
$seen = $null
foreach ($attempt in 1..5) {
  Start-Sleep -Seconds 3
  $code = & curl.exe -s -L -o $body -w '%{http_code}' $latest
  if ($code -eq '200') {
    $seen = Get-Content $body -Raw | ConvertFrom-Json
    break
  }
  Write-Host "  intento ${attempt}: HTTP $code"
}
if (-not $seen) { throw "El manifiesto no responde 200 en $latest" }
if ($seen.versionCode -ne $versionCode) {
  throw "El manifiesto publicado dice versionCode $($seen.versionCode) y esperábamos $versionCode"
}

Write-Host ''
Write-Host "OK  $versionName ($versionCode) publicado y verificado"
Write-Host "    APK:         $apkUrl"
Write-Host "    Manifiesto:  $latest"

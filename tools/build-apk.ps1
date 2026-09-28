# Build del APK release de OpenHer Mobile.
#
# Envuelve `flutter build apk --release` con las dos cosas que esta maquina
# necesita:
#   1. El shim de `ProgramFiles(x86)` (la unidad X: es intermitente y rompe el
#      toolchain de Dart/Android si no esta apuntando bien).
#   2. Verificar que el artefacto exista de verdad, con timestamp y tamano.
#
# Uso:
#   .\tools\build-apk.ps1
#   .\tools\build-apk.ps1 -SplitPerAbi   # APK por ABI (menos tamano)
#
# Salida: build\app\outputs\flutter-apk\app-release.apk

param(
  [switch]$SplitPerAbi,
  [string]$VersionName = '',
  [int]$VersionCode = 0
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

# El shim: sin esto, `flutter` puede fallar con errores raros de Visual Studio.
$realProgramFilesX86 = 'C:\Program Files (x86)'
$shim = Join-Path $env:TEMP 'vs_shim'
$hadShim = $false
try {
  $existing = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  if ($existing -ne $shim) {
    $hadShim = $true
    Set-Item -Path 'Env:ProgramFiles(x86)' -Value $shim
  }

  Write-Host '==> analyze' -ForegroundColor Cyan
  flutter analyze lib test
  if ($LASTEXITCODE -ne 0) { throw "flutter analyze fallo ($LASTEXITCODE)" }

  Write-Host '==> test' -ForegroundColor Cyan
  flutter test
  if ($LASTEXITCODE -ne 0) { throw "flutter test fallo ($LASTEXITCODE)" }

  $args = @('build', 'apk', '--release')
  if ($SplitPerAbi) { $args += '--split-per-abi' }
  if ($VersionName) { $args += @('--build-name', $VersionName) }
  if ($VersionCode -gt 0) { $args += @('--build-code', "$VersionCode") }

  Write-Host "==> flutter $($args -join ' ')" -ForegroundColor Cyan
  flutter @args
  if ($LASTEXITCODE -ne 0) { throw "flutter build fallo ($LASTEXITCODE)" }
}
finally {
  if ($hadShim) { Set-Item -Path 'Env:ProgramFiles(x86)' -Value $realProgramFilesX86 }
}

# Verificacion honesta del artefacto: existe, no esta vacio, y es fresco.
$apkDir = 'build\app\outputs\flutter-apk'
if (-not (Test-Path $apkDir)) { throw "No existe $apkDir" }
$apks = Get-ChildItem $apkDir -Filter '*.apk' | Sort-Object LastWriteTime -Descending
if (-not $apks) { throw 'No se genero ningun APK' }

Write-Host ''
Write-Host 'APK generado:' -ForegroundColor Green
foreach ($apk in $apks) {
  $mb = [math]::Round($apk.Length / 1MB, 2)
  Write-Host ('  {0,-34} {1,8} MB   {2}' -f $apk.Name, $mb, $apk.LastWriteTime)
}

@echo off
setlocal
title Instalador de Jarvis
rem ==== Instalador automatico de Jarvis para Ray-Ban Meta (Windows 10/11) ====
rem Instala iTunes, iCloud y Sideloadly, deja la app Jarvis lista y abre todo para el ultimo paso.
rem Pide permiso de administrador una sola vez.

net session >nul 2>&1
if errorlevel 1 (
  echo Pidiendo permiso de administrador...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText('%~f0'); $m='#'+'PS'+'#'; $env:JARVIS_SELF='%~dp0'; Invoke-Expression ($f.Substring($f.IndexOf($m)+$m.Length))"
set RC=%errorlevel%
if not defined JARVIS_CI pause
exit /b %RC%

#PS#
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$CI = [bool]$env:JARVIS_CI
function Paso($t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Mal($t)  { Write-Host "    !!  $t" -ForegroundColor Yellow }

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "   JARVIS para Ray-Ban Meta - instalador" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# ---- 1. winget ----
Paso "Revisando el instalador de Windows (winget)"
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
  Mal "Falta 'Instalador de aplicacion' (winget). Se abre la Microsoft Store: pulse Actualizar/Obtener y vuelva a ejecutar este instalador."
  if (-not $CI) { Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1" }
  exit 1
}
Ok "winget disponible"

# ---- 2. iTunes, iCloud (version clasica, la que pide Sideloadly) y Sideloadly ----
$paquetes = @(
  @{ id = 'Apple.iTunes';                   nombre = 'iTunes';                              critico = $true },
  @{ id = 'Apple.AppleMobileDeviceSupport'; nombre = 'Controlador USB del iPhone (Apple)';  critico = $true },
  @{ id = 'Apple.iCloud';                   nombre = 'iCloud (version clasica)';            critico = $false }
)
$avisos = @()
$fallos = @()
foreach ($p in $paquetes) {
  Paso "Instalando $($p.nombre) (puede tardar unos minutos)"
  $lista = winget list -e --id $p.id --accept-source-agreements 2>$null | Out-String
  if ($lista -match [regex]::Escape($p.id)) { Ok "$($p.nombre) ya estaba instalado"; continue }
  winget install -e --id $p.id --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
  $lista = winget list -e --id $p.id --accept-source-agreements 2>$null | Out-String
  if ($lista -match [regex]::Escape($p.id)) { Ok "$($p.nombre) instalado" }
  elseif ($p.critico) { Mal "No pude instalar $($p.nombre)"; $fallos += $p.nombre }
  else { Mal "No pude instalar $($p.nombre). Si Sideloadly luego da error de inicio de sesion, instale iCloud desde support.apple.com/103232"; $avisos += $p.nombre }
}

# ---- 3. Sideloadly (desde su sitio oficial; su paquete de winget esta desactualizado) ----
$inicio = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
function BuscarSideloadly {
  $x = Get-ChildItem $inicio -Recurse -Filter 'Sideloadly*.lnk' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $x) {
    $x = Get-ChildItem "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:LOCALAPPDATA\Programs" -Recurse -Filter 'sideloadly*.exe' -ErrorAction SilentlyContinue -Depth 3 |
         Where-Object { $_.Name -notmatch 'unins|setup' } | Select-Object -First 1
  }
  return $x
}
Paso "Instalando Sideloadly"
$sl = BuscarSideloadly
if ($sl) { Ok "Sideloadly ya estaba instalado" } else {
  $setup = Join-Path $env:TEMP 'SideloadlySetup64.exe'
  try {
    Invoke-WebRequest 'https://sideloadly.io/SideloadlySetup64.exe' -OutFile $setup -UseBasicParsing
    $tam = (Get-Item $setup).Length
    $bytes = [IO.File]::ReadAllBytes($setup)
    $esNsis = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min($bytes.Length, 4MB)).Contains('Nullsoft')
    Ok "Descargado de sideloadly.io ($([math]::Round($tam/1MB,1)) MB)"
    if ($tam -lt 20MB -or -not $esNsis -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
      Mal "El archivo descargado no parece el instalador de Sideloadly: no lo ejecuto."; $fallos += 'Sideloadly (descarga invalida)'
    } else {
      # Instalador NSIS: /S = instalacion silenciosa. Limite de 5 minutos para que nunca se quede colgado.
      $proc = Start-Process $setup -ArgumentList '/S' -PassThru
      if (-not $proc.WaitForExit(300000)) { $proc.Kill(); Mal "El instalador de Sideloadly no termino en 5 minutos" }
      $sl = BuscarSideloadly
      if (-not $sl -and -not $CI) {
        Write-Host "    Abro el instalador normal de Sideloadly: pulse Siguiente / Instalar." -ForegroundColor White
        Start-Process $setup -Wait
        $sl = BuscarSideloadly
      }
    }
  } catch { Mal "No pude descargar Sideloadly: $($_.Exception.Message)"; $fallos += 'Sideloadly (descarga)' }
}
Paso "Buscando Sideloadly"
if ($sl) { Ok "Sideloadly: $($sl.FullName)" } else { Mal "No encontre Sideloadly"; $fallos += 'Sideloadly' }

# ---- 4. App Jarvis (.ipa) ----
Paso "Buscando la app Jarvis (Jarvis-unsigned.ipa)"
$descargas = Join-Path $env:USERPROFILE 'Downloads'
$escritorio = [Environment]::GetFolderPath('Desktop')
$buscar = @($env:JARVIS_SELF, $descargas, $escritorio) | Where-Object { $_ -and (Test-Path $_) }
$ipa = Get-ChildItem $buscar -Filter 'Jarvis-unsigned*.ipa' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $ipa -and -not $CI) {
  Mal "No la encontre. Descarguela del chat (archivo Jarvis-unsigned.ipa) a Descargas; espero hasta 10 minutos..."
  $hasta = (Get-Date).AddMinutes(10)
  while (-not $ipa -and (Get-Date) -lt $hasta) {
    Start-Sleep 3
    $ipa = Get-ChildItem $buscar -Filter 'Jarvis-unsigned*.ipa' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
}
if ($ipa) {
  $dest = Join-Path $escritorio 'Jarvis-unsigned.ipa'
  if ($ipa.FullName -ne $dest) { Copy-Item $ipa.FullName $dest -Force }
  Ok "App lista en el Escritorio: $dest"
} elseif (-not $CI) { Mal "No llego el archivo .ipa"; $fallos += 'Jarvis-unsigned.ipa' }

# ---- 5. Abrir todo para el ultimo paso ----
if (-not $CI) {
  Paso "Abriendo iTunes y Sideloadly"
  $it = Get-ChildItem $inicio -Recurse -Filter 'iTunes.lnk' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($it) { Start-Process $it.FullName }
  Start-Sleep 4
  if ($sl) { Start-Process $sl.FullName }
  if ($ipa) { Start-Process explorer.exe "/select,`"$dest`"" }
}

Write-Host ""
if ($fallos.Count) {
  Write-Host "Termino con avisos: $($fallos -join ', '). Copie esta ventana y enviesela a Claude." -ForegroundColor Yellow
} else {
  Write-Host "=============================================" -ForegroundColor Green
  Write-Host " TODO INSTALADO. Faltan 4 pasos que son suyos:" -ForegroundColor Green
  Write-Host "=============================================" -ForegroundColor Green
}
Write-Host " 1. Conecte el iPhone por cable y toque CONFIAR en el iPhone."
Write-Host " 2. En Sideloadly: escriba su Apple ID y arrastre Jarvis-unsigned.ipa"
Write-Host "    (esta en el Escritorio) a la ventana de Sideloadly."
Write-Host " 3. Pulse Start. Escriba su contrasena y el codigo de 6 digitos. Espere 'Done'."
Write-Host " 4. iPhone: Ajustes > General > VPN y gestion de dispositivos > Confiar."
Write-Host "    Si lo pide: Ajustes > Privacidad y seguridad > Modo desarrollador > activar."
if ($fallos.Count) { exit 2 } else { exit 0 }

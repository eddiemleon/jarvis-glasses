#requires -Version 5.1
<#
  Jarvis para Ray-Ban Meta - instalador automatico para Windows.
  Instala iTunes y iCloud (versiones web de Apple, no las de Microsoft Store) y Sideloadly,
  deja Jarvis.ipa en el Escritorio y abre Sideloadly listo para instalar la app en el iPhone.
  Uso (Windows + R):
    powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\Downloads\Jarvis\instalar.ps1"
#>
param([switch]$CI)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- 1. Permiso de administrador (una sola ventana: pulse "Si") ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$Here    = Split-Path -Parent $PSCommandPath
$Work    = Join-Path $env:TEMP 'JarvisInstalador'
$Desktop = [Environment]::GetFolderPath('Desktop')
$Log     = Join-Path $Here 'instalacion.log'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
Start-Transcript -Path $Log -Force | Out-Null

function Paso($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Aviso($t){ Write-Host "    !!  $t" -ForegroundColor Yellow }

# Programa instalado? (busca en las listas de desinstalacion de Windows, 64 y 32 bits, maquina y usuario)
function Instalado([string]$nombre) {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($k in $keys) {
        $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $nombre }
        if ($hit) { return $true }
    }
    return $false
}

# Version de Microsoft Store de iTunes/iCloud: Sideloadly no funciona con ella.
function StoreApp([string]$patron) { [bool](Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $patron }) }

function Descargar($url, $archivo) {
    $dest = Join-Path $Work $archivo
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing; if ((Get-Item $dest).Length -gt 1MB) { return $dest } }
        catch { Aviso "Descarga fallida (intento $i): $($_.Exception.Message)" }
        Start-Sleep -Seconds 3
    }
    throw "No pude descargar $archivo"
}

# Ruta de sideloadly.exe: lista de desinstalacion de Windows, carpetas habituales y menu Inicio.
function BuscarSideloadly {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($k in $keys) {
        foreach ($e in (Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Sideloadly*' })) {
            foreach ($c in @($e.DisplayIcon, ($(if ($e.InstallLocation) { Join-Path $e.InstallLocation 'sideloadly.exe' })))) {
                if ($c) { $c = ($c -split ',')[0].Trim('"'); if ((Test-Path $c) -and $c -like '*.exe') { return $c } }
            }
        }
    }
    $hit = Get-ChildItem "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:LOCALAPPDATA\Programs", "$env:LOCALAPPDATA" -Filter 'sideloadly*.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    $lnk = Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu", "$env:APPDATA\Microsoft\Windows\Start Menu" -Filter 'Sideloadly*.lnk' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($lnk) { return $lnk.FullName }
    return $null
}

function Winget { [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) }

$fallos = @()

# ---------- 2. iTunes (web de Apple) ----------
Paso 'iTunes'
if (StoreApp '*AppleInc.iTunes*') { Aviso 'Tiene iTunes de Microsoft Store: Sideloadly necesita la version web. Desinstalela desde Configuracion > Aplicaciones y vuelva a ejecutar.'; $fallos += 'iTunes (Store)' }
elseif (Instalado 'iTunes') { Ok 'Ya estaba instalado' }
else {
    $hecho = $false
    if (Winget) {
        winget install -e --id Apple.iTunes --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        $hecho = Instalado 'iTunes'
    }
    if (-not $hecho) {
        $exe = Descargar 'https://www.apple.com/itunes/download/win64' 'iTunes64Setup.exe'
        Start-Process $exe -ArgumentList '/qn /norestart' -Wait
        $hecho = Instalado 'iTunes'
        if (-not $hecho -and -not $CI) { Aviso 'Instalacion silenciosa no funciono: siga el asistente de iTunes.'; Start-Process $exe -Wait; $hecho = Instalado 'iTunes' }
    }
    if ($hecho) { Ok 'Instalado' } else { $fallos += 'iTunes' }
}

# ---------- 3. iCloud (web de Apple) ----------
Paso 'iCloud'
if (StoreApp '*AppleInc.iCloud*') { Aviso 'Tiene iCloud de Microsoft Store: desinstalelo desde Configuracion > Aplicaciones y vuelva a ejecutar.'; $fallos += 'iCloud (Store)' }
elseif (Instalado 'iCloud*') { Ok 'Ya estaba instalado' }
else {
    $exe = Descargar 'https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe' 'iCloudSetup.exe'
    Start-Process $exe -ArgumentList '/qn /norestart' -Wait
    $hecho = Instalado 'iCloud*'
    if (-not $hecho -and -not $CI) { Aviso 'Instalacion silenciosa no funciono: siga el asistente de iCloud.'; Start-Process $exe -Wait; $hecho = Instalado 'iCloud*' }
    if ($hecho) { Ok 'Instalado' } else { $fallos += 'iCloud' }
}

# ---------- 4. Sideloadly ----------
Paso 'Sideloadly'
if (Instalado 'Sideloadly*') { Ok 'Ya estaba instalado' }
else {
    if (Winget) { winget install -e --id iOSGods.Sideloadly --silent --accept-package-agreements --accept-source-agreements --disable-interactivity }
    if (Instalado 'Sideloadly*') { Ok 'Instalado' }
    else { $fallos += 'Sideloadly'; if (-not $CI) { Aviso 'Descarguelo de sideloadly.io (se abre ahora).'; Start-Process 'https://sideloadly.io' } }
}

# ---------- 5. La app Jarvis en el Escritorio ----------
Paso 'App Jarvis'
$ipa = Join-Path $Here 'Jarvis.ipa'
if (Test-Path $ipa) { Copy-Item $ipa (Join-Path $Desktop 'Jarvis.ipa') -Force; Ok 'Jarvis.ipa copiada al Escritorio' }
else { Aviso "No encontre Jarvis.ipa junto a este instalador ($Here)"; $fallos += 'Jarvis.ipa' }

Stop-Transcript | Out-Null

if ($CI) {
    Write-Host "Sideloadly en: $(BuscarSideloadly)"
    if ($fallos.Count) { Write-Host "FALTA: $($fallos -join ', ')"; exit 1 }
    Write-Host 'TODO INSTALADO'; exit 0
}

# ---------- 6. Abrir Sideloadly y explicar lo que falta ----------
$sl = BuscarSideloadly
if ($sl) { Start-Process $sl }

Add-Type -AssemblyName PresentationFramework
if ($fallos.Count) {
    [System.Windows.MessageBox]::Show("Falto instalar: $($fallos -join ', ').`n`nRegistro: $Log", 'Jarvis - instalador', 'OK', 'Warning') | Out-Null
} else {
    $msg = @"
Todo instalado. Jarvis.ipa esta en su Escritorio.

Falta solo lo que usa su contrasena (2 minutos):

1. Conecte el iPhone por cable y en el iPhone toque "Confiar".
2. En Sideloadly: escriba su Apple ID, arrastre Jarvis.ipa del Escritorio y pulse Start.
   Escriba su contrasena y el codigo de 6 digitos cuando lo pida.
3. En el iPhone: Ajustes > General > VPN y gestion de dispositivos > Confiar.
   Si lo pide: Ajustes > Privacidad y seguridad > Modo desarrollador.
"@
    [System.Windows.MessageBox]::Show($msg, 'Jarvis - listo', 'OK', 'Information') | Out-Null
}

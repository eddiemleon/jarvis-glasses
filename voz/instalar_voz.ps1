#requires -Version 5.1
<#
  Voz propia de Jarvis - instalador para Windows (no necesita permisos de administrador).
  Instala en %LOCALAPPDATA%\JarvisVoz: Python 3.11 (uv), PyTorch (GPU NVIDIA si hay), XTTS-v2, tunel Cloudflare.
  Deja la voz arrancando sola al iniciar Windows y conectada al servidor de Jarvis.
  Uso (Windows + R):
    powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\Downloads\Jarvis\voz\instalar_voz.ps1"
#>
param([switch]$CI)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Origen = Split-Path -Parent $PSCommandPath
$Dest   = Join-Path $env:LOCALAPPDATA 'JarvisVoz'
$Log    = Join-Path $Origen 'instalacion_voz.log'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Start-Transcript -Path $Log -Force | Out-Null

function Paso($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Falla($t){ Write-Host "    ERROR  $t" -ForegroundColor Red; Stop-Transcript | Out-Null; if (-not $CI) { Read-Host 'Pulse Enter para cerrar' }; exit 1 }

# Ejecuta un programa externo: sus avisos (stderr) no detienen el instalador; solo cuenta su codigo de salida.
function Ejecutar([string]$exe, [string[]]$argumentos) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $exe @argumentos 2>&1 | ForEach-Object { Write-Host "    $_" } } finally { $ErrorActionPreference = $prev }
    return $LASTEXITCODE
}

function Bajar($url, $destino) {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -Uri $url -OutFile $destino -UseBasicParsing; return } catch { Write-Host "    reintento $i : $($_.Exception.Message)"; Start-Sleep 3 }
    }
    Falla "No pude descargar $url"
}

# ---------- 0. Licencia del modelo de voz ----------
Paso 'Licencia'
Write-Host '    El modelo de voz XTTS-v2 (Coqui) se usa bajo la licencia CPML: SOLO uso personal, no comercial.'
if (-not $CI) {
    $r = Read-Host '    Escriba S y pulse Enter para aceptar y continuar'
    if ($r -notmatch '^[sS]') { Falla 'Instalacion cancelada (licencia no aceptada).' }
}
Ok 'Aceptada'

# ---------- 1. Tarjeta grafica ----------
Paso 'Tarjeta grafica'
$gpu = $false
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $n = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null; if ($LASTEXITCODE -eq 0 -and $n) { $gpu = $true; Ok "NVIDIA: $n" } } catch {}
$ErrorActionPreference = $prev
if (-not $gpu) { Write-Host '    !!  Sin GPU NVIDIA: la voz funcionara, pero cada frase tardara varios segundos.' -ForegroundColor Yellow }

# ---------- 2. Python 3.11 con uv ----------
Paso 'Python'
$uv = Join-Path $Dest 'uv.exe'
if (-not (Test-Path $uv)) {
    $zip = Join-Path $env:TEMP 'uv.zip'
    Bajar 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip' $zip
    Expand-Archive $zip -DestinationPath (Join-Path $env:TEMP 'uvx') -Force
    Copy-Item (Get-ChildItem (Join-Path $env:TEMP 'uvx') -Filter uv.exe -Recurse | Select-Object -First 1).FullName $uv -Force
}
$venv = Join-Path $Dest 'venv'
$py = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $py)) { if (Ejecutar $uv @('venv', '--python', '3.11', $venv)) { Falla 'No pude crear el entorno de Python' } }
Ok 'Python 3.11 listo'

# ---------- 3. Motor de voz ----------
Paso 'Motor de voz (descarga grande la primera vez, puede tardar 10-20 min)'
$idx = if ($gpu) { 'https://download.pytorch.org/whl/cu124' } else { 'https://download.pytorch.org/whl/cpu' }
if (Ejecutar $uv @('pip', 'install', '--python', $py, 'torch==2.6.0', 'torchaudio==2.6.0', '--index-url', $idx)) { Falla 'No pude instalar PyTorch' }
if (Ejecutar $uv @('pip', 'install', '--python', $py, 'coqui-tts', 'six')) { Falla 'No pude instalar el motor de voz' }
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$cuda = & $py -c "import torch;print(torch.cuda.is_available())" 2>$null
$ErrorActionPreference = $prev
Ok "Motor instalado (GPU activa: $cuda)"

# ---------- 4. Archivos de la voz y conexion ----------
Paso 'Voz de Jarvis'
foreach ($f in 'voz_jarvis.py', 'referencia.wav') {
    if (-not (Test-Path (Join-Path $Origen $f))) { Falla "Falta $f junto al instalador" }
    Copy-Item (Join-Path $Origen $f) $Dest -Force
}
if (Test-Path (Join-Path $Origen 'config.txt')) { Copy-Item (Join-Path $Origen 'config.txt') $Dest -Force }
if (-not (Test-Path (Join-Path $Dest 'config.txt'))) { Falla 'Falta config.txt (direccion y contrasena de Jarvis)' }
$cf = Join-Path $Dest 'cloudflared.exe'
if (-not (Test-Path $cf)) { Bajar 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' $cf }
Ok 'Archivos y tunel seguro listos'

# ---------- 5. Primera prueba (descarga el modelo ~1.8 GB) ----------
Paso 'Prueba de voz'
$env:COQUI_TOS_AGREED = '1'
# El descargador nuevo de Hugging Face (xet) puede quedarse congelado en un bloque: se usa el clásico, que reanuda.
$env:HF_HUB_DISABLE_XET = '1'
$env:HF_HUB_DISABLE_SYMLINKS_WARNING = '1'
$env:HF_HUB_DOWNLOAD_TIMEOUT = '60'
$prueba = Join-Path $Dest 'prueba.wav'
$code = Ejecutar $py @((Join-Path $Dest 'voz_jarvis.py'), '--muestra', $prueba, 'Instalacion completa. Todos los sistemas en linea, senor Leon.')
if ($code -or -not (Test-Path $prueba)) { Falla 'La voz no pudo generar la prueba' }
Ok 'Voz generada'
if (-not $CI) { try { (New-Object Media.SoundPlayer $prueba).PlaySync() } catch {} }

if ($CI) { Stop-Transcript | Out-Null; Write-Host 'CI OK'; exit 0 }

# ---------- 6. Arranque automatico con Windows (oculto) ----------
Paso 'Arranque automatico'
$vbs = Join-Path $Dest 'iniciar_voz.vbs'
@"
Set sh = CreateObject("WScript.Shell")
sh.Environment("Process")("COQUI_TOS_AGREED") = "1"
sh.Environment("Process")("HF_HUB_DISABLE_XET") = "1"
sh.Environment("Process")("HF_HUB_DISABLE_SYMLINKS_WARNING") = "1"
sh.CurrentDirectory = "$Dest"
sh.Run "cmd /c """"$py"" ""$Dest\voz_jarvis.py"" --servidor >> ""$Dest\voz.log"" 2>&1""", 0, False
"@ | Set-Content -Path $vbs -Encoding ASCII
$startup = [Environment]::GetFolderPath('Startup')
Copy-Item $vbs (Join-Path $startup 'Jarvis Voz.vbs') -Force
# Detener una copia anterior y arrancar ya
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='cloudflared.exe'" | Where-Object { $_.CommandLine -match 'voz_jarvis|JarvisVoz' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Process wscript.exe -ArgumentList "`"$vbs`""
Ok 'La voz arranca sola con Windows y ya esta corriendo'

# ---------- 7. Verificar conexion con Jarvis ----------
Paso 'Conexion con Jarvis'
$ok = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep 6
    if (Test-Path (Join-Path $Dest 'voz.log')) {
        $t = Get-Content (Join-Path $Dest 'voz.log') -Raw -ErrorAction SilentlyContinue
        if ($t -match 'registrada en Jarvis') { $ok = $true; break }
    }
}
Stop-Transcript | Out-Null
Add-Type -AssemblyName PresentationFramework
if ($ok) {
    [System.Windows.MessageBox]::Show("Voz de Jarvis instalada y conectada.`n`nAbra Jarvis en el iPhone y diga 'Jarvis, que hora es'.`nArranca sola cada vez que encienda la PC.", 'Jarvis - voz lista', 'OK', 'Information') | Out-Null
} else {
    [System.Windows.MessageBox]::Show("La voz esta instalada pero aun no confirma conexion con Jarvis.`nRegistro: $Dest\voz.log", 'Jarvis - voz', 'OK', 'Warning') | Out-Null
}

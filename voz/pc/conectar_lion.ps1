# Conecta Jarvis con Lion Capital (una sola vez). Lee la direccion y la clave de la sala en esta PC y se las pasa
# al servidor de Jarvis por conexion cifrada. Claude no ve la clave.
$ErrorActionPreference = 'Stop'
try {
  $cfg = @{}; Get-Content "$env:LOCALAPPDATA\JarvisVoz\config.txt" | ForEach-Object { $k,$v = $_ -split '=',2; if ($v) { $cfg[$k.Trim()] = $v.Trim() } }
  $lc = Join-Path $env:USERPROFILE 'Documents\LionCapitalWeb'
  $clave = (Get-Content (Join-Path $lc 'config.json') -Raw | ConvertFrom-Json).clave
  $url = (Get-Content (Join-Path $lc 'tailscale_estado.json') -Raw | ConvertFrom-Json).url
  if (-not $url) { throw 'No encontre la direccion fija de Lion Capital (Tailscale).' }
  $body = @{ url = $url; key = $clave } | ConvertTo-Json -Compress
  $r = Invoke-RestMethod -Method Post -Uri ($cfg.JARVIS_URL.TrimEnd('/') + '/lion/register') -Headers @{ Authorization = "Bearer $($cfg.JARVIS_TOKEN)" } -ContentType 'application/json' -Body $body -TimeoutSec 90
  $msg = "Listo: Jarvis ya esta conectado a Lion Capital ($url).`n`nPregunte: 'Jarvis, como va Lion Capital'."
  "OK $url" | Set-Content "$env:LOCALAPPDATA\JarvisVoz\conectar_lion.log"
} catch { $msg = "No se pudo conectar: $($_.Exception.Message)"; $msg | Set-Content "$env:LOCALAPPDATA\JarvisVoz\conectar_lion.log" }
Add-Type -AssemblyName PresentationFramework
[System.Windows.MessageBox]::Show($msg, 'Jarvis - Lion Capital') | Out-Null

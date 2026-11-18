# Ayudante de Claude para entrenar la voz de Jarvis en esta PC (v2).
# Ejecuta SOLO los scripts que Claude deja en la carpeta "cola" de JarvisVoz y guarda su resultado.
# v2: cada tarea corre aparte; el ayudante sigue vivo, informa cada 5 s y puede detener una tarea
# trabada si Claude deja el archivo "detener.txt". Para apagarlo: cierre esta ventana.
$Host.UI.RawUI.WindowTitle = 'Jarvis - ayudante de Claude (cierre esta ventana para detenerlo)'
$base = Split-Path -Parent $PSCommandPath
$cola = Join-Path $base 'cola'
New-Item -ItemType Directory -Force -Path $cola | Out-Null
Write-Host 'Ayudante de Claude activo (v2). Cierre la ventana para detenerlo.' -ForegroundColor Cyan
$actual = $null
function ArbolMatar($ppid) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$ppid" | ForEach-Object { ArbolMatar $_.ProcessId }
    Stop-Process -Id $ppid -Force -ErrorAction SilentlyContinue
}
while ($true) {
    $estado = 'libre'
    if ($actual) {
        if ($actual.Proc.HasExited) {
            "FIN codigo=$($actual.Proc.ExitCode) $(Get-Date -Format s)" | Add-Content $actual.Log -Encoding UTF8
            Write-Host "$(Get-Date -Format HH:mm:ss) terminó: $($actual.Nombre)"
            $actual = $null
        } elseif (Test-Path (Join-Path $cola 'detener.txt')) {
            ArbolMatar $actual.Proc.Id
            "FIN detenida por Claude $(Get-Date -Format s)" | Add-Content $actual.Log -Encoding UTF8
            Remove-Item (Join-Path $cola 'detener.txt') -Force
            Write-Host "$(Get-Date -Format HH:mm:ss) detenida: $($actual.Nombre)" -ForegroundColor Yellow
            $actual = $null
        } else { $estado = "ocupado: $($actual.Nombre)" }
    }
    if (-not $actual) {
        $t = Get-ChildItem $cola -Filter '*.tarea.ps1' | Sort-Object Name | Select-Object -First 1
        if ($t) {
            $log = $t.FullName -replace '\.tarea\.ps1$', '.log'
            $hecho = $t.FullName -replace '\.tarea\.ps1$', '.hecho.ps1'
            Move-Item $t.FullName $hecho -Force
            "INICIO $(Get-Date -Format s)" | Set-Content $log -Encoding UTF8
            $p = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "& '$hecho' *>&1 | ForEach-Object { `"`$_`" } | Add-Content -Encoding UTF8 '$log'") -WindowStyle Hidden -PassThru
            $actual = @{ Proc = $p; Log = $log; Nombre = $t.Name }
            Write-Host "$(Get-Date -Format HH:mm:ss) tarea: $($t.Name)"
            $estado = "ocupado: $($t.Name)"
        }
    }
    Set-Content (Join-Path $cola 'vivo.txt') "$(Get-Date -Format s) $estado"
    Start-Sleep -Seconds 5
}

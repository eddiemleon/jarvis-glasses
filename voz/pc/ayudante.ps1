# Ayudante de Claude para entrenar la voz de Jarvis en esta PC.
# Ejecuta SOLO los scripts que Claude deja en la carpeta "cola" de JarvisVoz y guarda su resultado.
# Para detenerlo: cierre esta ventana.
$Host.UI.RawUI.WindowTitle = 'Jarvis - ayudante de Claude (cierre esta ventana para detenerlo)'
$base = Split-Path -Parent $PSCommandPath
$cola = Join-Path $base 'cola'
New-Item -ItemType Directory -Force -Path $cola | Out-Null
Write-Host 'Ayudante de Claude activo. Ejecuta las tareas de la carpeta cola. Cierre la ventana para detenerlo.' -ForegroundColor Cyan
Set-Content (Join-Path $cola 'vivo.txt') (Get-Date -Format s)
while ($true) {
    Get-ChildItem $cola -Filter '*.tarea.ps1' | Sort-Object Name | ForEach-Object {
        $t = $_.FullName
        $log = $t -replace '\.tarea\.ps1$', '.log'
        $hecho = $t -replace '\.tarea\.ps1$', '.hecho.ps1'
        Move-Item $t $hecho -Force
        Write-Host "$(Get-Date -Format HH:mm:ss) tarea: $($_.Name)"
        "INICIO $(Get-Date -Format s)" | Set-Content $log -Encoding UTF8
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $hecho *>&1 | ForEach-Object { "$_" } | Add-Content $log -Encoding UTF8
            "FIN codigo=$LASTEXITCODE $(Get-Date -Format s)" | Add-Content $log -Encoding UTF8
        } catch { "FIN error=$($_.Exception.Message)" | Add-Content $log -Encoding UTF8 }
    }
    Set-Content (Join-Path $cola 'vivo.txt') (Get-Date -Format s)
    Start-Sleep -Seconds 3
}

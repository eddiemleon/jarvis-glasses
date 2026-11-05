#requires -Version 5.1
<#
  1) Apaga la voz de Jarvis en la PC (ahora la voz vivirá dentro del iPhone) y quita su arranque con Windows.
  2) Durante 90 segundos anota qué programa abre las ventanas negras de "Símbolo del sistema".
  Resultado: %USERPROFILE%\Downloads\Jarvis\diagnostico.txt
  Uso (Windows + R):
    powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\Downloads\Jarvis\diagnostico_ventanas.ps1"
#>
$ErrorActionPreference = 'Continue'
$out = Join-Path $env:USERPROFILE 'Downloads\Jarvis\diagnostico.txt'
"Diagnostico $(Get-Date -Format s)" | Set-Content $out -Encoding UTF8
function Anota($t) { $t | Add-Content $out -Encoding UTF8; Write-Host $t }

# ---- 1. Voz de Jarvis en la PC: apagar y quitar del inicio ----
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Jarvis Voz.vbs'
if (Test-Path $startup) { Remove-Item $startup -Force; Anota 'Quitado del inicio: Jarvis Voz.vbs' }
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'voz_jarvis|JarvisVoz' } | ForEach-Object {
    Anota "Detenido: $($_.Name) (pid $($_.ProcessId))"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# ---- 2. Tareas programadas que abren consola ----
Anota "`n== Tareas programadas con cmd/bat/powershell/python (no de Microsoft) =="
Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' } | ForEach-Object {
    $t = $_
    foreach ($a in $t.Actions) {
        if ("$($a.Execute) $($a.Arguments)" -match 'cmd|\.bat|\.cmd|powershell|python|\.py|wscript|node') {
            $info = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            $rep = ($t.Triggers | ForEach-Object { $_.Repetition.Interval }) -join ','
            Anota ("TAREA {0}{1} | cada={2} | ultima={3} | {4} {5}" -f $t.TaskPath, $t.TaskName, $rep, $info.LastRunTime, $a.Execute, $a.Arguments)
        }
    }
}

# ---- 3. Vigilar 90 s qué abre consolas ----
Anota "`n== Consolas abiertas durante 90 s (quien las abre) =="
$vistos = @{}
$fin = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $fin) {
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe' OR Name='conhost.exe' OR Name='powershell.exe' OR Name='python.exe' OR Name='pythonw.exe' OR Name='node.exe'" | ForEach-Object {
        if (-not $vistos.ContainsKey($_.ProcessId) -and $_.ProcessId -ne $PID) {
            $vistos[$_.ProcessId] = 1
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)" -ErrorAction SilentlyContinue
            Anota ("{0} {1} pid={2} | padre={3} ({4}) | {5}" -f (Get-Date -Format HH:mm:ss), $_.Name, $_.ProcessId, $p.Name, $p.CommandLine, $_.CommandLine)
        }
    }
    Start-Sleep -Milliseconds 300
}
Anota "`nFin."
Add-Type -AssemblyName PresentationFramework
[System.Windows.MessageBox]::Show("Listo. Ya puede escribirle a Claude: 'diagnostico listo'.", 'Jarvis', 'OK', 'Information') | Out-Null

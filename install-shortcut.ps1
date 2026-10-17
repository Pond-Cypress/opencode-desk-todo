# Creates a desktop shortcut that launches the HUD.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$target = Join-Path $scriptDir 'todo-hud.ps1'
if (-not (Test-Path $target)) { Write-Host "todo-hud.ps1 not found next to this script."; exit 1 }
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'OpenCode Todo HUD.lnk'
$w = New-Object -ComObject WScript.Shell
$s = $w.CreateShortcut($lnk)
$s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $target + '"'
$s.WorkingDirectory = $scriptDir
$s.IconLocation = "$env:SystemRoot\System32\shell32.dll,167"
$s.Description = 'OpenCode Todo HUD'
$s.WindowStyle = 7
$s.Save()
Write-Host "Created shortcut: $lnk"

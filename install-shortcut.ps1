# Creates a desktop shortcut that launches the HUD.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$starter = Join-Path $scriptDir 'start.cmd'
if (-not (Test-Path $starter)) { Write-Host "start.cmd not found next to this script."; exit 1 }
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'OpenCode Todo HUD.lnk'
$w = New-Object -ComObject WScript.Shell
$s = $w.CreateShortcut($lnk)
# launch through start.cmd so the shortcut picks PowerShell 7 when installed
$s.TargetPath = $starter
$s.Arguments = ''
$s.WorkingDirectory = $scriptDir
$s.IconLocation = "$env:SystemRoot\System32\shell32.dll,167"
$s.Description = 'OpenCode Todo HUD'
$s.WindowStyle = 7
$s.Save()
Write-Host "Created shortcut: $lnk"

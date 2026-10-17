# OpenCode Todo HUD - always-on-top progress window for the OpenCode desktop app.
# Shows the live todo list of the currently ACTIVE session/tab (requires the
# opencode-todolist plugin, which provides the todowrite/todoread tools).
# Reads the local opencode + desktop databases directly: no network, no auth.
# Windows only (WinForms). Source is ASCII-only; todo text is read back as UTF-8.

# single instance
$mutex = New-Object System.Threading.Mutex($false, 'Local\OpenCodeTodoHudMutex')
if (-not $mutex.WaitOne(0)) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class JPTSWin32 {
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern int SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
}
"@

# borderless form that exposes resize hit-zones (edge arrows) while
# keeping a normal client area for drag-to-move.
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;
public class HudForm : Form {
  public int BorderSize = 6;
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x0084) {
      base.WndProc(ref m);
      if (m.Result.ToInt32() == 1) {
        int lp = m.LParam.ToInt32();
        int x = (short)(lp & 0xFFFF);
        int y = (short)((lp >> 16) & 0xFFFF);
        Point p = PointToClient(new Point(x, y));
        bool left = p.X <= BorderSize;
        bool right = p.X >= ClientSize.Width - BorderSize;
        bool top = p.Y <= BorderSize;
        bool bottom = p.Y >= ClientSize.Height - BorderSize;
        if (top && left) m.Result = (IntPtr)13;
        else if (top && right) m.Result = (IntPtr)14;
        else if (bottom && left) m.Result = (IntPtr)16;
        else if (bottom && right) m.Result = (IntPtr)17;
        else if (left) m.Result = (IntPtr)10;
        else if (right) m.Result = (IntPtr)11;
        else if (top) m.Result = (IntPtr)12;
        else if (bottom) m.Result = (IntPtr)15;
      }
    } else {
      base.WndProc(ref m);
    }
  }
}
"@

$ErrorActionPreference = 'SilentlyContinue'

# ---- poller JS (writes a JSON snapshot every second) ----------------------
$js = @'
const fs=require('fs'),os=require('os'),path=require('path');
const {DatabaseSync}=require('node:sqlite');
const DB=path.join(os.homedir(),'.local','share','opencode','opencode.db');
const OUT=path.join(os.tmpdir(),'opencode-todo-hud.json');
const HEX=Buffer.from('aiev.todolist','utf16le').swap16().toString('hex');
const DRAFTS=path.join(process.env.APPDATA||path.join(os.homedir(),'AppData','Roaming'),'ai.opencode.desktop','drafts.sqlite');
let db=null;
function openDb(){ db=new DatabaseSync(DB,{readOnly:true}); }
// The desktop GUI persists its tab state in drafts.sqlite (table "state"):
//   key "tabs.recent" = the currently ACTIVE tab  -> {"key":"sidecar\n/server/..\/session/<ses_id>"}
//   key "tabs.info"   = per-tab {title, directory}
function activeFromTabs(){
  let d=null;
  try{
    d=new DatabaseSync(DRAFTS,{readOnly:true});
    const rows=d.prepare("SELECT value,updated_at FROM state WHERE name LIKE 'opencode.window.%.dat' AND key='tabs.recent'").all();
    let best=null;
    for(const r of rows){ if(!best||(r.updated_at||0)>(best.updated_at||0)) best=r; }
    if(!best) return null;
    const m=/session\/(ses_[0-9a-zA-Z]+)/.exec(String(best.value));
    if(!m) return null;
    let title='';
    try{
      const inf=d.prepare("SELECT value FROM state WHERE name LIKE 'opencode.window.%.dat' AND key='tabs.info'").all();
      for(const r of inf){
        let map;try{map=JSON.parse(r.value);}catch(e){continue;}
        for(const k of Object.keys(map)){ if(k.endsWith(m[1])&&map[k]&&map[k].title){title=map[k].title;break;} }
        if(title)break;
      }
    }catch(e){}
    return {id:m[1],title:title};
  }catch(e){ return null; }
  finally{ try{if(d)d.close();}catch(e){} }
}
function tick(){
  const out={ok:false,error:'',todos:[],sessionID:'',title:'',src:'',updatedAt:0};
  try{
    if(!db)openDb();
    const at=activeFromTabs();
    let sid=null;
    if(at&&at.id){sid=at.id;out.src='tab';}
    else{
      const a=db.prepare('SELECT id FROM session_v2 WHERE time_archived IS NULL ORDER BY time_viewed DESC LIMIT 1').get();
      sid=a&&a.id; out.src='viewed';
    }
    if(!sid){out.error='no session';}
    else{
      out.sessionID=sid;
      const s2=db.prepare('SELECT title,slug FROM session_v2 WHERE id=?').get(sid);
      out.title=(at&&at.title)||(s2&&(s2.title||s2.slug))||sid;
      const row=db.prepare('SELECT value FROM kv WHERE key=?').get('plugin:'+HEX+':todos/'+sid);
      if(row){const v=JSON.parse(row.value);out.ok=true;out.todos=v.todos||[];out.updatedAt=v.updatedAt||0;}
      else out.error='no todo list in this session';
    }
  }catch(e){ out.error=String((e&&e.message)||e); db=null; }
  const j=JSON.stringify(out);
  if(j!==lastJson){ lastJson=j; try{fs.writeFileSync(OUT,j,'utf8');}catch(e){} }
}
let lastJson='';
let pending=null;
function schedule(){ if(pending)return; pending=setTimeout(function(){ pending=null; tick(); },20); }
tick();
setInterval(tick,250);
try{ fs.watch(path.dirname(DRAFTS), function(ev,fn){ if(!fn||String(fn).indexOf('drafts.sqlite')===0) schedule(); }); }catch(e){}
try{ fs.watch(path.dirname(DB), function(ev,fn){ if(!fn||String(fn).indexOf('opencode.db')===0) schedule(); }); }catch(e){}
'@

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$hudDir = Join-Path $env:TEMP 'opencode-todo-hud'
New-Item -ItemType Directory -Force -Path $hudDir | Out-Null
$pollJs = Join-Path $hudDir 'poll.js'
Set-Content -Path $pollJs -Value $js -Encoding ASCII
$jsonPath = Join-Path $env:TEMP 'opencode-todo-hud.json'
$boundsPath = Join-Path $scriptDir '.hud-bounds.txt'
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { $nodeExe = 'node' }
$nodeOk = [bool](Get-Command node -ErrorAction SilentlyContinue)

$pollProc = $null
function Start-Poller {
  $script:pollProc = Start-Process -FilePath $nodeExe -ArgumentList $pollJs -WindowStyle Hidden -PassThru
}

# ---- colours --------------------------------------------------------------
$BG = [System.Drawing.Color]::FromArgb(24, 24, 27)
$FG = [System.Drawing.Color]::FromArgb(228, 228, 231)
$DIM = [System.Drawing.Color]::FromArgb(130, 130, 140)
$OK = [System.Drawing.Color]::FromArgb(110, 231, 150)
$RUN = [System.Drawing.Color]::FromArgb(255, 209, 92)
$PEND = [System.Drawing.Color]::FromArgb(150, 150, 160)

# ---- window ---------------------------------------------------------------
$form = New-Object HudForm
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = $BG
$form.Opacity = 0.95
$form.MinimumSize = New-Object System.Drawing.Size(240, 150)
$sa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.StartPosition = 'Manual'
$form.Size = New-Object System.Drawing.Size(360, 210)
$form.Location = New-Object System.Drawing.Point(($sa.Right - 380), ($sa.Top + 40))

# restore remembered geometry
if (Test-Path $boundsPath) {
  $b = (Get-Content -Raw -Encoding UTF8 $boundsPath) -split ','
  if ($b.Count -eq 4) {
    $bx = [int]$b[0]; $by = [int]$b[1]; $bw = [int]$b[2]; $bh = [int]$b[3]
    if ($bw -ge 240 -and $bh -ge 150 -and $bw -le 4000 -and $bh -le 4000) {
      $form.Size = New-Object System.Drawing.Size($bw, $bh)
      if ($bx -lt $sa.Right -and ($bx + $bw) -gt $sa.Left -and $by -lt $sa.Bottom -and ($by + $bh) -gt $sa.Top) {
        $form.Location = New-Object System.Drawing.Point($bx, $by)
      }
    }
  }
}

$title = New-Object System.Windows.Forms.Label
$title.Text = 'OpenCode Todo'
$title.ForeColor = $DIM
$title.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$title.Location = New-Object System.Drawing.Point(12, 9)
$title.AutoSize = $true
$title.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left

$summary = New-Object System.Windows.Forms.Label
$summary.Text = 'waiting...'
$summary.ForeColor = $FG
$summary.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$summary.Location = New-Object System.Drawing.Point(12, 29)
$summary.AutoSize = $true
$summary.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(12, 53)
$bar.Size = New-Object System.Drawing.Size(336, 8)
$bar.Minimum = 0
$bar.Maximum = 100
$bar.Value = 0
$bar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

$list = New-Object System.Windows.Forms.RichTextBox
$list.Location = New-Object System.Drawing.Point(10, 69)
$list.Size = New-Object System.Drawing.Size(340, 131)
$list.ReadOnly = $true
$list.BorderStyle = 'None'
$list.BackColor = $BG
$list.ForeColor = $FG
$list.Font = New-Object System.Drawing.Font('Consolas', 9)
$list.ScrollBars = 'Vertical'
$list.WordWrap = $false
$list.DetectUrls = $false
$list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom

$form.Controls.AddRange(@($title, $summary, $bar, $list))

# drag by the client area (edges are handled by HudForm hit-test)
$drag = {
  [JPTSWin32]::ReleaseCapture() | Out-Null
  [JPTSWin32]::SendMessage($form.Handle, 0xA1, 0x2, 0) | Out-Null
}
$form.Add_MouseDown($drag)
$summary.Add_MouseDown($drag)
$title.Add_MouseDown($drag)
$list.Add_MouseDown($drag)
$bar.Add_MouseDown($drag)

# right-click menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('Refresh now')
$miReset = $menu.Items.Add('Reset size/position')
$miClose = $menu.Items.Add('Close')
$form.ContextMenuStrip = $menu
$list.ContextMenuStrip = $menu
$summary.ContextMenuStrip = $menu
$title.ContextMenuStrip = $menu
$bar.ContextMenuStrip = $menu

function Update-Hud {
  if (-not $nodeOk) {
    $title.Text = 'OpenCode Todo  |  Node.js not found'
    $summary.Text = 'install Node.js 18+ (nodejs.org)'
    $bar.Value = 0
    $list.Text = ''
    return
  }
  if (-not $pollProc -or $pollProc.HasExited) { Start-Poller }
  if (-not (Test-Path $jsonPath)) { $summary.Text = 'waiting for node...'; return }
  $raw = Get-Content -Raw -Encoding UTF8 $jsonPath
  if (-not $raw) { return }
  if ($raw -eq $script:lastRaw) { return }
  $script:lastRaw = $raw
  $s = $raw | ConvertFrom-Json
  if (-not $s) { return }
  $t = $s.title
  if (-not $t) { $t = $s.error }
  if ($t -and $t.Length -gt 34) { $t = $t.Substring(0, 33) + [char]0x2026 }
  $title.Text = 'OpenCode Todo  |  ' + $t
  if (-not $s.ok) {
    $summary.Text = 'no todo list here'
    $bar.Value = 0
    $list.Text = ''
    return
  }
  $items = @($s.todos)
  $total = $items.Count
  $done = @($items | Where-Object { $_.status -eq 'completed' }).Count
  $pct = if ($total -gt 0) { [int][Math]::Round(100.0 * $done / $total) } else { 0 }
  $summary.Text = ('Todo ' + $done + '/' + $total + '  ' + $pct + '%')
  $bar.Value = $pct
  $list.Clear() | Out-Null
  foreach ($it in $items) {
    $mark = '[ ]'; $col = $PEND
    if ($it.status -eq 'completed') { $mark = '[' + [char]0x2714 + ']'; $col = $OK }
    elseif ($it.status -eq 'in_progress') { $mark = '[>]'; $col = $RUN }
    $line = $mark + ' ' + $it.content + "`n"
    $len0 = $list.TextLength
    $list.AppendText($line)
    $list.Select($len0, $line.Length)
    $list.SelectionColor = $col
  }
  $list.Select(0, 0) | Out-Null
}

$miRefresh.Add_Click({ Update-Hud })
$miReset.Add_Click({
  $form.Size = New-Object System.Drawing.Size(360, 210)
  $form.Location = New-Object System.Drawing.Point(($sa.Right - 380), ($sa.Top + 40))
})
$miClose.Add_Click({ $form.Close() })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({ Update-Hud })

$form.Add_Shown({
  Start-Poller
  Start-Sleep -Milliseconds 400
  Update-Hud
  $timer.Start()
})
$form.Add_FormClosed({
  $timer.Stop()
  if ($pollProc -and -not $pollProc.HasExited) { Stop-Process -Id $pollProc.Id -Force -ErrorAction SilentlyContinue }
  try { Set-Content -Path $boundsPath -Value ($form.Left.ToString() + ',' + $form.Top.ToString() + ',' + $form.Width.ToString() + ',' + $form.Height.ToString()) -Encoding ASCII } catch {}
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)

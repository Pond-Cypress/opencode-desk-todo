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
using System.Text;
using System.Runtime.InteropServices;
public class JPTSWin32 {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern int SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
  [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW", SetLastError=true)] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int n);
}
"@

# borderless form that exposes resize hit-zones (edge arrows) while
# keeping a normal client area for drag-to-move.
$formSrc = @"
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

# Windows PowerShell 5.1 resolves framework assemblies by simple name, while
# PowerShell 7 (.NET) needs real reference paths plus the WinForms dependency
# closure - otherwise the compiler fails with CS0012 on Component / Message.
if ($PSVersionTable.PSEdition -eq 'Core') {
  $fwDir = Split-Path ([System.Windows.Forms.Form].Assembly.Location) -Parent
  $refs = @(
    'System.Windows.Forms.dll','System.Windows.Forms.Primitives.dll',
    'System.Drawing.Common.dll','System.Drawing.Primitives.dll',
    'System.ComponentModel.Primitives.dll','System.ComponentModel.TypeConverter.dll',
    'System.Runtime.dll','System.Collections.dll'
  ) | ForEach-Object { Join-Path $fwDir $_ } | Where-Object { Test-Path $_ }
  try {
    Add-Type -ReferencedAssemblies $refs -TypeDefinition $formSrc -ErrorAction Stop
  } catch {
    # last resort: hand the compiler every assembly that is already loaded
    $all = @([AppDomain]::CurrentDomain.GetAssemblies() |
      Where-Object { -not $_.IsDynamic -and $_.Location } |
      ForEach-Object { $_.Location } | Select-Object -Unique)
    Add-Type -ReferencedAssemblies $all -TypeDefinition $formSrc
  }
} else {
  Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition $formSrc
}

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
// exit if the parent HUD process is gone (avoids orphan pollers)
const PPID=process.ppid;
setInterval(function(){ try{ process.kill(PPID,0); }catch(e){ process.exit(0); } },2000);
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
$form.Text = 'OpenCode Todo HUD'
$form.FormBorderStyle = 'None'
# NOT top-most globally: the window is attached as an OWNED window of the
# OpenCode main window (see Attach-ToOpenCode), so it stays above OpenCode but
# goes behind any other application the user switches to.
$form.TopMost = $false
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
# fixed-width + ellipsis: a long session title is clipped to the window width
# instead of stretching the header row past the frame.
$title.AutoSize = $false
$title.AutoEllipsis = $true
$title.Size = New-Object System.Drawing.Size(336, 15)
$title.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

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
# No scrollbars at all: long lines WRAP and the font size is auto-fitted to the
# window (see Render-List) so every step is always fully visible.
$list.ScrollBars = 'None'
$list.WordWrap = $true
$list.DetectUrls = $false
$list.ShortcutsEnabled = $true
$list.HideSelection = $false
$list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom

$form.Controls.AddRange(@($title, $summary, $bar, $list))

# drag by the header row (title / summary / progress bar).
# The step list is deliberately NOT a drag surface any more: mousedown there
# belongs to text selection so you can select and copy the steps.
$drag = {
  [JPTSWin32]::ReleaseCapture() | Out-Null
  [JPTSWin32]::SendMessage($form.Handle, 0xA1, 0x2, 0) | Out-Null
}
$form.Add_MouseDown($drag)
$summary.Add_MouseDown($drag)
$title.Add_MouseDown($drag)
$bar.Add_MouseDown($drag)

# right-click menu (frame)
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('Refresh now')
$miReset = $menu.Items.Add('Reset size/position')
$miClose = $menu.Items.Add('Close')
$form.ContextMenuStrip = $menu
$summary.ContextMenuStrip = $menu
$title.ContextMenuStrip = $menu
$bar.ContextMenuStrip = $menu

# right-click menu (step list): copy actions first, then the frame actions.
# The list needs its OWN strip - a ToolStripItem can only live in one menu.
$listMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miCopy = $listMenu.Items.Add('Copy selected')
$miCopyAll = $listMenu.Items.Add('Select all')
[void]$listMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miLRefresh = $listMenu.Items.Add('Refresh now')
$miLReset = $listMenu.Items.Add('Reset size/position')
$miLClose = $listMenu.Items.Add('Close')
$list.ContextMenuStrip = $listMenu

# ---- keep the HUD attached to the OpenCode main window --------------------
# An OWNED window always sits above its owner, but goes behind any other
# application the user switches to; it also minimises with the owner.
$script:ownerHwnd = [IntPtr]::Zero

function Find-OpenCodeWindow {
  $script:ocFound = [IntPtr]::Zero
  $cb = [JPTSWin32+EnumProc]{
    param($h, $l)
    if (-not [JPTSWin32]::IsWindowVisible($h)) { return $true }
    if ([JPTSWin32]::GetWindow($h, 4) -ne [IntPtr]::Zero) { return $true }   # GW_OWNER -> must be top-level
    $sb = New-Object System.Text.StringBuilder 256
    [void][JPTSWin32]::GetClassNameW($h, $sb, 256)
    if ($sb.ToString() -ne 'Chrome_WidgetWin_1') { return $true }
    $procId = 0
    [void][JPTSWin32]::GetWindowThreadProcessId($h, [ref]$procId)
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match '^opencode') { $script:ocFound = $h; return $false }
    return $true
  }
  [void][JPTSWin32]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:ocFound
}

function Sync-Owner {
  $oc = Find-OpenCodeWindow
  if ($oc -eq [IntPtr]::Zero) {
    # OpenCode is gone -> the HUD goes with it
    if ($script:ownerHwnd -ne [IntPtr]::Zero) { $form.Close() }
    return
  }
  if ($oc -ne $script:ownerHwnd) {
    [void][JPTSWin32]::SetWindowLongPtr($form.Handle, -8, $oc)                              # GWLP_HWNDPARENT
    [void][JPTSWin32]::SetWindowPos($form.Handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x13)          # HWND_TOP | NOMOVE|NOSIZE|NOACTIVATE
    $script:ownerHwnd = $oc
  }
}

# ---- content rendering: wrap + auto fit -----------------------------------
# The step list never scrolls. Lines wrap to the window width and the whole
# layout is scaled to the frame: a bigger window -> bigger text, more/longer
# steps -> smaller text, so every step is always fully visible.
$script:items = @()
$script:needFit = $true

function Measure-Stack {
  param($font, $aw)
  $total = 0
  $size = New-Object System.Drawing.Size([int]$aw, 20000)
  foreach ($it in $script:items) {
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText(
      $it.line, $font, $size,
      ([System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding))
    $total += $sz.Height
  }
  return $total
}

# header text / progress bar sizes derived from the step font size, so the
# whole card scales together instead of only the list changing.
function Get-HeaderScale {
  param($size)
  return @{
    title = [double][Math]::Min(13.0, [Math]::Max(7.5, $size * 0.55))
    summ  = [double][Math]::Min(17.0, [Math]::Max(9.5, $size * 0.78))
    bar   = [int][Math]::Min(18, [Math]::Max(6, [Math]::Round($size * 0.45)))
    gap   = [int][Math]::Max(5, [Math]::Round($size * 0.35))
  }
}

# where the list box would sit for a given font size (pure arithmetic: no
# control is touched, so it is cheap inside the search loop)
function Predict-ListBox {
  param($size, $cw, $ch)
  $h = Get-HeaderScale $size
  $titleH = [int][Math]::Ceiling($h.title * 1.65)
  $summH = [int][Math]::Ceiling($h.summ * 1.65)
  $top = 9 + $titleH + 3 + $summH + $h.gap + $h.bar + 8
  return @{ top = $top; w = ($cw - 20); h = ($ch - $top - 8) }
}

function Get-FitSize {
  param($cw, $ch)
  $size = 26.0
  while ($size -ge 5.5) {
    $box = Predict-ListBox $size $cw $ch
    if ($box.h -ge 20) {
      $f = New-Object System.Drawing.Font('Consolas', [float]$size, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
      $fits = (Measure-Stack $f ($box.w - 12)) -le (($box.h - 4) * 0.98)
      $f.Dispose()
      if ($fits) { return [double]$size }
    }
    $size = $size - 1.0
  }
  return [double]5.5
}

function Apply-Layout {
  param($size)
  $cw = $form.ClientSize.Width
  $ch = $form.ClientSize.Height
  $h = Get-HeaderScale $size
  $title.Font = New-Object System.Drawing.Font('Consolas', [float]$h.title)
  $summary.Font = New-Object System.Drawing.Font('Consolas', [float]$h.summ, [System.Drawing.FontStyle]::Bold)
  $title.Left = 12; $title.Top = 9
  $title.Width = [Math]::Max(40, $cw - 24)
  $title.Height = $title.Font.Height
  $summary.Left = 12
  $summary.Top = $title.Bottom + 3
  $bar.Left = 12
  $bar.Width = [Math]::Max(40, $cw - 24)
  $bar.Top = $summary.Bottom + $h.gap
  $bar.Height = $h.bar
  $list.Left = 10
  $list.Width = [Math]::Max(40, $cw - 20)
  $list.Top = $bar.Bottom + 8
  $list.Height = [Math]::Max(20, $ch - $list.Top - 8)
}

function Test-ListOverflow {
  $n = $list.TextLength
  if ($n -le 0) { return $false }
  # position of the last character tells the truth about the real wrap, which
  # covers glyph fallback (CJK) that a pure MeasureText estimate can miss.
  $p = $list.GetPositionFromCharIndex($n - 1)
  return (($p.Y + $list.Font.Height) -gt ($list.ClientSize.Height - 1))
}

function Draw-Items {
  param($size)
  $list.Font = New-Object System.Drawing.Font('Consolas', [float]$size)
  $list.Clear() | Out-Null
  $n = $script:items.Count
  for ($i = 0; $i -lt $n; $i++) {
    $it = $script:items[$i]
    $text = $it.line
    if ($i -lt $n - 1) { $text = $text + "`n" }
    $len0 = $list.TextLength
    $list.AppendText($text)
    $list.Select($len0, $text.Length)
    $list.SelectionColor = $it.color
  }
  $list.Select(0, 0) | Out-Null
  # appending text leaves the view scrolled to the end; whenever the list has
  # to scroll, start at the first step instead of mid-list
  $list.ScrollToCaret()
}

function Render-List {
  $cw = $form.ClientSize.Width
  $ch = $form.ClientSize.Height
  if ($cw -lt 80 -or $ch -lt 60) { return }
  if ($script:items.Count -eq 0) {
    Apply-Layout 12.0
    if ($list.ScrollBars -ne [System.Windows.Forms.RichTextBoxScrollBars]::None) { $list.ScrollBars = 'None' }
    $list.Clear() | Out-Null
    return
  }
  $size = Get-FitSize $cw $ch
  # the estimate above is generous; this loop verifies the REAL wrap in the
  # control and steps down until nothing is clipped (belt and braces).
  for ($guard = 0; $guard -lt 10; $guard++) {
    Apply-Layout $size
    Draw-Items $size
    if (-not (Test-ListOverflow)) {
      if ($list.ScrollBars -ne [System.Windows.Forms.RichTextBoxScrollBars]::None) { $list.ScrollBars = 'None' }
      return
    }
    if ($size -le 5.5) {
      # Last resort: the window is too small for this many steps even at the
      # smallest readable size. Never hide steps - show them at a readable
      # size with a scrollbar instead of shrinking to an illegible 5.5 pt.
      Apply-Layout 9.0
      $list.ScrollBars = 'Vertical'
      Draw-Items 9.0
      return
    }
    $size = [Math]::Max(5.5, $size - 1.0)
  }
}

function Update-Hud {
  if (-not $nodeOk) {
    $title.Text = 'OpenCode Todo  |  Node.js not found'
    $summary.Text = 'install Node.js 18+ (nodejs.org)'
    $bar.Value = 0
    $script:items = @()
    $list.Clear() | Out-Null
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
  # no manual truncation any more: the label is width-bound with AutoEllipsis
  $title.Text = 'OpenCode Todo  |  ' + $t
  if (-not $s.ok) {
    $summary.Text = 'no todo list here'
    $bar.Value = 0
    $script:items = @()
    $list.Clear() | Out-Null
    return
  }
  $items = @($s.todos)
  $total = $items.Count
  $done = @($items | Where-Object { $_.status -eq 'completed' }).Count
  $pct = if ($total -gt 0) { [int][Math]::Round(100.0 * $done / $total) } else { 0 }
  $summary.Text = ('Todo ' + $done + '/' + $total + '  ' + $pct + '%')
  $bar.Value = $pct
  $script:items = @()
  foreach ($it in $items) {
    $mark = '[ ]'; $col = $PEND
    if ($it.status -eq 'completed') { $mark = '[' + [char]0x2714 + ']'; $col = $OK }
    elseif ($it.status -eq 'in_progress') { $mark = '[>]'; $col = $RUN }
    $script:items += [pscustomobject]@{ line = ($mark + ' ' + $it.content); color = $col }
  }
  $script:needFit = $true
  Render-List
}

$doRefresh = { $script:lastRaw = ''; $script:needFit = $true; Update-Hud }
$doReset = {
  $form.Size = New-Object System.Drawing.Size(360, 210)
  $form.Location = New-Object System.Drawing.Point(($sa.Right - 380), ($sa.Top + 40))
  $script:needFit = $true
}
$doClose = { $form.Close() }

$miRefresh.Add_Click($doRefresh)
$miReset.Add_Click($doReset)
$miClose.Add_Click($doClose)
$miCopy.Add_Click({ $list.Copy() })
$miCopyAll.Add_Click({ $list.SelectAll(); $list.Copy() })
$miLRefresh.Add_Click($doRefresh)
$miLReset.Add_Click($doReset)
$miLClose.Add_Click($doClose)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
  if ($script:needFit) { $script:needFit = $false; Render-List }
  Update-Hud
})

# any resize (window or list) re-fits the text to the new box
$form.Add_Resize({ $script:needFit = $true })
$list.Add_Resize({ $script:needFit = $true })

$ownerTimer = New-Object System.Windows.Forms.Timer
$ownerTimer.Interval = 1000
$ownerTimer.Add_Tick({ Sync-Owner })

$form.Add_Shown({
  Sync-Owner
  $ownerTimer.Start()
  Start-Poller
  Start-Sleep -Milliseconds 400
  Update-Hud
  $timer.Start()
})
$form.Add_FormClosed({
  $timer.Stop()
  $ownerTimer.Stop()
  if ($pollProc -and -not $pollProc.HasExited) { Stop-Process -Id $pollProc.Id -Force -ErrorAction SilentlyContinue }
  try { Set-Content -Path $boundsPath -Value ($form.Left.ToString() + ',' + $form.Top.ToString() + ',' + $form.Width.ToString() + ',' + $form.Height.ToString()) -Encoding ASCII } catch {}
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)

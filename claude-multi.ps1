<#
  claude-multi.ps1 - run several isolated Claude Desktop instances on Windows.

  Each profile gets its own Electron data directory (--user-data-dir), so it
  has its own login/account, settings, cache and claude_desktop_config.json
  (MCP servers). The regular Claude app keeps its default data directory, so
  it can stay "account 1" while a profile is "account 2" (or use two profiles).

    Profiles:  %USERPROFILE%\Claude-Profiles\<name>
    Launchers: Start menu > Claude Multi > Claude780 (<name>)

  Profiles live outside %APPDATA% on purpose: the Microsoft Store (MSIX) build
  of Claude virtualizes writes under AppData, which would hide profile data.

  Run it without arguments for an interactive menu, or double-click
  claude-multi.cmd. Works in Windows PowerShell 5.1 and PowerShell 7.
  This file is ASCII-only so Windows PowerShell 5.1 reads it correctly.
#>

$ErrorActionPreference = 'Stop'

$Version  = '2.0.0'
$RepoUrl  = 'https://github.com/IbrahimHosseini/multi-claude-app'
$RawUrl   = if ($env:CLAUDE_MULTI_RAW_URL) { $env:CLAUDE_MULTI_RAW_URL } else { 'https://raw.githubusercontent.com/IbrahimHosseini/multi-claude-app/main' }
$UA       = "claude-multi/$Version (+$RepoUrl)"
$AppLabel = if ($env:CLAUDE_APP_LABEL) { $env:CLAUDE_APP_LABEL } else { 'Claude780' }
$ProfilesRoot = if ($env:CLAUDE_PROFILES_ROOT) { $env:CLAUDE_PROFILES_ROOT } else { Join-Path $env:USERPROFILE 'Claude-Profiles' }
$LaunchersDir = if ($env:CLAUDE_LAUNCHERS_DIR) { $env:CLAUDE_LAUNCHERS_DIR } else { Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude Multi' }
$InstallDir   = if ($env:CLAUDE_MULTI_BIN_DIR) { $env:CLAUDE_MULTI_BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\claude-multi' }
$Me   = 'claude-multi'
$Self = $PSCommandPath
$CmdShim = '@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-multi.ps1" %*'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ------------------------------------------------------------------- UI ---

$Fancy = -not $env:NO_COLOR
try { if ([Console]::IsOutputRedirected) { $Fancy = $false } } catch { $Fancy = $false }
$Unicode = [bool]$env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode'

if ($Unicode) {
  $S = @{ Ok = [char]0x2713; Fail = [char]0x2717; Arrow = [char]0x276F; Star = [char]0x273B
          On = [char]0x25CF; Off = [char]0x25CB; Full = [char]0x2588; Empty = [char]0x2591
          Spin = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F | ForEach-Object { [string][char]$_ })
          Keys = 'up/down move, enter select, q back' }
} else {
  # Characters that the classic console font (Consolas, code page 437) can show.
  $S = @{ Ok = [char]0x221A; Fail = 'x'; Arrow = '>'; Star = '*'
          On = '*'; Off = '-'; Full = [char]0x2588; Empty = [char]0x2591
          Spin = @('|', '/', '-', '\')
          Keys = 'up/down move, enter select, q back' }
}
$Accent = 'DarkYellow'

function Get-Width {
  try { $w = [Console]::WindowWidth; if ($w -gt 20) { return $w } } catch { }
  return 80
}
function Fit([string]$Text, [int]$Len) {
  if ($Text.Length -gt $Len) { return $Text.Substring(0, $Len) }
  return $Text.PadRight($Len)
}
function Write-Ok([string]$Msg)   { Write-Host ('  ' + $S.Ok + ' ') -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Warn([string]$Msg) { Write-Host '  ! ' -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Hint([string]$Msg) { Write-Host "  $Msg" -ForegroundColor DarkGray }
function Write-Failure([string]$Msg) {
  Write-Host ($S.Fail + ' Error: ') -ForegroundColor Red -NoNewline
  Write-Host $Msg
}
function Fail([string]$Msg) { throw $Msg }

function Clear-Line {
  if ($Fancy) { Write-Host ("`r" + (' ' * ((Get-Width) - 1)) + "`r") -NoNewline }
}
function Show-Banner {
  Write-Host ''
  Write-Host ('  ' + $S.Star + ' Claude Multi ') -ForegroundColor $Accent -NoNewline
  Write-Host "v$Version - isolated Claude Desktop profiles" -ForegroundColor DarkGray
  Write-Host ''
}
function Wait-AnyKey {
  try { if ([Console]::IsInputRedirected) { return } } catch { return }
  Write-Host ''
  Write-Host '  press any key to continue' -ForegroundColor DarkGray -NoNewline
  $null = [Console]::ReadKey($true)
  Write-Host ''
}
function Write-Bar([int]$Pct, [int]$Width) {
  $Pct = [Math]::Max(0, [Math]::Min(100, $Pct))
  $fill = [int][Math]::Floor($Pct * $Width / 100)
  Write-Host (([string]$S.Full) * $fill) -ForegroundColor $Accent -NoNewline
  Write-Host (([string]$S.Empty) * ($Width - $fill)) -ForegroundColor DarkGray -NoNewline
}
function Format-Size([long]$Bytes) {
  if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
  return "$Bytes B"
}

function Read-Input([string]$Prompt, [string]$Default = '') {
  Write-Host '  ? ' -ForegroundColor $Accent -NoNewline
  Write-Host "$Prompt " -NoNewline
  if ($Default) { Write-Host "($Default) " -ForegroundColor DarkGray -NoNewline }
  $v = [Console]::ReadLine()
  if ([string]::IsNullOrEmpty($v)) { return $Default }
  return $v
}
function Confirm-Choice([string]$Question, [bool]$Default = $false) {
  $keys = if ($Default) { 'Y/n' } else { 'y/N' }
  Write-Host '  ? ' -ForegroundColor $Accent -NoNewline
  Write-Host "$Question " -NoNewline
  Write-Host "[$keys] " -ForegroundColor DarkGray -NoNewline
  $v = [Console]::ReadLine()
  if ([string]::IsNullOrEmpty($v)) { return $Default }
  return $v -match '^[yY]'
}

# Select-Option "Question" options [default]  -> index, or -1 when cancelled.
# Arrow keys (or j/k, or a digit) move, Enter picks.
function Select-Option([string]$Title, [string[]]$Options, [int]$Default = 0) {
  $n = $Options.Count
  $interactive = $Fancy
  try { if ([Console]::IsInputRedirected) { $interactive = $false } } catch { $interactive = $false }
  if (-not $interactive) {
    Write-Host "  $Title"
    for ($i = 0; $i -lt $n; $i++) { Write-Host ('    {0}) {1}' -f ($i + 1), $Options[$i]) }
    $v = Read-Input "Choose 1-$n" ([string]($Default + 1))
    $num = 0
    if ([int]::TryParse($v, [ref]$num) -and $num -ge 1 -and $num -le $n) { return $num - 1 }
    return -1
  }

  $sel = $Default
  $width = Get-Width
  Write-Host '  ? ' -ForegroundColor $Accent -NoNewline
  Write-Host $Title
  $cursorWas = $true
  try { $cursorWas = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { }
  $top = -1
  try {
    :menu while ($true) {
      if ($top -ge 0) { [Console]::SetCursorPosition(0, $top) }
      for ($i = 0; $i -lt $n; $i++) {
        if ($i -eq $sel) {
          Write-Host (Fit ('  ' + $S.Arrow + ' ' + $Options[$i]) ($width - 1)) -ForegroundColor $Accent
        } else {
          Write-Host (Fit ('    ' + $Options[$i]) ($width - 1))
        }
      }
      Write-Host (Fit ('  ' + $S.Keys) ($width - 1)) -ForegroundColor DarkGray -NoNewline
      if ($top -lt 0) { $top = [Console]::CursorTop - $n }
      $k = [Console]::ReadKey($true)
      $ch = [string]$k.KeyChar
      switch ($k.Key) {
        'UpArrow'   { $sel = ($sel - 1 + $n) % $n; continue menu }
        'DownArrow' { $sel = ($sel + 1) % $n; continue menu }
        'Enter'     { break menu }
        'Escape'    { $sel = -1; break menu }
      }
      if ($ch -eq 'k') { $sel = ($sel - 1 + $n) % $n }
      elseif ($ch -eq 'j') { $sel = ($sel + 1) % $n }
      elseif ($ch -eq 'q' -or $ch -eq 'Q') { $sel = -1; break menu }
      elseif ($ch -match '^[1-9]$' -and [int]$ch -le $n) { $sel = [int]$ch - 1 }
    }
    # Collapse the list into a one-line answer.
    [Console]::SetCursorPosition(0, $top - 1)
    for ($i = 0; $i -le $n + 1; $i++) { Write-Host (' ' * ($width - 1)) }
    [Console]::SetCursorPosition(0, $top - 1)
  } finally {
    try { [Console]::CursorVisible = $cursorWas } catch { }
  }
  if ($sel -ge 0) {
    Write-Host ('  ' + $S.Ok + ' ') -ForegroundColor Green -NoNewline
    Write-Host "$Title " -NoNewline
    Write-Host $Options[$sel] -ForegroundColor $Accent
  } else {
    Write-Host "  - $Title (cancelled)" -ForegroundColor DarkGray
  }
  return $sel
}

# --------------------------------------------------------- steps & plans ---
#
# A plan is a titled list of steps with an overall progress bar. A step that
# throws is marked failed and stops the plan. Steps report a short note
# through $script:StepDetail.

$script:StepI = 0
$script:StepN = 0
$script:PlanClock = $null
$script:StepDetail = ''
$StepFailed = '__claude_multi_step_failed__'

function Start-Plan([string]$Title, [int]$Steps) {
  $script:StepI = 0
  $script:StepN = $Steps
  $script:PlanClock = [Diagnostics.Stopwatch]::StartNew()
  Write-Host ''
  Write-Host "  $Title" -ForegroundColor White
  Write-Host ''
}
function Add-PlanSteps([int]$Count) { $script:StepN += $Count }

function Complete-Plan([string]$Message) {
  if ($Fancy) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Bar 100 30
    Write-Host ' 100%' -NoNewline
  }
  Write-Host ''
  Write-Host ('  ' + $S.Ok + " $Message ") -ForegroundColor Green -NoNewline
  Write-Host ('({0}s)' -f [int]$script:PlanClock.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}

function Write-StepLine([string]$Sym, [string]$Text, [int]$Pct, [string]$Extra) {
  if (-not $Fancy) { return }
  $width = Get-Width
  $barW = if ($width -ge 64) { 10 } else { 0 }
  $room = $width - 36
  if ($barW) { $room -= $barW + 5 }
  if ($room -lt 0) { $room = 0 }
  if ($Extra.Length -gt $room) { $Extra = $Extra.Substring(0, $room) }
  Write-Host "`r  " -NoNewline
  Write-Host $Sym -ForegroundColor $Accent -NoNewline
  Write-Host (' ' + (Fit $Text 28) + ' ') -NoNewline
  $used = 33
  if ($barW) {
    Write-Bar $Pct $barW
    Write-Host (' {0,3}%' -f $Pct) -NoNewline
    $used += $barW + 5
  }
  Write-Host ('  ' + $Extra) -ForegroundColor DarkGray -NoNewline
  $used += 2 + $Extra.Length
  $pad = $width - 1 - $used
  if ($pad -gt 0) { Write-Host (' ' * $pad) -NoNewline }
}

function Start-StepState {
  $script:StepI++
  if ($script:StepN -lt $script:StepI) { $script:StepN = $script:StepI }
  $script:StepDetail = ''
}
function Get-PlanPercent { return [int](($script:StepI - 1) * 100 / $script:StepN) }

function Complete-Step([string]$Text, [bool]$Succeeded, [string]$ErrorText) {
  Clear-Line
  if ($Succeeded) {
    Write-Host ('  ' + $S.Ok + ' ') -ForegroundColor Green -NoNewline
    Write-Host $Text -NoNewline
    if ($script:StepDetail) { Write-Host ('  ' + $script:StepDetail) -ForegroundColor DarkGray -NoNewline }
    Write-Host ''
  } else {
    Write-Host ('  ' + $S.Fail + ' ' + $Text) -ForegroundColor Red
    if ($ErrorText) {
      foreach ($line in ($ErrorText -split "`r?`n" | Select-Object -Last 12)) { Write-Host "      $line" -ForegroundColor DarkGray }
    }
    throw $StepFailed
  }
}

function Invoke-Step([string]$StepText, [scriptblock]$StepAction) {
  Start-StepState
  Write-StepLine $S.Spin[0] $StepText (Get-PlanPercent) ('[{0}/{1}]' -f $script:StepI, $script:StepN)
  $stepError = $null
  try { $null = & $StepAction } catch { $stepError = $_.Exception.Message }
  Complete-Step $StepText ($null -eq $stepError) $stepError
}

# Run a Windows PowerShell script in a hidden process while a spinner turns.
function Invoke-ProcessStep([string]$StepText, [string]$Script) {
  Start-StepState
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ErrorActionPreference = 'Stop'; $Script"))
  $errFile = Join-Path $script:WorkDir ("step{0}.err" -f $script:StepI)
  $outFile = Join-Path $script:WorkDir ("step{0}.out" -f $script:StepI)
  $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
         -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
         -RedirectStandardError $errFile -RedirectStandardOutput $outFile
  $null = $p.Handle   # keeps ExitCode available after the process ends
  $f = 0
  while (-not $p.HasExited) {
    Write-StepLine $S.Spin[$f % $S.Spin.Count] $StepText (Get-PlanPercent) ('[{0}/{1}]' -f $script:StepI, $script:StepN)
    $f++
    Start-Sleep -Milliseconds 100
  }
  $p.WaitForExit()
  $errText = ''
  if (Test-Path -LiteralPath $errFile) { $errText = (Get-Content -LiteralPath $errFile -Raw) }
  Complete-Step $StepText ($p.ExitCode -eq 0) $errText
}

function Invoke-DownloadStep([string]$StepText, [string]$Url, [string]$Dest) {
  Start-StepState
  $stepError = $null
  $in = $null; $out = $null; $resp = $null
  try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = $UA
    $req.AllowAutoRedirect = $true
    $req.Timeout = 30000
    $resp = $req.GetResponse()
    $total = [long]$resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Create($Dest)
    $buf = New-Object byte[] 262144
    $got = [long]0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastDraw = [long]-1000
    $f = 0
    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
      $out.Write($buf, 0, $n)
      $got += $n
      if ($clock.ElapsedMilliseconds - $lastDraw -ge 150) {
        $lastDraw = $clock.ElapsedMilliseconds
        $pct = 0
        $extra = Format-Size $got
        if ($total -gt 0) { $pct = [int]($got * 100 / $total); $extra += ' / ' + (Format-Size $total) }
        $secs = $clock.Elapsed.TotalSeconds
        if ($secs -ge 1) { $extra += '  ' + (Format-Size ([long]($got / $secs))) + '/s' }
        Write-StepLine $S.Spin[$f % $S.Spin.Count] $StepText $pct $extra
        $f++
      }
    }
    $script:StepDetail = Format-Size $got
  } catch {
    $stepError = $_.Exception.Message
  } finally {
    if ($out) { $out.Close() }
    if ($in) { $in.Close() }
    if ($resp) { $resp.Close() }
  }
  Complete-Step $StepText ($null -eq $stepError) $stepError
}

# ------------------------------------------------------------ the Claude app ---

function Find-ClaudeApp([switch]$Quiet) {
  if ($env:CLAUDE_APP_PATH) {
    if (Test-Path -LiteralPath $env:CLAUDE_APP_PATH) { return $env:CLAUDE_APP_PATH }
    if ($Quiet) { return $null }
    Fail "CLAUDE_APP_PATH not found: $env:CLAUDE_APP_PATH"
  }
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\claude-desktop.exe'),  # Microsoft Store / MSIX build
    (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe')                 # older installer
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  $cmd = Get-Command 'claude-desktop.exe' -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  if ($Quiet) { return $null }
  Fail "Claude Desktop not found. Install it with '$Me install-claude' or set CLAUDE_APP_PATH."
}

function Get-ClaudePackage {
  try {
    return (Get-AppxPackage -Name 'Claude' -ErrorAction Stop | Where-Object { $_.Publisher -like '*Anthropic*' } | Select-Object -First 1)
  } catch { }
  # PowerShell 7 can lack the Appx module; ask Windows PowerShell instead.
  try {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $json = & powershell.exe -NoProfile -NonInteractive -Command "Get-AppxPackage -Name Claude | Where-Object { `$_.Publisher -like '*Anthropic*' } | Select-Object -First 1 Name, Version, InstallLocation | ConvertTo-Json" 2>$null
    $ErrorActionPreference = $old
    if ($json) { return (($json | Out-String) | ConvertFrom-Json) }
  } catch { }
  return $null
}

function Get-AppVersion([string]$App) {
  if ($App -like '*\WindowsApps\*') {
    $pkg = Get-ClaudePackage
    if ($pkg) { return [string]$pkg.Version }
    return ''
  }
  try { return (Get-Item -LiteralPath $App).VersionInfo.ProductVersion } catch { return '' }
}

function Get-ClaudeIcon([string]$App) {
  $pkg = Get-ClaudePackage
  if ($pkg -and $pkg.InstallLocation) {
    $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
    if (Test-Path -LiteralPath $exe) { return "$exe,0" }
  }
  return "$App,0"
}

# Main Claude processes (Electron helpers carry --type=...).
function Get-ClaudeProcesses {
  Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' }
}

function Get-MainPid([string]$Dir) {
  $needle = "--user-data-dir=$Dir"
  foreach ($p in Get-ClaudeProcesses) {
    $cl = [string]$p.CommandLine
    $i = $cl.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { continue }
    $end = $i + $needle.Length
    if ($end -lt $cl.Length -and $cl[$end] -ne ' ' -and $cl[$end] -ne '"') { continue }  # "work" vs "work2"
    return [int]$p.ProcessId
  }
  return $null
}

function Set-Foreground([int]$ProcessId) {
  try { $null = (New-Object -ComObject WScript.Shell).AppActivate($ProcessId) } catch { }
}

function Stop-ClaudePids([int[]]$Pids) {
  foreach ($id in $Pids) {
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p) { $null = $p.CloseMainWindow() }
  }
  for ($i = 0; $i -lt 10; $i++) {
    if (-not (Get-Process -Id $Pids -ErrorAction SilentlyContinue)) { $script:StepDetail = 'closed'; return }
    Start-Sleep -Milliseconds 500
  }
  # Claude keeps running in the tray when its window closes, so finish the job.
  Stop-Process -Id $Pids -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
  if (Get-Process -Id $Pids -ErrorAction SilentlyContinue) { Fail 'Claude is still running; close it from the tray and retry.' }
  $script:StepDetail = 'force-closed after 5s'
}

# ------------------------------------------------------------- launchers ---

function Test-ProfileName([string]$Name) {
  if (-not $Name) { Fail "a profile name is required (see: $Me help)" }
  if ($Name -notmatch '^[A-Za-z0-9._-]+$') { Fail "invalid name '$Name' (use letters, digits, . _ -)" }
  if ($Name -eq '.' -or $Name -eq '..') { Fail "invalid name '$Name'" }
}
function Get-ProfileDir([string]$Name) { return (Join-Path $ProfilesRoot $Name) }
function Get-LauncherPath([string]$Name) { return (Join-Path $LaunchersDir "$AppLabel ($Name).lnk") }
function Get-ProfileNames {
  if (-not (Test-Path -LiteralPath $ProfilesRoot)) { return @() }
  return @(Get-ChildItem -LiteralPath $ProfilesRoot -Directory | ForEach-Object { $_.Name })
}

function Get-DefaultConfig {
  $dirs = @()
  $pkgRoot = Join-Path $env:LOCALAPPDATA 'Packages'
  if (Test-Path -LiteralPath $pkgRoot) {
    $dirs += @(Get-ChildItem -LiteralPath $pkgRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
               ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude' })
  }
  $dirs += (Join-Path $env:APPDATA 'Claude')
  foreach ($d in $dirs) {
    $cfg = Join-Path $d 'claude_desktop_config.json'
    if (Test-Path -LiteralPath $cfg) { return $cfg }
  }
  return $null
}

function New-Launcher([string]$Name, [string]$App, [string]$Dir) {
  $null = New-Item -ItemType Directory -Force -Path $LaunchersDir
  $lnk = Get-LauncherPath $Name
  $shell = New-Object -ComObject WScript.Shell
  $sc = $shell.CreateShortcut($lnk)
  $sc.TargetPath = $App
  $sc.Arguments = '"--user-data-dir=' + $Dir + '"'
  $sc.WorkingDirectory = $Dir
  $sc.Description = "Claude Desktop with the '$Name' profile (claude-multi)"
  $sc.IconLocation = Get-ClaudeIcon $App
  $sc.Save()
  $script:StepDetail = $lnk
}

function Update-Launchers([string]$App) {
  $count = 0
  foreach ($name in Get-ProfileNames) {
    if (Test-Path -LiteralPath (Get-LauncherPath $name)) {
      New-Launcher $name $App (Get-ProfileDir $name)
      $count++
    }
  }
  $script:StepDetail = "$count launcher(s) updated"
}

# -------------------------------------------------------------- profiles ---

function Invoke-Create([string[]]$Arguments) {
  $name = ''; $copy = $false
  foreach ($a in $Arguments) {
    if ($a -eq '--copy-config') { $copy = $true }
    elseif ($a.StartsWith('-')) { Fail "unknown option '$a'" }
    elseif ($name) { Fail "unexpected argument '$a'" }
    else { $name = $a }
  }
  Test-ProfileName $name
  $dir = Get-ProfileDir $name

  $steps = 3
  if ($copy) { $steps = 4 }
  Start-Plan "Creating profile '$name'" $steps
  Invoke-Step 'Find Claude Desktop' {
    $script:App = Find-ClaudeApp
    $ver = Get-AppVersion $script:App
    $script:StepDetail = $script:App
    if ($ver) { $script:StepDetail += " (v$ver)" }
  }
  Invoke-Step 'Create profile folder' {
    if (Test-Path -LiteralPath $dir) { $script:StepDetail = 'already exists' }
    else { $null = New-Item -ItemType Directory -Force -Path $dir; $script:StepDetail = $dir }
  }
  if ($copy) {
    Invoke-Step 'Copy MCP config' {
      $source = Get-DefaultConfig
      if (Test-Path -LiteralPath (Join-Path $dir 'claude_desktop_config.json')) { $script:StepDetail = 'the profile already has a config; kept it' }
      elseif ($source) { Copy-Item -LiteralPath $source -Destination $dir; $script:StepDetail = 'from the regular Claude app' }
      else { $script:StepDetail = 'the regular Claude app has no config to copy' }
    }
  }
  Invoke-Step 'Build launcher' { New-Launcher $name $script:App $dir }
  Complete-Plan "Profile '$name' is ready"
  Write-Hint "Start it with:  $Me start $name"
  Write-Hint "or open '$AppLabel ($name)' from the Start menu."
}

function Invoke-Start([string]$Name) {
  Test-ProfileName $Name
  $dir = Get-ProfileDir $Name
  if (-not (Test-Path -LiteralPath $dir)) { Fail "profile '$Name' does not exist. Run: $Me create $Name" }
  $running = Get-MainPid $dir
  if ($running) {
    Write-Ok "Profile '$Name' is already running (pid $running); bringing it to front."
    Set-Foreground $running
    return
  }
  Start-Plan "Starting profile '$Name'" 3
  Invoke-Step 'Find Claude Desktop' { $script:App = Find-ClaudeApp; $script:StepDetail = $script:App }
  Invoke-Step 'Launch Claude' { Start-Process -FilePath $script:App -ArgumentList ('"--user-data-dir=' + $dir + '"') }
  Start-StepState
  $found = $null
  for ($i = 0; $i -lt 60 -and -not $found; $i++) {
    Write-StepLine $S.Spin[$i % $S.Spin.Count] 'Wait for it to start' (Get-PlanPercent) ('[{0}/{1}]' -f $script:StepI, $script:StepN)
    $found = Get-MainPid $dir
    if (-not $found) { Start-Sleep -Milliseconds 500 }
  }
  if ($found) { $script:StepDetail = "pid $found" }
  Complete-Step 'Wait for it to start' ([bool]$found) 'Claude did not start within 30 seconds.'
  Complete-Plan "Profile '$Name' is running"
}

function Invoke-Stop([string]$Name) {
  Test-ProfileName $Name
  $running = Get-MainPid (Get-ProfileDir $Name)
  if (-not $running) { Write-Ok "Profile '$Name' is not running."; return }
  Start-Plan "Stopping profile '$Name'" 1
  Invoke-Step "Quit Claude (pid $running)" { Stop-ClaudePids @($running) }
  Complete-Plan "Stopped profile '$Name'"
}

function Invoke-List {
  Write-Host ''
  Write-Host '  Profiles ' -NoNewline
  Write-Host "in $ProfilesRoot" -ForegroundColor DarkGray
  Write-Host ''
  $names = Get-ProfileNames
  foreach ($name in $names) {
    $running = Get-MainPid (Get-ProfileDir $name)
    if ($running) {
      Write-Host ('  ' + $S.On + ' ') -ForegroundColor Green -NoNewline
      Write-Host ('{0,-20} ' -f $name) -NoNewline
      Write-Host 'running ' -ForegroundColor Green -NoNewline
      Write-Host "(pid $running)" -ForegroundColor DarkGray
    } else {
      Write-Host ('  {0} {1,-20} stopped' -f $S.Off, $name) -ForegroundColor DarkGray
    }
  }
  if ($names.Count -eq 0) { Write-Hint "(none yet; create one with: $Me create <name>)" }
}

function Invoke-Config([string]$Name) {
  Test-ProfileName $Name
  $dir = Get-ProfileDir $Name
  if (-not (Test-Path -LiteralPath $dir)) { Fail "profile '$Name' does not exist. Run: $Me create $Name" }
  $cfg = Join-Path $dir 'claude_desktop_config.json'
  if (-not (Test-Path -LiteralPath $cfg)) {
    [IO.File]::WriteAllText($cfg, "{`n  `"mcpServers`": {}`n}`n")
  }
  Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $cfg + '"')
  Write-Ok "Editing: $cfg"
  Write-Hint "After saving, restart the profile:  $Me stop $Name; $Me start $Name"
}

function Invoke-Remove([string[]]$Arguments) {
  $name = ''; $yes = $false
  foreach ($a in $Arguments) {
    if ($a -eq '--yes' -or $a -eq '-y') { $yes = $true }
    elseif ($a.StartsWith('-')) { Fail "unknown option '$a'" }
    elseif ($name) { Fail "unexpected argument '$a'" }
    else { $name = $a }
  }
  Test-ProfileName $name
  $dir = Get-ProfileDir $name
  $lnk = Get-LauncherPath $name
  if (-not (Test-Path -LiteralPath $dir) -and -not (Test-Path -LiteralPath $lnk)) { Fail "profile '$name' does not exist" }
  if (-not $yes) {
    if (-not (Confirm-Choice "Delete the launcher and ALL local data (login, settings, cache, config) for '$name'?" $false)) {
      Write-Host '  Cancelled.'
      return
    }
  }
  $running = Get-MainPid $dir
  Start-Plan "Removing profile '$name'" 2
  if ($running) {
    Add-PlanSteps 1
    Invoke-Step "Quit Claude (pid $running)" { Stop-ClaudePids @($running) }
  }
  Invoke-Step 'Remove launcher' { if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force } }
  Invoke-Step 'Delete profile data' { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
  Complete-Plan "Removed profile '$name'"
}

# --------------------------------------------------------- Claude itself ---

function Get-LatestRelease([string]$Arch) {
  $req = [Net.HttpWebRequest]::Create("https://claude.ai/api/desktop/win32/$Arch/msix/latest/redirect")
  $req.UserAgent = $UA
  $req.AllowAutoRedirect = $true
  $req.Timeout = 30000
  $req.AddRange(0, 0)
  $resp = $req.GetResponse()
  $url = $resp.ResponseUri.AbsoluteUri
  $resp.Close()
  if ($url -notmatch '/releases/win32/[^/]+/([0-9][0-9.]*)/[^/]+\.msix$') {
    Fail "unexpected download address: $url (download Claude from https://claude.ai/download instead)"
  }
  return @{ Version = $Matches[1]; Url = $url }
}

function Invoke-InstallClaude([string[]]$Arguments) {
  $force = $false
  foreach ($a in $Arguments) {
    if ($a -eq '--force' -or $a -eq '-f') { $force = $true } else { Fail "unknown option '$a'" }
  }
  $arch = 'x64'
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $arch = 'arm64' }
  $pkg = Get-ClaudePackage
  $current = ''
  if ($pkg) { $current = [string]$pkg.Version }

  Start-Plan 'Claude Desktop for Windows' 5
  Invoke-Step 'Check for the latest version' {
    $script:Latest = Get-LatestRelease $arch
    $script:StepDetail = 'latest v' + $script:Latest.Version
    if ($current) { $script:StepDetail += ", installed v$current" }
  }
  $latest = $script:Latest.Version
  if ($current -and -not $force -and ([version]$current -ge [version]$latest)) {
    Complete-Plan "Claude v$current is up to date"
    return
  }
  $msix = Join-Path $script:WorkDir "Claude-$latest.msix"
  Invoke-DownloadStep "Download Claude v$latest" $script:Latest.Url $msix
  Invoke-Step 'Verify the signature' {
    $sig = Get-AuthenticodeSignature -LiteralPath $msix
    if ($sig.Status -eq 'Valid') {
      if ($sig.SignerCertificate.Subject -notlike '*Anthropic*') { Fail "unexpected signer: $($sig.SignerCertificate.Subject)" }
      $script:StepDetail = 'signed by Anthropic, PBC'
    } else {
      $script:StepDetail = 'Windows checks the package signature during install'
    }
  }
  $running = @(Get-ClaudeProcesses)
  if ($running.Count -gt 0) {
    Write-Warn ('Claude is running ({0} window(s)). The installer will close it.' -f $running.Count)
    if (-not (Confirm-Choice 'Continue and close Claude?' $true)) { Fail 'cancelled; nothing was changed' }
  }
  $quoted = $msix.Replace("'", "''")
  Invoke-ProcessStep 'Install (Add-AppxPackage)' "Add-AppxPackage -Path '$quoted' -ForceApplicationShutdown"
  Invoke-Step 'Refresh profile launchers' { Update-Launchers (Find-ClaudeApp) }
  if ($current) { Complete-Plan "Claude updated: v$current -> v$latest" }
  else { Complete-Plan "Claude v$latest installed" }
  Remove-Item -LiteralPath $msix -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------- this tool ---

function Test-InPath([string]$Dir) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  foreach ($p in (($env:Path + ';' + $userPath) -split ';')) {
    if ($p -and $p.TrimEnd('\') -ieq $Dir.TrimEnd('\')) { return $true }
  }
  return $false
}

function Invoke-InstallSelf {
  $dest = Join-Path $InstallDir 'claude-multi.ps1'
  Start-Plan 'Installing claude-multi' 3
  Invoke-Step "Create $InstallDir" { $null = New-Item -ItemType Directory -Force -Path $InstallDir }
  if ($Self -and (Test-Path -LiteralPath $Self)) {
    Invoke-Step 'Copy the script' {
      if ((Resolve-Path -LiteralPath $Self).Path -ieq $dest) { $script:StepDetail = 'already installed here' }
      else { Copy-Item -LiteralPath $Self -Destination $dest -Force; $script:StepDetail = $dest }
    }
  } else {
    Invoke-DownloadStep 'Download the script' "$RawUrl/claude-multi.ps1" $dest
  }
  Invoke-Step "Create the '$Me' command" {
    [IO.File]::WriteAllText((Join-Path $InstallDir 'claude-multi.cmd'), $CmdShim + "`r`n")
    $script:StepDetail = Join-Path $InstallDir 'claude-multi.cmd'
  }
  Complete-Plan "Installed into $InstallDir"

  if (Test-InPath $InstallDir) {
    Write-Hint "Run it from anywhere with: $Me"
    return
  }
  Write-Warn "$InstallDir is not on your PATH."
  if (Confirm-Choice 'Add it to your user PATH?' $true) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) { $userPath = $userPath.TrimEnd(';') + ';' + $InstallDir } else { $userPath = $InstallDir }
    [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
    Write-Ok "Added. Open a new terminal, then run: $Me"
  } else {
    Write-Hint "Run it with: & '$dest'"
  }
}

function Invoke-UpdateSelf([string[]]$Arguments) {
  $force = $false
  foreach ($a in $Arguments) {
    if ($a -eq '--force' -or $a -eq '-f') { $force = $true } else { Fail "unknown option '$a'" }
  }
  if (-not $Self -or -not (Test-Path -LiteralPath $Self)) { Fail "can't find this script on disk to update it" }
  $dir = Split-Path -Parent $Self
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git -and (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
    Write-Warn "This copy is inside a git checkout ($dir)."
    if (Confirm-Choice "Update it with 'git pull --ff-only'?" $true) {
      Start-Plan 'Updating claude-multi' 1
      Invoke-Step 'git pull' {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $output = & git -C $dir pull --ff-only 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = $old
        if ($code -ne 0) { Fail $output }
      }
      Complete-Plan 'Repository is up to date'
    }
    return
  }

  $tmp = Join-Path $script:WorkDir 'claude-multi.ps1.new'
  Start-Plan 'Updating claude-multi' 3
  Invoke-DownloadStep 'Download the latest version' "$RawUrl/claude-multi.ps1" $tmp
  Invoke-Step 'Check the download' {
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { Fail 'the download has syntax errors' }
    $m = Select-String -LiteralPath $tmp -Pattern "^\`$Version\s*=\s*'([^']+)'" | Select-Object -First 1
    if (-not $m) { Fail 'the download does not look like claude-multi.ps1' }
    $script:RemoteVersion = $m.Matches[0].Groups[1].Value
    $script:StepDetail = 'v' + $script:RemoteVersion
  }
  if ($script:RemoteVersion -eq $Version -and -not $force) {
    Complete-Plan "claude-multi v$Version is up to date"
    return
  }
  Invoke-Step "Replace $Self" { Copy-Item -LiteralPath $tmp -Destination $Self -Force; $script:StepDetail = $Self }
  Complete-Plan "claude-multi updated: v$Version -> v$($script:RemoteVersion)"
}

function Invoke-UninstallSelf {
  if (-not (Test-Path -LiteralPath $InstallDir)) { Write-Ok "claude-multi is not installed in $InstallDir."; return }
  Remove-Item -LiteralPath $InstallDir -Recurse -Force
  Write-Ok "Removed $InstallDir (profiles and launchers were kept)."
}

# ------------------------------------------------------------------ menu ---

function Show-Status {
  $app = Find-ClaudeApp -Quiet
  $names = Get-ProfileNames
  $running = 0
  foreach ($name in $names) { if (Get-MainPid (Get-ProfileDir $name)) { $running++ } }
  Write-Host '  Platform  ' -ForegroundColor DarkGray -NoNewline; Write-Host 'Windows'
  Write-Host '  Claude    ' -ForegroundColor DarkGray -NoNewline
  if ($app) {
    $ver = Get-AppVersion $app
    if ($ver) { Write-Host "$app (v$ver)" } else { Write-Host $app }
  } else {
    Write-Host 'not installed' -ForegroundColor Yellow
  }
  Write-Host '  Profiles  ' -ForegroundColor DarkGray -NoNewline
  Write-Host ('{0} ({1} running)' -f $names.Count, $running)
  Write-Host ''
}

function Select-Profile([string]$Question) {
  $names = @(Get-ProfileNames)
  if ($names.Count -eq 0) { Fail 'No profiles yet. Create one first.' }
  $labels = @($names | ForEach-Object { if (Get-MainPid (Get-ProfileDir $_)) { "$_  (running)" } else { $_ } })
  $idx = Select-Option $Question $labels 0
  if ($idx -lt 0) { return $null }
  return $names[$idx]
}

function Invoke-MenuAction([scriptblock]$Action) {
  try { & $Action }
  catch {
    if ($_.Exception.Message -ne $StepFailed) { Write-Failure $_.Exception.Message }
  }
  Wait-AnyKey
}

function Invoke-Menu([bool]$AskPlatform) {
  try { if ([Console]::IsInputRedirected) { Show-Usage; return } } catch { Show-Usage; return }
  if ($AskPlatform) {
    if ($Fancy) { Clear-Host }
    Show-Banner
    $idx = Select-Option 'Which platform are you setting up?' @('macOS', 'Linux', 'Windows  (detected)') 2
    if ($idx -lt 0) { return }
    if ($idx -ne 2) {
      Write-Warn 'This is the Windows script. On macOS and Linux, run claude-multi.sh on that machine.'
      return
    }
  }
  while ($true) {
    if ($Fancy) { Clear-Host }
    Show-Banner
    Show-Status
    $choice = Select-Option 'What would you like to do?' @(
      'Create a profile', 'Start a profile', 'Stop a profile', 'List profiles',
      "Edit a profile's MCP config", 'Remove a profile',
      'Install / update Claude Desktop', 'Install / update claude-multi', 'Quit') 0
    switch ($choice) {
      0 { Invoke-MenuAction {
            $name = Read-Input 'Profile name (letters, digits, . _ -)'
            Test-ProfileName $name
            if (Confirm-Choice 'Copy the MCP servers from your regular Claude app?' $true) { Invoke-Create @($name, '--copy-config') }
            else { Invoke-Create @($name) } } }
      1 { Invoke-MenuAction { $p = Select-Profile 'Start which profile?'; if ($p) { Invoke-Start $p } } }
      2 { Invoke-MenuAction { $p = Select-Profile 'Stop which profile?'; if ($p) { Invoke-Stop $p } } }
      3 { Invoke-MenuAction { Invoke-List } }
      4 { Invoke-MenuAction { $p = Select-Profile "Edit which profile's MCP config?"; if ($p) { Invoke-Config $p } } }
      5 { Invoke-MenuAction { $p = Select-Profile 'Remove which profile?'; if ($p) { Invoke-Remove @($p) } } }
      6 { Invoke-MenuAction { Invoke-InstallClaude @() } }
      7 { Invoke-MenuAction {
            $i = Select-Option 'claude-multi' @("Install to $InstallDir (run '$Me' anywhere)", 'Update from GitHub', 'Back') 0
            if ($i -eq 0) { Invoke-InstallSelf } elseif ($i -eq 1) { Invoke-UpdateSelf @() } } }
      default { Write-Host ''; return }
    }
  }
}

# ------------------------------------------------------------------ main ---

function Show-Usage {
  @"
claude-multi v${Version}: isolated Claude Desktop profiles (this is the Windows script)

Usage: $Me [command] [args]

Run it without a command (or double-click claude-multi.cmd) for the interactive menu.

Profiles
  create <name> [--copy-config]  Create a profile and a Start menu launcher.
                                 --copy-config copies the MCP config from the
                                 regular Claude app.
  start  <name>                  Launch Claude with that profile
                                 (brings it to front if already running).
  stop   <name>                  Quit the instance running that profile.
  list                           Show profiles and whether they are running.
  config <name>                  Open that profile's claude_desktop_config.json.
  remove <name> [--yes]          Delete the launcher and the profile's local data.

Claude Desktop
  install-claude [--force]       Install or update Claude Desktop (MSIX from claude.ai).

This tool
  install                        Install claude-multi into $InstallDir
                                 and add it to your PATH.
  update [--force]               Update claude-multi from GitHub.
  uninstall                      Remove that installed copy (profiles are kept).
  version                        Print the version.

On macOS and Linux, use claude-multi.sh.

Environment overrides:
  CLAUDE_APP_PATH       path to Claude (default: the Microsoft Store alias
                        claude-desktop.exe, then %LOCALAPPDATA%\AnthropicClaude)
  CLAUDE_PROFILES_ROOT  where profile data lives (default: %USERPROFILE%\Claude-Profiles)
  CLAUDE_LAUNCHERS_DIR  where launchers are created (default: Start menu\Claude Multi)
  CLAUDE_APP_LABEL      launcher name (default: Claude780)
  CLAUDE_MULTI_BIN_DIR  where 'install' puts the script
  NO_COLOR              turn off colors and animations
"@ | Write-Host
}

function Invoke-Main([string[]]$Argv) {
  $platform = $env:CLAUDE_PLATFORM
  $rest = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $Argv.Count; $i++) {
    $a = $Argv[$i]
    if ($a -eq '--platform' -or $a -eq '-Platform') {
      if ($i + 1 -ge $Argv.Count) { Fail '--platform needs a value' }
      $platform = $Argv[$i + 1]; $i++
    } elseif ($a -like '--platform=*') {
      $platform = $a.Substring(11)
    } else {
      $rest.Add($a)
    }
  }
  if ($platform -and $platform -notmatch '^(win|windows)$') {
    Fail "'$platform' was selected, but this is the Windows script. Run claude-multi.sh on macOS or Linux."
  }
  $cmd = ''
  if ($rest.Count -gt 0) { $cmd = $rest[0] }
  $cmdArgs = @()
  if ($rest.Count -gt 1) { $cmdArgs = $rest.GetRange(1, $rest.Count - 1).ToArray() }
  $first = ''
  if ($cmdArgs.Count -gt 0) { $first = $cmdArgs[0] }

  switch -Regex ($cmd) {
    '^$'                             { Invoke-Menu (-not $platform) }
    '^menu$'                         { Invoke-Menu $false }
    '^(help|-h|--help|/\?)$'         { Show-Usage }
    '^(version|--version|-v)$'       { Write-Host "claude-multi $Version" }
    '^(create|new)$'                 { Invoke-Create $cmdArgs }
    '^(start|open|run)$'             { Invoke-Start $first }
    '^(stop|quit)$'                  { Invoke-Stop $first }
    '^(list|ls)$'                    { Invoke-List }
    '^config$'                       { Invoke-Config $first }
    '^(remove|rm|delete)$'           { Invoke-Remove $cmdArgs }
    '^(install-claude|update-claude)$' { Invoke-InstallClaude $cmdArgs }
    '^install$'                      { Invoke-InstallSelf }
    '^(update|self-update)$'         { Invoke-UpdateSelf $cmdArgs }
    '^uninstall$'                    { Invoke-UninstallSelf }
    default                          { Show-Usage; Fail "unknown command '$cmd'" }
  }
}

$script:WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('claude-multi-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $script:WorkDir
$exitCode = 0
try {
  Invoke-Main @($args)
} catch {
  if ($_.Exception.Message -ne $StepFailed) { Write-Failure $_.Exception.Message }
  $exitCode = 1
} finally {
  try { [Console]::CursorVisible = $true } catch { }
  Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exitCode

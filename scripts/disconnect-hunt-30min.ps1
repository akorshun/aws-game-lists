<#
.SYNOPSIS
  Catches random mid-match disconnects and tells you whether the game server
  was covered by the AWS CIDR list. 30-minute version.

.DESCRIPTION
  Captures UDP traffic with pktmon while you play, then for every game flow it
  answers the one question that matters: was that server inside the CIDR list
  your bypass tool is filtering on?

  A flow marked "IN-LIST: NO" is a server your filter never touched - that is
  what a random disconnect every few matches usually turns out to be.

  Run in an ELEVATED PowerShell (pktmon needs admin).
  Note the wall-clock time when you get kicked, then match it against the
  FIRST/LAST columns in the report.

  Press any key to finish early - the capture stops, decodes and reports
  normally. Do NOT use Ctrl+C for that: it kills the script before the decode
  and you lose the report.

  The report is written to a timestamped file next to the capture, so you can
  reread it later. Paths are printed at the end.

.PARAMETER Minutes
  Capture duration. Default 30.

.PARAMETER Ipset
  Local CIDR file to check against. If omitted, the list is downloaded from
  this repository.

.PARAMETER PortLow / .PARAMETER PortHigh
  Only set these if you narrowed the UDP port range in your bypass config and
  want to verify that choice. Defaults cover everything, so PORT-OK stays yes.

.PARAMETER KeepRaw
  Keep the decoded text file. It is large; deleted by default.

.EXAMPLE
  .\disconnect-hunt-30min.ps1
.EXAMPLE
  .\disconnect-hunt-30min.ps1 -Ipset "D:\zapret\lists\ipset-dbd-all.txt"
#>
param(
  [int]$Minutes  = 30,
  [string]$Ipset,
  [int]$PortLow  = 1024,
  [int]$PortHigh = 65535,
  [switch]$KeepRaw
)

Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'

$ListUrl = 'https://raw.githubusercontent.com/akorshun/aws-game-lists/main/results/cidr_ipv4.txt'
$etl     = Join-Path $env:TEMP 'gamehunt.etl'
$txt     = Join-Path $env:TEMP 'gamehunt.txt'
$reportF = Join-Path $env:TEMP ("gamehunt-report-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host "ERROR: run this in an elevated PowerShell (Run as administrator)." -ForegroundColor Red
  exit 1
}
if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) {
  Write-Host "ERROR: pktmon not found. Needs Windows 10 1809+ or Windows 11." -ForegroundColor Red
  exit 1
}

# Report goes to the console AND into a file, so closing the window does not
# throw away the verdict.
$report = New-Object System.Collections.Generic.List[string]
function Say { param([string]$Text = '', $Color)
  if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
  $report.Add($Text)
}

# ---------------- CIDR list ----------------
if (-not $Ipset) {
  $Ipset = Join-Path $env:TEMP 'aws-game-cidr.txt'
  Write-Host "Downloading CIDR list ..."
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
  try { Invoke-WebRequest -Uri $ListUrl -OutFile $Ipset -UseBasicParsing -TimeoutSec 60 }
  catch { Write-Host "ERROR: could not download the list: $_" -ForegroundColor Red; exit 1 }
}
if (-not (Test-Path $Ipset)) { Write-Host "ERROR: list not found: $Ipset" -ForegroundColor Red; exit 1 }

# NB: [int64] is required. PowerShell's -shl is int32, so "192 -shl 24"
# overflows negative and every match silently fails.
function ConvertTo-IpNum { param([string]$ip)
  $o = $ip -split '\.'
  return ([int64]$o[0] -shl 24) -bor ([int64]$o[1] -shl 16) -bor ([int64]$o[2] -shl 8) -bor [int64]$o[3]
}
$nets = @()
foreach ($l in (Get-Content $Ipset)) {
  $l = $l.Trim()
  if (-not $l -or $l.StartsWith('#') -or $l -notmatch '/') { continue }
  $c = $l -split '/'; $bits = [int]$c[1]
  $mask = if ($bits -eq 0) { [int64]0 } else { ([int64]0xFFFFFFFF -shl (32 - $bits)) -band [int64]0xFFFFFFFF }
  $nets += ,@(((ConvertTo-IpNum $c[0]) -band $mask), $mask, $l)
}
function Get-Cidr { param([string]$ip)
  $n = ConvertTo-IpNum $ip
  foreach ($x in $nets) { if (($n -band $x[1]) -eq $x[0]) { return $x[2] } }
  return $null
}
Say "CIDR list : $($nets.Count) prefixes from $(Split-Path $Ipset -Leaf)"
Say "ports under test: UDP $PortLow-$PortHigh"
Say ""

# ---------------- capture ----------------
# KeyAvailable throws when input is redirected, so probe it once up front.
$canReadKey = $true
try { $null = [Console]::KeyAvailable } catch { $canReadKey = $false }

$capturing = $false
$stoppedEarly = $false
try {
  pktmon stop 2>$null | Out-Null
  pktmon filter remove | Out-Null
  pktmon filter add GAMEHUNT -t UDP | Out-Null
  # --comp nics cuts most per-component duplication. Virtual adapters still log
  # separately, so sample counts are relative, not exact packet counts.
  pktmon start --capture --comp nics --pkt-size 64 --file-name $etl --file-size 1024 | Out-Null
  $capturing = $true

  Write-Host "Capturing for $Minutes min. Play normally." -ForegroundColor Cyan
  Write-Host ">>> WRITE DOWN THE CLOCK TIME WHEN YOU GET KICKED. <<<" -ForegroundColor Yellow
  if ($canReadKey) {
    Write-Host "    Press any key to finish early and get the report." -ForegroundColor DarkGray
  }
  Write-Host ""

  $end = (Get-Date).AddMinutes($Minutes)
  while ((Get-Date) -lt $end) {
    Write-Host ("  {0}   ~{1} min left    " -f (Get-Date -Format 'HH:mm:ss'), [int]($end - (Get-Date)).TotalMinutes) -NoNewline
    Write-Host "`r" -NoNewline
    # sleep in 1s slices so a keypress is noticed quickly
    for ($i = 0; $i -lt 15; $i++) {
      if ($canReadKey -and [Console]::KeyAvailable) {
        [void][Console]::ReadKey($true); $stoppedEarly = $true; break
      }
      Start-Sleep -Seconds 1
    }
    if ($stoppedEarly) { break }
  }
}
finally {
  # Runs even on Ctrl+C, so pktmon is never left capturing in the background.
  if ($capturing) {
    pktmon stop | Out-Null
    pktmon filter remove | Out-Null
  }
}
Write-Host ""
if ($stoppedEarly) { Write-Host "Stopped early on keypress." -ForegroundColor DarkGray }
Write-Host "Decoding (this can take a minute) ..."
pktmon format $etl -o $txt | Out-Null

# ---------------- parse ----------------
$rxTime = [regex]'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})'
$rxFlow = [regex]'(\d{1,3}(?:\.\d{1,3}){3})\.(\d{1,5}) > (\d{1,3}(?:\.\d{1,3}){3})\.(\d{1,5}):'
function Test-Private { param([string]$ip)
  return ($ip -match '^(10\.|127\.|169\.254\.|192\.168\.|22[4-9]\.|23\d\.|255\.|0\.)' -or
          $ip -match '^172\.(1[6-9]|2\d|3[01])\.')
}
$flow = @{}; $now = ''
$fs = New-Object System.IO.FileStream($txt,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
$sr = New-Object System.IO.StreamReader($fs)
while (($line = $sr.ReadLine()) -ne $null) {
  $t = $rxTime.Match($line); if ($t.Success) { $now = $t.Groups[1].Value }
  $m = $rxFlow.Match($line); if (-not $m.Success) { continue }
  $src=$m.Groups[1].Value; $sp=$m.Groups[2].Value; $dst=$m.Groups[3].Value; $dp=$m.Groups[4].Value
  if     (-not (Test-Private $dst)) { $rip=$dst; $rp=$dp }
  elseif (-not (Test-Private $src)) { $rip=$src; $rp=$sp }
  else { continue }
  if ($rp -eq '53' -or $rp -eq '123' -or $rp -eq '443') { continue }   # DNS / NTP / QUIC
  $k = "$rip|$rp"
  if (-not $flow.ContainsKey($k)) { $flow[$k] = @{ first=$now; last=$now; n=0 } }
  $flow[$k].last = $now; $flow[$k].n++
}
$sr.Close(); $fs.Close()

# ---------------- report ----------------
Say ""
Say "=== Game flows in time order (>=200 samples) ===" Cyan
Say ""
Say ("{0,-16} {1,-6} {2,-9} {3,-9} {4,9}  {5,-8} {6,-8} {7}" -f 'REMOTE IP','PORT','FIRST','LAST','SAMPLES','PORT-OK','IN-LIST','MATCHED CIDR')
Say ("-" * 112)
$rows = @()
foreach ($k in $flow.Keys) {
  if ($flow[$k].n -lt 200) { continue }
  $p = $k -split '\|'
  $rows += ,[pscustomobject]@{ Ip=$p[0]; Port=[int]$p[1]; First=$flow[$k].first; Last=$flow[$k].last; N=$flow[$k].n }
}
$bad = @()
foreach ($r in ($rows | Sort-Object First)) {
  $portOk = ($r.Port -ge $PortLow -and $r.Port -le $PortHigh)
  $cidr = Get-Cidr $r.Ip
  Say ("{0,-16} {1,-6} {2,-9} {3,-9} {4,9}  {5,-8} {6,-8} {7}" -f `
    $r.Ip, $r.Port, ($r.First -split ' ')[1], ($r.Last -split ' ')[1], $r.N,
    $(if($portOk){'yes'}else{'NO'}), $(if($cidr){'yes'}else{'NO'}), $(if($cidr){$cidr}else{'-- not in list --'}))
  if (-not $portOk -or -not $cidr) { $bad += ,$r }
}

Say ""
if ($rows.Count -eq 0) {
  Say "No game flows seen. Was a match actually running during the capture?" Yellow
} elseif ($bad.Count -gt 0) {
  Say "=== VERDICT: some servers were NOT covered ===" Red
  foreach ($r in $bad) {
    $why = @()
    if ($r.Port -lt $PortLow -or $r.Port -gt $PortHigh) { $why += "port $($r.Port) outside $PortLow-$PortHigh" }
    if (-not (Get-Cidr $r.Ip)) { $why += "IP $($r.Ip) not in the CIDR list" }
    Say ("  $($r.Ip):$($r.Port)  first seen $($r.First)  ->  $($why -join '; ')")
  }
  Say ""
  Say "  If the IP is missing: refresh the list (AWS adds ranges constantly)," Yellow
  Say "  or that game simply is not hosted on AWS." Yellow
} else {
  Say "=== VERDICT: every game flow was covered ===" Green
  Say "  Scope is fine, so look at your bypass strategy instead."
  Say "  For zapret, a common culprit is --dpi-desync-cutoff=n2: it only treats"
  Say "  the first 2 packets of a flow, leaving the rest of the match unprotected."
}
Say ""
Say "Compare the FIRST/LAST times above with when you got kicked."

$report | Set-Content $reportF -Encoding UTF8
Write-Host ""
Write-Host "Report saved to: $reportF" -ForegroundColor Cyan
if ($KeepRaw) {
  Write-Host "Raw decode kept at: $txt"
} else {
  Remove-Item -LiteralPath $txt -Force -ErrorAction SilentlyContinue
  Write-Host "Raw decode deleted (it is large). Pass -KeepRaw to keep it."
}

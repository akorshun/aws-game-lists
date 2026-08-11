<#
.SYNOPSIS
  Regenerates results/cidr_ipv4.txt from the official AWS published ranges.

.DESCRIPTION
  Takes the UNION of the AMAZON, EC2 and GLOBALACCELERATOR service tags from
  https://ip-ranges.amazonaws.com/ip-ranges.json

  Why the union and not just EC2: EC2 is only ~1900 of ~6100 prefixes, and game
  servers routinely land in ranges tagged AMAZON. An EC2-only list leaves two
  thirds of AWS uncovered, which shows up as a working session that randomly
  drops every few matches once matchmaking moves you to an uncovered server.
  AMAZON is also NOT a strict superset of EC2 - a few dozen /32s under
  99.77.55.x carry the EC2 tag only - so taking AMAZON alone still misses them.

  There is no GAMELIFT service tag; GameLift fleets run on EC2.

  No admin needed. AWS revises the source file several times a week.

.PARAMETER OutDir
  Where to write results/. Defaults to the repository root.
#>
param(
  [string]$OutDir = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$wanted  = 'AMAZON','EC2','GLOBALACCELERATOR'
$results = Join-Path $OutDir 'results'
$out     = Join-Path $results 'cidr_ipv4.txt'
$tmp     = Join-Path $env:TEMP 'aws-ip-ranges.json'

if (-not (Test-Path $results)) { New-Item -ItemType Directory -Force -Path $results | Out-Null }

Write-Host "Fetching ip-ranges.json ..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri 'https://ip-ranges.amazonaws.com/ip-ranges.json' -OutFile $tmp -UseBasicParsing -TimeoutSec 120

$raw = Get-Content $tmp -Raw
$created = ([regex]'"createDate"\s*:\s*"([^"]+)"').Match($raw).Groups[1].Value
Write-Host "AWS snapshot: $created"

$rx  = [regex]'"ip_prefix"\s*:\s*"([^"]+)",\s*"region"\s*:\s*"([^"]+)",\s*"service"\s*:\s*"([^"]+)"'
$all = New-Object 'System.Collections.Generic.HashSet[string]'
$per = @{}
foreach ($m in $rx.Matches($raw)) {
  $svc = $m.Groups[3].Value
  if ($wanted -notcontains $svc) { continue }
  [void]$all.Add($m.Groups[1].Value)
  if ($per.ContainsKey($svc)) { $per[$svc]++ } else { $per[$svc] = 1 }
}

if ($all.Count -lt 3000) {
  Write-Host "ABORT: only $($all.Count) prefixes parsed - the JSON format probably changed." -ForegroundColor Red
  Write-Host "Existing list left untouched." -ForegroundColor Red
  exit 1
}

$prev = if (Test-Path $out) { (Get-Content $out).Count } else { 0 }
# ASCII, no BOM - a BOM breaks the first line for zapret and most parsers
($all | Sort-Object) | Set-Content $out -Encoding ASCII

Write-Host ""
foreach ($s in $wanted) { "  {0,-20} {1,6}" -f $s, $per[$s] }
Write-Host ""
$new = (Get-Content $out).Count
Write-Host "results/cidr_ipv4.txt : $new prefixes (was $prev, delta $($new - $prev))" -ForegroundColor Green

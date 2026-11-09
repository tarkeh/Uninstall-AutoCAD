#requires -version 5.1
<#+
.SYNOPSIS
 Conservative Autodesk application family cleanup for Microsoft Configuration Manager.
.DESCRIPTION
 Audit (default), Execute, or Detect. Retains latest installed year in EACH whitelisted
 family, optionally enforcing a year floor. Never removes the only release in a family.
 Supports verified ODIS, MSI, and Classic Autodesk Setup uninstall strings; optionally
 use an administrator-reviewed mapping CSV for classic uninstall commands.
 Does NOT remove server, shared, licensing, libraries, language packs, updates or add-ins.
.EXAMPLE
 .\Invoke-AutodeskCleanup.ps1 -Mode Audit
.EXAMPLE
 .\Invoke-AutodeskCleanup.ps1 -Mode Execute -MinimumKeepYear 2025
#>
[CmdletBinding()]
param(
 [ValidateSet('Audit','Execute','Detect')][string]$Mode='Audit',
 [ValidateRange(2000,2100)][int]$MinimumKeepYear=2000,
 [string]$LegacyOverridesCsv='',
 [ValidateRange(0,10)][int]$MaxRetries=2,
 [ValidateRange(5,600)][int]$RetryDelaySeconds=45,
 [string]$LogRoot="$env:ProgramData\AutodeskVersionCleanup",
 [switch]$AllowRunningApplications
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$script:RebootRequired=$false
$script:Issues=New-Object System.Collections.Generic.List[string]
$script:LogFile=$null

function Write-Log([string]$Message,[string]$Level='INFO') {
 $line="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
 if ($Mode -ne 'Detect') { Write-Host $line }
 if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}
function Get-Family([string]$Name) {
 # Exact major-product prefixes only. Intentional exclusions avoid updates/add-ins/servers.
 if ($Name -match '(?i)\b(server|ADMS|add[ -]?in|plugin|plug-in|object enabler|language pack|material library|content|update|hotfix|service pack|SDK|viewer|Autodesk Access|licensing)\b') { return $null }
 if ($Name -match '(?i)^Autodesk\s+Vault\s+(?:Basic\s+|Professional\s+|Workgroup\s+)?(?:Client\s+)?20\d{2}(?:\s|$)' -or
     $Name -match '(?i)^Autodesk\s+Vault\s+(?:Basic\s+|Professional\s+|Workgroup\s+)?(?:Client\s+)?\d+(?:\.\d+)*(?:\s|$)') {
   # Require explicit year elsewhere; exclude Vault Office and integrations below.
   if ($Name -match '(?i)\b(Office|Explorer|Job Processor|Data Standard|Thin Client)\b') {return $null}
   return 'Vault Client'
 }
 if ($Name -match '(?i)^(?:Autodesk\s+)?AutoCAD\s+Electrical\s+20\d{2}\b') { return 'AutoCAD Electrical' }
 if ($Name -match '(?i)^(?:Autodesk\s+)?AutoCAD\s+Mechanical\s+20\d{2}\b') { return 'AutoCAD Mechanical' }
 if ($Name -match '(?i)^(?:Autodesk\s+)?AutoCAD\s+Architecture\s+20\d{2}\b') { return 'AutoCAD Architecture' }
 if ($Name -match '(?i)^(?:Autodesk\s+)?AutoCAD\s+Map\s+3D\s+20\d{2}\b') { return 'AutoCAD Map 3D' }
 if ($Name -match '(?i)^(?:Autodesk\s+)?AutoCAD\s+Plant\s+3D\s+20\d{2}\b') { return 'AutoCAD Plant 3D' }
 if ($Name -match '(?i)^(?:Autodesk\s+)?AutoCAD\s+LT\s+20\d{2}\b') { return 'AutoCAD LT' }
 if ($Name -match '(?i)^(?:Autodesk\s+)?AutoCAD\s+20\d{2}\b') { return 'AutoCAD' }
 if ($Name -match '(?i)^(?:Autodesk\s+)?Civil\s+3D\s+20\d{2}\b') { return 'Civil 3D' }
 return $null
}
function Get-InstalledProducts {
 $roots=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
 $found=@()
 foreach ($root in $roots) {
  if (-not (Test-Path $root)) {continue}
  foreach($key in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
   $p=Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
   if (-not $p -or -not $p.DisplayName) {continue}
   $name=[string]$p.DisplayName
   $family=Get-Family $name
   if (-not $family) {continue}
   if ($name -notmatch '\b(20(?:1[0-9]|2[0-9]|3[0-9]))\b') {continue}
   $year=[int]$Matches[1]
   # Some uninstall entries are hidden or component registrations with misleading names.
   if ($p.SystemComponent -eq 1 -or $p.ParentKeyName) {continue}
   $found += [pscustomobject]@{
      Name=$name; Family=$family; Year=$year; RegistryKey=$key.PSChildName
      RegistryPath=$key.Name; UninstallString=[string]$p.UninstallString
      QuietUninstallString=[string]$p.QuietUninstallString
      WindowsInstaller=($p.WindowsInstaller -eq 1)
      DisplayVersion=[string]$p.DisplayVersion
   }
  }
 }
 # Deduplicate identical registry uninstall entries in both views, if any.
 return @($found | Sort-Object RegistryPath -Unique)
}
function Get-Plan($products) {
 $plan=@()
 foreach($group in @($products | Group-Object Family)) {
  $newest=($group.Group | Measure-Object Year -Maximum).Maximum
  foreach($p in $group.Group) {
   $action='Keep';$reason='Newest version in family'
   if ($p.Year -eq $newest) { $reason='Newest year in family' }
   elseif ($p.Year -ge $MinimumKeepYear) { $reason="Year at/above floor $MinimumKeepYear" }
   else { $action='Remove';$reason="Older than $newest in same family and below year floor" }
   $plan += [pscustomobject]@{Computer=$env:COMPUTERNAME;Name=$p.Name;Family=$p.Family;Year=$p.Year;NewestYear=$newest;Action=$action;Reason=$reason;Method='';Status='NotStarted';ExitCode='';RegistryPath=$p.RegistryPath;Key=$p.RegistryKey;UninstallString=$p.UninstallString;QuietUninstallString=$p.QuietUninstallString;WindowsInstaller=$p.WindowsInstaller}
  }
 }
 return @($plan | Sort-Object Family,Year,Name)
}
function Split-Command([string]$Command) {
 $s=$Command.Trim()
 if (-not $s) {return $null}
 if ($s -match '^"([^"]+\.exe)"\s*(.*)$') { return @($Matches[1],$Matches[2]) }
 if ($s -match '^(.+?\.exe)\s+(.*)$') { return @($Matches[1].Trim(),$Matches[2]) }
 if ($s -match '^(.+?\.exe)$') {return @($Matches[1],'')}
 return $null
}
function Get-SafeCommand($item,$overrides) {
 $raw=$item.QuietUninstallString
 if ([string]::IsNullOrWhiteSpace($raw)) { $raw=$item.UninstallString }
 $source='Registry'
 $overrideKey="$($item.Family)|$($item.Year)"
 if ($overrides.ContainsKey($overrideKey)) { $raw=$overrides[$overrideKey];$source='ApprovedOverride' }
 $parts=Split-Command $raw
 if (-not $parts) {return @{Error='No parseable uninstall command'}}
 $exe=$parts[0];$arg=$parts[1]
 # Only vendor uninstallers or MSI. Do not invoke cmd.exe or arbitrary scripts.
 if ($exe -match '(?i)(?:^|\\)msiexec(?:\.exe)?$') {
   $guid=''
   if ($arg -match '(?i)(?:/I|/X)\s*\{([A-F0-9-]{36})\}') { $guid=$Matches[1] }
   elseif ($item.Key -match '^\{[A-Fa-f0-9-]{36}\}$' -and $item.WindowsInstaller) {$guid=$item.Key.Trim('{}')}
   if (-not $guid) {return @{Error='MSI command does not contain a recognized product code'}}
   return @{Exe="$env:WINDIR\System32\msiexec.exe";Args="/x {$guid} /qn /norestart";Method="MSI ($source)"}
 }
 if ($exe -match '(?i)\\AdODIS\\V1\\Installer\.exe$') {
   if ($arg -notmatch '(?i)(?:^|\s)-i\s+uninstall(?:\s|$)' -or $arg -notmatch '(?i)(?:^|\s)-m\s+') {return @{Error='ODIS command is missing uninstall or manifest arguments'}}
   if ($arg -match '(?i)(?:^|\s)-i\s+install(?:\s|$)') {return @{Error='ODIS install command was found instead of uninstall'}}
   # Verify referenced manifest actually exists; do not fabricate path.
   if ($arg -notmatch '(?i)(?:^|\s)-m\s+(?:"([^"]+\.xml)"|([^\s]+\.xml))') {return @{Error='Cannot identify ODIS manifest'}}
   $manifest=if($Matches[1]) {$Matches[1]}else{$Matches[2]}
   if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {return @{Error="ODIS manifest missing: $manifest"}}
   if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {return @{Error='ODIS installer missing'}}
   # Ensure each additional linked local metadata file exists if explicitly referenced.
   foreach($opt in @('-x','--extension_manifest','--extension_manifest_xsd','-o')) {
    $pattern='(?i)(?:^|\s)'+[regex]::Escape($opt)+'\s+(?:"([^"]+)"|([^\s]+))'
    if ($arg -match $pattern) { $path=if($Matches[1]){$Matches[1]}else{$Matches[2]};if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return @{Error="ODIS metadata missing: $path"}} }
   }
   if ($arg -notmatch '(?i)(?:^|\s)-q(?:\s|$)' -and $arg -notmatch '(?i)(?:^|\s)--silent(?:\s|$)') {$arg+=' -q'}
   return @{Exe=$exe;Args=$arg;Method="ODIS ($source)"}
 }
 if ($exe -match '(?i)\\(?:Setup|Uninstall)\.exe$' -and $exe -match '(?i)\\Autodesk\\') {
   # Classic 2019-21: require complete, product-specific registered parameters.
   if ($item.Year -gt 2021) {return @{Error='Classic uninstall only enabled for <=2021'}}
   if ($arg -notmatch '(?i)(?:^|\s)/P\s*\{[A-F0-9-]{36}\}(?:\s|$)' -or $arg -notmatch '(?i)(?:^|\s)/R\s+\S+') {
    return @{Error='Classic uninstall needs verified /P {GUID} and /R PRODUCT parameters; supply approved override CSV if needed'}
   }
   if ($arg -notmatch '(?i)(?:^|\s)/LANG\s+\S+') {return @{Error='Classic uninstall missing /LANG; supply approved override CSV'}}
   if (-not(Test-Path -LiteralPath $exe -PathType Leaf)) {return @{Error='Classic setup/uninstall executable missing'}}
   if ($arg -notmatch '(?i)(?:^|\s)/Q(?:\s|$)') {$arg+=' /Q'}
   if ($arg -notmatch '(?i)(?:^|\s)/W(?:\s|$)') {$arg+=' /W'}
   return @{Exe=$exe;Args=$arg;Method="Classic ($source)"}
 }
 return @{Error='Unsupported uninstall engine; manual review required'}
}
function Test-RegistryPresent([string]$RegistryPath) {
 $psPath='Registry::'+$RegistryPath
 return (Test-Path -LiteralPath $psPath)
}
function Export-Reports($plan,$summary) {
 $plan | Select-Object Computer,Name,Family,Year,NewestYear,Action,Reason,Method,Status,ExitCode,RegistryPath | Export-Csv -LiteralPath (Join-Path $LogRoot 'LatestPlan.csv') -NoTypeInformation -Encoding UTF8
 $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $LogRoot 'LatestSummary.json') -Encoding UTF8
}
try {
 if ([IntPtr]::Size -ne 8) { throw 'Run the 64-bit PowerShell host (SysNative from 32-bit SCCM context).' }
 if ($Mode -eq 'Execute') {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Administrator/SYSTEM rights required'}
 }
 if ($Mode -ne 'Detect') {
  New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
  $script:LogFile=Join-Path $LogRoot ("Run-{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date),$PID)
 }
 $overrideMap=@{}
 if ($LegacyOverridesCsv) {
  if (-not(Test-Path -LiteralPath $LegacyOverridesCsv -PathType Leaf)) {throw "Override CSV missing: $LegacyOverridesCsv"}
  foreach($o in @(Import-Csv -LiteralPath $LegacyOverridesCsv)) {
   if (-not $o.Family -or -not $o.Year -or -not $o.UninstallCommand) {throw 'Overrides CSV requires Family,Year,UninstallCommand'}
   if (@('AutoCAD','AutoCAD Electrical','AutoCAD Mechanical','AutoCAD Architecture','AutoCAD Map 3D','AutoCAD Plant 3D','AutoCAD LT','Civil 3D','Vault Client') -notcontains $o.Family) {throw "Unknown family in override: $($o.Family)"}
   if ([int]$o.Year -gt 2021) {throw 'Overrides are allowed only for classic 2021-and-older entries'}
   $overrideMap["$($o.Family)|$($o.Year)"]=$o.UninstallCommand
  }
 }
 $products=@(Get-InstalledProducts)
 $plan=@(Get-Plan $products)
 $candidates=@($plan | Where-Object Action -eq 'Remove')
 Write-Log "Computer=$env:COMPUTERNAME mode=$Mode found=$($plan.Count) older=$($candidates.Count) floor=$MinimumKeepYear"
 $blockedRunning=$false
 if ($Mode -eq 'Execute' -and $candidates.Count -gt 0 -and -not $AllowRunningApplications) {
  $running=@(Get-Process -Name acad,acadlt,acadlt64,Inventor,Revit,Connectivity.VaultPro,Connectivity.VaultWkf,Connectivity.Vault -ErrorAction SilentlyContinue)
  if ($running.Count -gt 0) { $blockedRunning=$true;Write-Log ('Applications running: '+(($running.ProcessName | Sort-Object -Unique) -join ', ')) 'WARN' }
 }
 foreach($item in $candidates) {
  $cmd=Get-SafeCommand $item $overrideMap
  if ($cmd.ContainsKey('Error')) {
   $item.Status='Blocked';$item.Reason=$cmd.Error
   $script:Issues.Add("$($item.Name): $($cmd.Error)")
   Write-Log "BLOCKED $($item.Name): $($cmd.Error)" 'WARN'
   continue
  }
  $item.Method=$cmd.Method
  if ($Mode -ne 'Execute') {$item.Status='Eligible';Write-Log "ELIGIBLE $($item.Name) method=$($item.Method)";continue}
  if ($blockedRunning) {$item.Status='Deferred';$item.Reason='CAD/Vault process running';$script:Issues.Add("$($item.Name): apps running");continue}
  Write-Log "REMOVE $($item.Name) using $($cmd.Method)"
  $attempt=0;$finished=$false
  while($attempt -le $MaxRetries -and -not $finished) {
   $attempt++
   try {
    $proc=Start-Process -FilePath $cmd.Exe -ArgumentList $cmd.Args -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    $code=[int]$proc.ExitCode
    $item.ExitCode=[string]$code
    if ($code -in @(0,3010,1641,1605,1614)) {
     if ($code -in @(3010,1641)) {$script:RebootRequired=$true}
     Start-Sleep -Seconds 3
     if (Test-RegistryPresent $item.RegistryPath) {
       $item.Status='NeedsVerification';$item.Reason="Uninstaller exit $code; registry registration still present"
       $script:Issues.Add("$($item.Name): uninstall exited $code but still registered")
     } else {$item.Status='Removed';$item.Reason='Uninstall command completed and registration absent'}
     $finished=$true
    } elseif ($code -eq 1618 -and $attempt -le $MaxRetries) {
     Write-Log "Windows Installer busy; retry $attempt/$MaxRetries after $RetryDelaySeconds s" 'WARN'
     Start-Sleep -Seconds $RetryDelaySeconds
    } else {
     $item.Status='Failed';$item.Reason="Uninstaller returned $code"
     $script:Issues.Add("$($item.Name): exit $code")
     $finished=$true
    }
   } catch {
    $item.Status='Failed';$item.Reason=$_.Exception.Message
    $script:Issues.Add("$($item.Name): $($_.Exception.Message)")
    $finished=$true
   }
  }
  if (-not $finished) {$item.Status='Failed';$item.Reason='Installer busy after retries';$script:Issues.Add("$($item.Name): installer busy")}
  Write-Log "$($item.Status) $($item.Name) exit=$($item.ExitCode) $($item.Reason)"
 }
 $summary=[pscustomobject]@{
  Computer=$env:COMPUTERNAME;Time=(Get-Date).ToString('o');Mode=$Mode;MinimumKeepYear=$MinimumKeepYear
  ProductCount=$plan.Count;OlderCount=$candidates.Count
  Removed=@($plan|Where-Object Status -eq 'Removed').Count
  Blocked=@($plan|Where-Object Status -in @('Blocked','Deferred','Failed','NeedsVerification')).Count
  RebootRequired=$script:RebootRequired;Issues=@($script:Issues.ToArray())
 }
 if ($Mode -ne 'Detect') {Export-Reports $plan $summary}
 # Detect returns 0 only when no older eligible entries remain; use as App detection source.
 if ($Mode -eq 'Detect') {if ($candidates.Count -eq 0) {exit 0}else{exit 1}}
 if ($Mode -eq 'Audit') {exit 0}
 if ($script:Issues.Count -gt 0) {exit 1}
 if ($script:RebootRequired) {exit 3010}
 exit 0
} catch {
 Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
 exit 1
}

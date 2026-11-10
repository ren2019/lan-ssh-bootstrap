$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'assets') -Filter *.ps1) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($file.Name + ': ' + ($errors.Message -join '; ')) }
}
. (Join-Path $root 'assets/core.ps1')
$sid = 'S-1-5-21-100-200-300-1001'
$original = "Port 22`r`nPasswordAuthentication yes`r`nMatch Group administrators`r`n    AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n"
$paths = @(Get-KeyFileTokens '__PROGRAMDATA__/ssh/administrators_authorized_keys')
$result = Add-AccountKeySource $original 'Example' $sid $paths 'C:/ProgramData/lan-ssh-bootstrap/keys/example'
if ($result.IndexOf('Match User "example"') -gt $result.IndexOf('Match Group administrators')) { throw 'User rule must precede administrator group rule.' }
if ($result -notmatch 'AuthorizedKeysFile "__PROGRAMDATA__/ssh/administrators_authorized_keys" "C:/ProgramData/lan-ssh-bootstrap/keys/example"') { throw 'Existing key source was lost.' }
$again = Add-AccountKeySource $result 'Example' $sid $paths 'C:/ProgramData/lan-ssh-bootstrap/keys/example'
if ($again -ne $result) { throw 'Repeated setup changed the managed configuration.' }
$locked = Set-KeyOnlyAuthentication $result
if ($locked -notmatch '(?m)^PasswordAuthentication no' -or $locked.IndexOf('PasswordAuthentication no') -gt $locked.IndexOf('Match User')) { throw 'Password policy was not applied globally.' }
$secondSid='S-1-5-21-100-200-300-1002'
$twoAccounts=Add-AccountKeySource $locked 'Another' $secondSid @('.ssh/authorized_keys') 'C:/ProgramData/lan-ssh-bootstrap/keys/another'
$changedAgain=Add-AccountKeySource $twoAccounts 'Example' $sid $paths 'C:/ProgramData/lan-ssh-bootstrap/keys/example'
if ($changedAgain -notmatch 'Match User "another"' -or $changedAgain -notmatch '(?m)^KbdInteractiveAuthentication no') { throw 'Updating one account removed another account or global authentication policy.' }
if (-not (Test-NarrowerScope '192.0.2.20,192.0.2.64/26' '192.0.2.0/24')) { throw 'Valid narrow scope rejected.' }
if (Test-NarrowerScope '0.0.0.0/0' '192.0.2.0/24') { throw 'Wider scope accepted.' }
if ((Get-ScopeSignature '192.0.2.0/24') -ne (Get-ScopeSignature '192.0.2.0/255.255.255.0')) { throw 'Equivalent Windows firewall scopes differ.' }
$rejected=$false;try { Get-KeyFileTokens 'C:/Program Files/custom keys' | Out-Null } catch { $rejected=$true }
if (-not $rejected) { throw 'Ambiguous custom key path accepted.' }
# Exercise standalone recovery with fake firewall/service commands, never the OS.
function Get-CimInstance { param($ClassName, $Filter) return $null }
function Get-NetFirewallRule { param($Name) $global:lsbFakeRule }
function Get-NetFirewallPortFilter { process { [pscustomobject]@{ Protocol='TCP'; LocalPort='22'; RemotePort='Any' } } }
function Get-NetFirewallAddressFilter { process { [pscustomobject]@{ LocalAddress='Any'; RemoteAddress=$global:lsbFakeScope } } }
function Get-NetFirewallApplicationFilter { process { [pscustomobject]@{ Program='C:/Program Files/OpenSSH/sshd.exe' } } }
function Get-NetFirewallServiceFilter { process { [pscustomobject]@{ Service='Any' } } }
function Enable-NetFirewallRule { param($Name) $global:lsbReenabled += $Name }
$global:lsbFakeRule=[pscustomobject]@{ Name='installer-rule'; Description='Installer SSH'; Direction='Inbound'; Action='Allow'; Profile='Any'; Enabled='False' }
$global:lsbFakeScope='Any'; $global:lsbReenabled=@()
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('lsb-recovery-check-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $receipt=@{ Fresh=$true; OwnedFreshService=$true; Config=(Join-Path $temporary 'absent-config'); DisabledRules=@(@{ Name='installer-rule'; Signature=(Get-LsbRuleSignature $global:lsbFakeRule) }) }
    [IO.File]::WriteAllText((Join-Path $temporary 'state.json'), ($receipt | ConvertTo-Json -Depth 5))
    $standalone=[IO.File]::ReadAllText((Join-Path $root 'assets/core.ps1')) + "`n" + [IO.File]::ReadAllText((Join-Path $root 'assets/restore.ps1'))
    # Only the administrator preflight uses a platform API; remove it from this
    # mock-only copy so the same recovery behaviour can be checked on macOS.
    $standalone=[regex]::Replace($standalone, '(?m)^\$principal = New-Object Security\.Principal\.WindowsPrincipal[^\r\n]*\r?\nif \(-not \$principal\.IsInRole[^\r\n]*\r?\n', '')
    [IO.File]::WriteAllText((Join-Path $temporary 'restore.ps1'), $standalone, (New-Object Text.UTF8Encoding($true)))
    & (Join-Path $temporary 'restore.ps1') | Out-Null
    if ($global:lsbReenabled.Count -ne 1 -or $global:lsbReenabled[0] -ne 'installer-rule') { throw 'Recovery did not restore the approved installation-time rule.' }
    $global:lsbFakeScope='192.0.2.1'; $global:lsbReenabled=@(); $rejected=$false
    try { & (Join-Path $temporary 'restore.ps1') | Out-Null } catch { $rejected=$true }
    if (-not $rejected -or $global:lsbReenabled.Count) { throw 'Recovery overwrote a concurrently changed firewall rule.' }
} finally { [IO.Directory]::Delete($temporary, $true) }
Write-Output 'PowerShell syntax and configuration checks passed. No Windows settings were changed.'

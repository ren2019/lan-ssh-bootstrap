# Requires administrator PowerShell. This script is copied beside state.json.
$ErrorActionPreference = 'Stop'
$statePath = Join-Path $PSScriptRoot 'state.json'
$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
function Get-LsbRestoreHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run in administrator PowerShell.' }
if ($state.InstallerPID) {
    $installer = Get-Process -Id $state.InstallerPID -ErrorAction SilentlyContinue
    if ($installer -and $installer.ProcessName -eq 'msiexec' -and $installer.StartTime.ToUniversalTime().ToString('o') -eq $state.InstallerStarted) {
        throw 'Installer is still running. The temporary SSH port block is retained. Wait for installation to finish, then run this recovery command again.'
    }
}
$service = Get-CimInstance Win32_Service -Filter "Name='sshd'"
if ($state.ServiceTouched -and -not $state.Fresh -and -not $service) { throw 'The original SSH service was removed after setup; manual recovery is required.' }
if ($state.Fresh -and $service -and -not $state.OwnedFreshService) { throw 'A new SSH service has uncertain ownership. Installation guard is retained; review the service manually.' }
if ($state.ServicePID -and $service.State -eq 'Running' -and $service.ProcessId -ne $state.ServicePID) { throw 'SSH service was restarted after setup. Review concurrent changes before restoring.' }
# Validate all known guards before restoring any setting.
if ($state.AfterHash -and -not (Test-Path -LiteralPath $state.Config)) { throw 'SSH configuration disappeared after setup; manual recovery is required.' }
if ($state.AfterHash -and (Test-Path -LiteralPath $state.Config)) {
    if ((Get-LsbRestoreHash $state.Config) -ne $state.AfterHash) { throw 'SSH configuration changed after setup. Refusing to overwrite concurrent changes.' }
}
if ($state.CreatedRule) {
    $rule = Get-NetFirewallRule -Name $state.RuleName -ErrorAction SilentlyContinue
    if ($rule) {
        $scope = @($rule | Get-NetFirewallAddressFilter).RemoteAddress -join ','
        if ($scope -ne $state.Allowed) { throw 'Firewall scope changed after setup. Refusing to overwrite concurrent changes.' }
    }
}
if ($state.CreatedKey -and (Test-Path -LiteralPath $state.KeyPath)) {
    if ((Get-LsbRestoreHash $state.KeyPath) -ne $state.KeyHash) { throw 'Managed public-key file changed. Refusing to remove it.' }
}
foreach ($disabled in @($state.DisabledRules)) {
    $current = @(Get-NetFirewallRule -Name $disabled.Name -ErrorAction SilentlyContinue)
    if ($current.Count -ne 1 -or (Get-LsbRuleSignature $current[0]) -ne $disabled.Signature) { throw 'An installation-time firewall rule changed; manual recovery is required.' }
}
if ($state.AfterHash -and (Test-Path -LiteralPath $state.Config)) {
    if ($state.HadConfig) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sshd_config.before') -Destination $state.Config -Force }
    else { Remove-Item -LiteralPath $state.Config }
}
if ($state.CreatedRule -and $rule) { Remove-NetFirewallRule -Name $state.RuleName }
if ($state.CreatedKey -and (Test-Path -LiteralPath $state.KeyPath)) { Remove-Item -LiteralPath $state.KeyPath }
if ($service -and ($state.ServiceTouched -or $state.OwnedFreshService)) {
    Stop-Service sshd
    if ($state.Fresh) { Set-Service sshd -StartupType Disabled }
    else {
        $mode = @{ Auto = 'Automatic'; Manual = 'Manual'; Disabled = 'Disabled' }[$state.StartMode]
        if ($state.WasRunning -and $mode -eq 'Disabled') {
            Set-Service sshd -StartupType Manual
            Start-Service sshd
            Set-Service sshd -StartupType Disabled
        } else {
            Set-Service sshd -StartupType $mode
            if ($state.WasRunning) { Start-Service sshd }
        }
    }
}
foreach ($disabled in @($state.DisabledRules)) { Enable-NetFirewallRule -Name $disabled.Name }
if ($state.BlockRule) { Remove-NetFirewallRule -Name $state.BlockRule -ErrorAction SilentlyContinue }
if ($state.Fresh) { Write-Host 'Settings restored; the new package and host keys are retained without enabling sshd. / 设置已恢复；新软件包及主机密钥保留，未启用 sshd。' }
else { Write-Host 'Previous SSH settings and service state restored. / 已恢复原有 SSH 设置和服务状态。' }

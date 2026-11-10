$ErrorActionPreference = 'Stop'
$script:attempt = [Guid]::NewGuid().ToString('N')
$script:receipt = $null
$script:stateDir = $null
function Get-LsbText([string]$Zh, [string]$En) { if ($BootstrapConfig.language -eq 'en') { $En } else { $Zh } }
function Request-Session([string]$Path, [object]$Payload = $null) {
    $request = [Net.HttpWebRequest]::Create($BootstrapConfig.base + $Path)
    $request.Proxy = $null
    $request.Timeout = 10000
    $request.ReadWriteTimeout = 10000
    $request.Headers['X-Attempt'] = $script:attempt
    if ($null -ne $Payload) {
        $request.Method = 'POST'
        $request.ContentType = 'application/json; charset=utf-8'
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Compress))
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}
function Send-Stage([string]$Stage, [object]$Identity = $null) {
    $payload = @{ attempt = $script:attempt; stage = $Stage; message = ''; user = ''; sid = ''; hostKey = ''; fresh = $false; port = 22 }
    if ($Identity) {
        $payload.user = $Identity.User; $payload.sid = $Identity.Sid
        $payload.hostKey = $Identity.HostKey; $payload.fresh = $script:receipt.Fresh; $payload.port = $Identity.Port
    }
    Request-Session '/event' $payload | Out-Null
}
function Save-Receipt {
    [IO.File]::WriteAllText((Join-Path $script:stateDir 'state.json'), ($script:receipt | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}
function Write-Config([string]$Text) {
    if (Test-Path -LiteralPath $script:receipt.Config) {
        if ((Get-Sha256 $script:receipt.Config) -ne $script:receipt.AfterHash) { throw (Get-LsbText 'SSH 配置被其他程序修改，已停止覆盖。' 'SSH configuration changed concurrently; overwrite refused.') }
    } elseif ($script:receipt.AfterHash) { throw 'SSH configuration disappeared concurrently.' }
    $candidate = Join-Path $script:stateDir 'sshd_config.candidate'
    [IO.File]::WriteAllText($candidate, $Text, (New-Object Text.UTF8Encoding($false)))
    & $script:sshd -t -f $candidate 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw (Get-LsbText '候选 SSH 配置未通过校验。' 'Candidate SSH configuration did not validate.') }
    # Re-check after validation, before writing; do not overwrite concurrent changes.
    if ($script:receipt.AfterHash -and -not (Test-Path -LiteralPath $script:receipt.Config)) { throw 'SSH configuration disappeared concurrently.' }
    if ((Test-Path -LiteralPath $script:receipt.Config) -and (Get-Sha256 $script:receipt.Config) -ne $script:receipt.AfterHash) { throw 'SSH configuration changed concurrently.' }
    [IO.File]::WriteAllText($script:receipt.Config, $Text, (New-Object Text.UTF8Encoding($false)))
    $script:receipt.AfterHash = Get-Sha256 $script:receipt.Config
    Save-Receipt
}
function Wait-Decision([string]$Expected) {
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    Write-Host (Get-LsbText '请保持窗口打开，等待 Mac 操作者验证连接。' 'Keep this window open while the Mac operator verifies the connection.')
    while ([DateTime]::UtcNow -lt $deadline) {
        $decision = (Request-Session '/decision').decision
        if ($decision -eq $Expected) { return }
        if ($decision -eq 'abort') { throw (Get-LsbText 'Mac 操作者取消了本次验证。' 'Verification was cancelled on the Mac.') }
        Start-Sleep -Seconds 2
    }
    throw (Get-LsbText '等待 Mac 验证超时。' 'Timed out waiting for Mac verification.')
}
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw (Get-LsbText '请在管理员 Windows PowerShell 中运行。' 'Run this command in administrator Windows PowerShell.') }
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1' -or $Host.Name -ne 'ConsoleHost') { throw 'Use Windows PowerShell 5.1, not PowerShell 7 or ISE.' }
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    if ([int]$os.BuildNumber -lt 17763 -or $os.ProductType -ne 1 -or $cpu.Architecture -ne 9 -or -not [Environment]::Is64BitProcess) { throw (Get-LsbText '首版仅支持 Windows 10 1809 起及 Windows 11 的 x64 系统和 64 位 PowerShell。' 'This version requires x64 Windows 10 1809 or later / Windows 11, with 64-bit Windows PowerShell.') }
    Send-Stage 'checking'
    $desktop = (Get-CimInstance Win32_ComputerSystem).UserName
    $defaultUser = ''
    if ($desktop -and $desktop.Split('\')[0] -ieq $env:COMPUTERNAME) { $defaultUser = $desktop.Split('\')[-1] }
    $name = Read-Host ((Get-LsbText '授权的现有本地账户，回车使用' 'Existing local account to authorize; Enter uses') + " [$defaultUser]")
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $defaultUser }
    $account = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object { $_.Name -ieq $name -and -not $_.Disabled })
    if ($account.Count -ne 1 -or $name -match '[\x00-\x1f"\\/\[\]:;|=,+*?<>@]') { throw (Get-LsbText '找不到唯一、已启用的现有本地账户。' 'No unique enabled local account was found.') }
    $account = $account[0]
    $allowed = Read-Host ((Get-LsbText '防火墙允许地址，可填写更小网段或逗号分隔的 IPv4，默认' 'Allowed firewall addresses: a narrower subnet or comma-separated IPv4 addresses; default') + " [$($BootstrapConfig.network)]")
    if ([string]::IsNullOrWhiteSpace($allowed)) { $allowed = $BootstrapConfig.network }
    $allowed = (@($allowed.Split(',') | ForEach-Object { $_.Trim() }) -join ',')
    if (-not (Test-NarrowerScope $allowed $BootstrapConfig.network)) { throw (Get-LsbText '地址范围必须位于默认局域网网段内。' 'Allowed addresses must be within the selected local subnet.') }
    if (@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count) { throw (Get-LsbText 'Windows 防火墙存在未启用的配置文件，无法保证网段限制。请先由管理员检查防火墙。' 'A Windows Firewall profile is disabled; the subnet restriction cannot be guaranteed. Ask the administrator to review firewall settings first.') }
    $old = Get-CimInstance Win32_Service -Filter "Name='sshd'"
    $fresh = $null -eq $old
    $config = Join-Path $env:ProgramData 'ssh\sshd_config'
    $lockDownPassword = $fresh -and -not (Test-Path -LiteralPath $config)
    if ($fresh -and (Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue)) { throw 'Port 22 is already in use by another service; no installation was started.' }
    if ($fresh -and ((Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'OpenSSH\sshd.exe')) -or (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe')))) { throw 'An existing sshd binary has no registered service. Resolve this installation manually before continuing.' }
    $script:sshd = $null
    $port = 22
    $effectivePaths = @('.ssh/authorized_keys')
    $original = ''
    if (-not $fresh) {
        $binPath = [Environment]::ExpandEnvironmentVariables($old.PathName).Trim()
        if ($binPath -match '^"([^"]+sshd\.exe)"\s*$') { $script:sshd = $Matches[1] }
        elseif ($binPath -match '^([^"\r\n]+sshd\.exe)\s*$') { $script:sshd = $Matches[1].Trim() }
        else { throw (Get-LsbText '现有 sshd 使用自定义启动参数，请手工处理；未修改配置。' 'Existing sshd has custom startup arguments; manual configuration is required.') }
        if (-not (Test-Path -LiteralPath $config)) { throw 'Existing service has no default sshd_config; manual configuration required.' }
        $original = [IO.File]::ReadAllText($config)
        if ($original -match '(?im)^\s*Include\s+') { throw 'Existing Include directives require manual configuration.' }
        $effective = @(& $script:sshd -T -C "user=$($account.Name.ToLowerInvariant()),host=localhost,addr=$(([Uri]$BootstrapConfig.base).Host)" 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect existing sshd configuration.' }
        $ports = @($effective | Where-Object { $_ -match '^port \d+$' })
        if ($ports.Count -ne 1) { throw 'Multiple SSH ports require manual configuration.' }
        $port = [int]($ports[0].ToString().Split(' ')[1])
        $keyLine = @($effective | Where-Object { $_ -match '^authorizedkeysfile ' })
        if ($keyLine.Count -ne 1) { throw 'Cannot inspect AuthorizedKeysFile.' }
        $effectivePaths = @(Get-KeyFileTokens $keyLine[0].ToString().Substring(19))
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $keyId = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($BootstrapConfig.publicKey)))).Replace('-', '').ToLowerInvariant().Substring(0, 24) } finally { $sha.Dispose() }
    $keyPath = Join-Path $env:ProgramData ("lan-ssh-bootstrap\keys\" + $account.SID + '-' + $keyId)
    $ruleName = 'LAN-SSH-Bootstrap-' + $account.SID + '-' + $port
    $rules = @(Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)
    if ($rules.Count -gt 1) { throw 'Multiple firewall rules have the managed name; manual review is required.' }
    $rule = $null
    if ($rules.Count -eq 1) { $rule = $rules[0] }
    if ($rule) {
        $filter = $rule | Get-NetFirewallPortFilter
        if ($rule.Description -ne 'Managed by lan-ssh-bootstrap; selected local subnet only' -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or $filter.Protocol -ne 'TCP' -or $filter.LocalPort -ne "$port") { throw 'The existing named firewall rule is not a matching managed SSH rule.' }
    }
    if ($rule -and ((Get-ScopeSignature (@($rule | Get-NetFirewallAddressFilter).RemoteAddress -join ',')) -ne (Get-ScopeSignature $allowed) -or $rule.Enabled -ne 'True')) {
        throw (Get-LsbText '已有本工具规则的范围或启用状态不同，请先手工处理；本次未改动它。' 'An existing managed firewall rule has a different scope or is disabled; resolve it manually first.')
    }
    Write-Host "`nLAN SSH Bootstrap — $($os.Caption) / $($os.BuildNumber) / x64"
    Write-Host ((Get-LsbText '账户 / SID：' 'Account / SID: ') + $account.Caption + ' / ' + $account.SID)
    Write-Host ((Get-LsbText '安装：' 'Installation: ') + $(if ($fresh) { $BootstrapConfig.version + ' (Preview)' } else { (Get-LsbText '复用现有安装，不升级' 'reuse existing installation; no upgrade') }))
    Write-Host ((Get-LsbText '将配置：' 'Will configure: ') + "sshd Automatic / TCP $port / $allowed / public key")
    Write-Host (Get-LsbText '新增公钥文件仅针对所选账户，已有公钥来源会保留。' 'The new public-key file is scoped to the selected account; existing key sources are preserved.')
    if ($lockDownPassword) { Write-Host (Get-LsbText '本次认证策略：公钥验证成功后关闭密码及 keyboard-interactive 登录。' 'Authentication policy for this run: disable password and keyboard-interactive login after public-key verification.') }
    else { Write-Host (Get-LsbText '本次认证策略：保留已有配置中的认证策略。' 'Authentication policy for this run: preserve the existing policy.') }
    Write-Host (Get-LsbText '应用配置可能重启 sshd，断开已有 SSH 会话。当前为尚未完成实机验收的开发版本。' 'Applying configuration may restart sshd and disconnect existing SSH sessions. This development version has not completed real-device acceptance.')
    Write-Host (Get-LsbText '局域网限制只适用于本工具新增的规则；既有防火墙放行不会自动收窄。' 'The local-subnet restriction applies to the managed rule only; existing firewall allowances are not automatically narrowed.')
    $portRules = @(Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq "$port" } | Get-NetFirewallRule | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' })
    if ($portRules.Count) { Write-Host (Get-LsbText '注意：已有端口放行规则会保留。新增局域网规则不会收窄其他规则授予的访问。' 'Existing port allow rules are retained. Adding a local-subnet rule does not narrow access granted by other rules.') }
    $answer = Read-Host (Get-LsbText '确认应用以上变更？输入 yes，其他输入退出' 'Apply these changes? Type yes; anything else exits')
    if ($answer -cne 'yes') { Send-Stage 'cancelled'; return }
    $script:stateDir = Join-Path $env:ProgramData ('lan-ssh-bootstrap\sessions\' + $script:attempt)
    New-Item -ItemType Directory -Path $script:stateDir -Force | Out-Null
    & icacls.exe $script:stateDir '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' '/q' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot protect recovery directory.' }
    $script:receipt = [ordered]@{ Config=$config; HadConfig=(Test-Path -LiteralPath $config); AfterHash=$null; Fresh=$fresh; StartMode='Disabled'; WasRunning=$false; CreatedRule=$false; RuleName=$ruleName; Allowed=$allowed; DisabledRules=@(); CreatedKey=$false; KeyPath=$keyPath; KeyHash=$null; BlockRule=$null; InstallerPID=$null; InstallerStarted=$null; OwnedFreshService=$false; ServiceTouched=$false; ServicePID=$null }
    if ($old) { $script:receipt.StartMode=$old.StartMode; $script:receipt.WasRunning=$old.State -eq 'Running' }
    if ($script:receipt.HadConfig) { Copy-Item -LiteralPath $config -Destination (Join-Path $script:stateDir 'sshd_config.before'); $script:receipt.AfterHash=Get-Sha256 $config }
    Save-Receipt
    $restoreBytes = [Convert]::FromBase64String($BootstrapConfig.restore)
    [IO.File]::WriteAllBytes((Join-Path $script:stateDir 'restore.ps1'), $restoreBytes)
    Write-Host ((Get-LsbText '恢复命令：' 'Recovery command: ') + "powershell.exe -ExecutionPolicy Bypass -File `"$script:stateDir\restore.ps1`"")
    if ($fresh) {
        Send-Stage 'installing'
        $msi = Join-Path $script:stateDir 'OpenSSH-Win64.msi'
        $client = New-Object Net.WebClient
        $client.Proxy = $null
        try { $client.DownloadFile($BootstrapConfig.base + '/OpenSSH-Win64.msi', $msi) } finally { $client.Dispose() }
        if ((Get-Sha256 $msi) -ne $BootstrapConfig.sha256) { throw 'Installer SHA256 mismatch; installation stopped.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $msi
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne 'Microsoft Corporation') { throw 'Installer must have a valid Microsoft Corporation Authenticode signature.' }
        $script:receipt.BlockRule = 'LAN-SSH-Bootstrap-Installing-' + $script:attempt
        Save-Receipt
        New-NetFirewallRule -Name $script:receipt.BlockRule -DisplayName 'LAN SSH Bootstrap - installation guard' -Direction Inbound -Action Block -Protocol TCP -LocalPort 22 -Profile Any | Out-Null
        Save-Receipt
        $beforeRules = @(Get-NetFirewallRule | Select-Object -ExpandProperty Name)
        if (Get-Service sshd -ErrorAction SilentlyContinue) { throw 'An SSH service appeared after preflight. Installation stopped for manual review.' }
        $process = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $msi + '"'), 'ADDLOCAL=Server', '/qn', '/norestart', '/l*v', ('"' + (Join-Path $script:stateDir 'install.log') + '"')) -PassThru
        $script:receipt.InstallerPID=$process.Id; $script:receipt.InstallerStarted=$process.StartTime.ToUniversalTime().ToString('o'); Save-Receipt
        if (-not $process.WaitForExit(300000)) { throw (Get-LsbText '安装超过五分钟；不要重复启动安装器，请检查安装日志和任务管理器。' 'Installation exceeded five minutes; do not start another installer. Check install.log and Task Manager.') }
        $installed = Get-CimInstance Win32_Service -Filter "Name='sshd'"
        $expectedBinary = Join-Path $env:ProgramFiles 'OpenSSH\sshd.exe'
        if ($installed -and $installed.PathName.Trim('"') -ieq $expectedBinary -and $process.ExitCode -in @(0,3010)) {
            $script:receipt.OwnedFreshService=$true; Save-Receipt
            Stop-Service sshd -ErrorAction SilentlyContinue
        }
        # Other work may run concurrently. Show new SSH allow rules and obtain
        # concrete local approval instead of assuming every new rule is ours.
        $newAllowRules = @(Get-NetFirewallRule | Where-Object { $_.Name -notin $beforeRules -and $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' } | Where-Object {
            $filter = $_ | Get-NetFirewallPortFilter
            $application = $_ | Get-NetFirewallApplicationFilter
            $filter.LocalPort -eq '22' -or $application.Program -match '[\\/]sshd\.exe$'
        })
        if ($newAllowRules.Count) {
            $newAllowRules | Select-Object Name, DisplayName | Format-Table | Out-Host
            $approveRules = Read-Host (Get-LsbText '安装期间出现以上 SSH 放行规则。输入 yes 禁用它们并改用已选局域网规则，其他输入中止' 'These SSH allow rules appeared during installation. Type yes to disable them and use the selected local scope; anything else aborts')
            if ($approveRules -cne 'yes') { throw 'New SSH firewall rules require manual review.' }
            foreach ($newRule in $newAllowRules) {
                $script:receipt.DisabledRules += [ordered]@{ Name=$newRule.Name; Signature=(Get-LsbRuleSignature $newRule) }
                Save-Receipt
                $newRule | Disable-NetFirewallRule
            }
        }
        if ($process.ExitCode -ne 0) { throw "Installer exit code $($process.ExitCode). No automatic reboot will occur." }
        if (-not $installed) { throw 'Installer did not create sshd.' }
        $script:sshd = Join-Path $env:ProgramFiles 'OpenSSH\sshd.exe'
        if (-not (Test-Path -LiteralPath $script:sshd)) { throw 'Unexpected OpenSSH installation path.' }
        if (-not (Test-Path -LiteralPath $config)) {
            New-Item -ItemType Directory -Path (Split-Path $config) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path (Split-Path $script:sshd) 'sshd_config_default') -Destination $config
        }
        if ($script:receipt.HadConfig -and (Get-Sha256 $config) -ne $script:receipt.AfterHash) { throw 'Existing SSH configuration changed during installation; overwrite refused.' }
        if (-not $script:receipt.HadConfig -and (Get-Sha256 $config) -ne (Get-Sha256 (Join-Path (Split-Path $script:sshd) 'sshd_config_default'))) { throw 'A customized SSH configuration appeared during installation; manual review is required.' }
        $original = [IO.File]::ReadAllText($config)
        $script:receipt.AfterHash = Get-Sha256 $config; Save-Receipt
    }
    Send-Stage 'configuring'
    $keygen = Join-Path (Split-Path $script:sshd) 'ssh-keygen.exe'
    & $keygen -A | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Host key generation failed.' }
    if ($fresh) {
        $effective = @(& $script:sshd -T -C "user=$($account.Name.ToLowerInvariant()),host=localhost,addr=$(([Uri]$BootstrapConfig.base).Host)" 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect newly installed sshd configuration.' }
        $keyLine = @($effective | Where-Object { $_ -match '^authorizedkeysfile ' })
        if ($keyLine.Count -ne 1) { throw 'Cannot inspect AuthorizedKeysFile.' }
        $effectivePaths = @(Get-KeyFileTokens $keyLine[0].ToString().Substring(19))
    }
    $keyDirectory = Split-Path $keyPath
    if (-not (Test-Path -LiteralPath $keyDirectory)) {
        New-Item -ItemType Directory -Path $keyDirectory -Force | Out-Null
        & icacls.exe $keyDirectory '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-32-545:(OI)(CI)(RX)' '/q' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot protect the public-key directory.' }
    }
    $keyText = $BootstrapConfig.publicKey + "`r`n"
    if (Test-Path -LiteralPath $keyPath) {
        if ([IO.File]::ReadAllText($keyPath).Trim() -ne $BootstrapConfig.publicKey) { throw 'Managed key file already exists with different content.' }
    } else {
        [IO.File]::WriteAllText($keyPath, $keyText, (New-Object Text.UTF8Encoding($false)))
        $script:receipt.CreatedKey=$true; $script:receipt.KeyHash=Get-Sha256 $keyPath; Save-Receipt
        & icacls.exe $keyPath '/inheritance:r' '/grant:r' ('*' + $account.SID + ':(R)') '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' '/q' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Public key ACL setup failed.' }
        & icacls.exe $keyPath '/setowner' ('*' + $account.SID) '/q' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Public key ownership setup failed.' }
    }
    $configured = Add-AccountKeySource $original $account.Name $account.SID $effectivePaths $keyPath.Replace('\','/')
    Write-Config $configured
    if (-not $rule) {
        New-NetFirewallRule -Name $ruleName -DisplayName ('LAN SSH Bootstrap - ' + $account.Name) -Description 'Managed by lan-ssh-bootstrap; selected local subnet only' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress $allowed.Split(',') -Profile Any | Out-Null
        $script:receipt.CreatedRule=$true
        $script:receipt.Allowed = (@(Get-NetFirewallRule -Name $ruleName | Get-NetFirewallAddressFilter).RemoteAddress -join ',')
        Save-Receipt
    }
    $script:receipt.ServiceTouched=$true; Save-Receipt
    Set-Service sshd -StartupType Automatic
    if ((Get-Service sshd).Status -eq 'Running') { Restart-Service sshd } else { Start-Service sshd }
    $script:receipt.ServicePID=(Get-CimInstance Win32_Service -Filter "Name='sshd'").ProcessId; Save-Receipt
    if ($script:receipt.BlockRule) { Remove-NetFirewallRule -Name $script:receipt.BlockRule; $script:receipt.BlockRule=$null; Save-Receipt }
    $hostKeyPath = @('ssh_host_ed25519_key.pub','ssh_host_rsa_key.pub','ssh_host_ecdsa_key.pub') | ForEach-Object { Join-Path $env:ProgramData ('ssh\' + $_) } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $hostKeyPath) { throw 'Cannot find a supported host public key.' }
    $parts = [IO.File]::ReadAllText($hostKeyPath).Trim() -split '\s+'
    $identity = @{ User=$account.Name.ToLowerInvariant(); Sid=$account.SID; HostKey=($parts[0..1] -join ' '); Port=$port }
    Write-Host (Get-LsbText '请将以下主机指纹与 Mac 显示的指纹核对：' 'Compare this host fingerprint with the fingerprint shown on the Mac:')
    & $keygen -lf $hostKeyPath -E sha256 | Out-Host
    Send-Stage 'ready' $identity
    Wait-Decision 'verify-pass'
    if ($lockDownPassword) {
        Write-Config (Set-KeyOnlyAuthentication ([IO.File]::ReadAllText($config)))
        $finalPolicy = @(& $script:sshd -T -C "user=$($account.Name.ToLowerInvariant()),host=localhost,addr=$(([Uri]$BootstrapConfig.base).Host)" 2>&1)
        if ($LASTEXITCODE -ne 0 -or 'passwordauthentication no' -notin $finalPolicy -or 'kbdinteractiveauthentication no' -notin $finalPolicy) { throw 'Key-only authentication policy did not become effective.' }
        Restart-Service sshd
        $script:receipt.ServicePID=(Get-CimInstance Win32_Service -Filter "Name='sshd'").ProcessId; Save-Receipt
    }
    Send-Stage 'ready-final' $identity
    Wait-Decision 'finish'
    Send-Stage 'complete' $identity
    Write-Host (Get-LsbText '配置完成，Mac 已验证实际公钥登录。可关闭此窗口。' 'Setup complete. The Mac verified real public-key login. You may close this window.')
} catch {
    Write-Host (Get-LsbText '配置未完成：' 'Setup did not complete:') -ForegroundColor Red
    Write-Host $_.Exception.Message
    if ($script:stateDir -and (Test-Path -LiteralPath (Join-Path $script:stateDir 'restore.ps1'))) {
        try { & (Join-Path $script:stateDir 'restore.ps1') } catch { Write-Host ('Recovery requires manual review: ' + $_.Exception.Message) -ForegroundColor Red }
    }
    try { Send-Stage 'failed' } catch { Write-Host (Get-LsbText '无法向 Mac 回传结果，请保留当前窗口中的提示。' 'Could not report back to the Mac. Keep the messages in this window.') }
}

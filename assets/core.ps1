# Pure configuration helpers, compatible with Windows PowerShell 5.1.
function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-LsbRuleSignature($Rule) {
    $port = $Rule | Get-NetFirewallPortFilter
    $address = $Rule | Get-NetFirewallAddressFilter
    $application = $Rule | Get-NetFirewallApplicationFilter
    $service = $Rule | Get-NetFirewallServiceFilter
    [ordered]@{ Name=$Rule.Name; Description=$Rule.Description; Direction=[string]$Rule.Direction; Action=[string]$Rule.Action; Profile=[string]$Rule.Profile; Protocol=[string]$port.Protocol; LocalPort=(@($port.LocalPort) -join ','); RemotePort=(@($port.RemotePort) -join ','); LocalAddress=(@($address.LocalAddress) -join ','); RemoteAddress=(@($address.RemoteAddress) -join ','); Program=$application.Program; Service=$service.Service } | ConvertTo-Json -Compress
}

function ConvertTo-SshToken([string]$Value) {
    if ($Value -match '[\r\n\x00"]') { throw 'Invalid SSH configuration token' }
    '"' + $Value.Replace('\', '/') + '"'
}

function Get-KeyFileTokens([string]$EffectiveValue) {
    # sshd -T does not reliably retain quoting around paths containing spaces.
    # Refuse ambiguous custom paths rather than accidentally remove an old key source.
    $tokens = @($EffectiveValue.Trim() -split '\s+')
    foreach ($token in $tokens) {
        if ($token -notmatch '^(?:\.ssh[/\\]|__PROGRAMDATA__[/\\]|%h[/\\]|[A-Za-z]:[/\\]|/)' -or $token -match '["\r\n]') {
            throw 'Existing AuthorizedKeysFile is complex; configure it manually before continuing.'
        }
    }
    $tokens
}

function Add-AccountKeySource([string]$Text, [string]$UserName, [string]$Sid, [string[]]$ExistingPaths, [string]$KeyPath) {
    if ($UserName -match '[\x00-\x1f"\\/\[\]:;|=,+*?<>@]' -or $UserName.Length -eq 0) { throw 'Unsupported local account name' }
    if ($Sid -notmatch '^S-1-5-21-(?:\d+-){3}\d+$') { throw 'Invalid local account SID' }
    $begin = '# BEGIN LAN-SSH-BOOTSTRAP ' + $Sid
    $end = '# END LAN-SSH-BOOTSTRAP ' + $Sid
    $beginCount = [regex]::Matches($Text, '(?m)^' + [regex]::Escape($begin) + '\r?$').Count
    $endCount = [regex]::Matches($Text, '(?m)^' + [regex]::Escape($end) + '\r?$').Count
    if ($beginCount -ne $endCount -or $beginCount -gt 1) { throw 'Damaged managed SSH block' }
    if ($beginCount -eq 1) {
        $Text = [regex]::Replace($Text, '(?ms)^' + [regex]::Escape($begin) + '\r?\n.*?^' + [regex]::Escape($end) + '\r?\n?', '')
    }
    $paths = @()
    foreach ($path in (@($ExistingPaths) + @($KeyPath))) { if ($paths -notcontains $path) { $paths += $path } }
    $quotedPaths = @($paths | ForEach-Object { ConvertTo-SshToken $_ }) -join ' '
    $block = "$begin`r`nMatch User $(ConvertTo-SshToken $UserName.ToLowerInvariant())`r`n    AuthorizedKeysFile $quotedPaths`r`nMatch all`r`n$end`r`n"
    # Insert after all global-only options, before the first existing Match block.
    $firstMatch = [regex]::Match($Text, '(?im)^[ \t]*Match[ \t]+')
    $firstManaged = [regex]::Match($Text, '(?m)^# BEGIN LAN-SSH-BOOTSTRAP ')
    if ($firstMatch.Success) {
        $offset = $firstMatch.Index
        if ($firstManaged.Success -and $firstManaged.Index -lt $offset) { $offset = $firstManaged.Index }
        return $Text.Substring(0, $offset).TrimEnd() + "`r`n`r`n" + $block + $Text.Substring($offset)
    }
    $Text.TrimEnd() + "`r`n`r`n" + $block
}

function Set-KeyOnlyAuthentication([string]$Text) {
    $firstMatch = [regex]::Match($Text, '(?im)^[ \t]*Match[ \t]+')
    $offset = $Text.Length
    if ($firstMatch.Success) { $offset = $firstMatch.Index }
    $firstManaged = [regex]::Match($Text, '(?m)^# BEGIN LAN-SSH-BOOTSTRAP ')
    if ($firstManaged.Success -and $firstManaged.Index -lt $offset) { $offset = $firstManaged.Index }
    $global = $Text.Substring(0, $offset)
    $tail = $Text.Substring($offset)
    foreach ($option in @('PasswordAuthentication', 'KbdInteractiveAuthentication', 'ChallengeResponseAuthentication')) {
        $pattern = '(?im)^[ \t]*#?[ \t]*' + $option + '[ \t]+[^\r\n]*'
        if ([regex]::IsMatch($global, $pattern)) { $global = [regex]::Replace($global, $pattern, "$option no") }
        else { $global = $global.TrimEnd() + "`r`n$option no`r`n" }
    }
    $global.TrimEnd() + "`r`n`r`n" + $tail
}

function ConvertTo-IPv4Number([string]$Address) {
    if ($Address -notmatch '^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){3}$') { throw 'Use an explicit dotted IPv4 address' }
    $ip = [Net.IPAddress]::Parse($Address)
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'IPv4 required' }
    $bytes = $ip.GetAddressBytes()
    [uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + [uint64]$bytes[3]
}

function Get-IPv4Range([string]$Cidr) {
    if ($Cidr.Contains('-')) {
        $range = $Cidr.Split('-')
        if ($range.Count -ne 2) { throw 'Invalid address range' }
        $first = ConvertTo-IPv4Number $range[0]; $last = ConvertTo-IPv4Number $range[1]
        if ($last -lt $first) { throw 'Invalid address range' }
        return [pscustomobject]@{ Start=$first; End=$last; Prefix=$null }
    }
    $parts = $Cidr.Split('/')
    if ($parts.Count -gt 2) { throw 'Invalid CIDR' }
    $prefix = 32
    if ($parts.Count -eq 2) {
        if ($parts[1] -match '^\d{1,2}$') { $prefix = [int]$parts[1] }
        else {
            $mask = [Convert]::ToString([int64](ConvertTo-IPv4Number $parts[1]),2).PadLeft(32,'0')
            if ($mask -notmatch '^1*0*$') { throw 'Non-contiguous subnet mask' }
            $prefix = $mask.TrimEnd('0').Length
        }
    }
    if ($prefix -lt 0 -or $prefix -gt 32) { throw 'Invalid prefix' }
    $n = ConvertTo-IPv4Number $parts[0]
    $size = [math]::Pow(2, 32 - $prefix)
    $start = [math]::Floor($n / $size) * $size
    [pscustomobject]@{ Start = [uint64]$start; End = [uint64]($start + $size - 1); Prefix = $prefix }
}

function Get-ScopeSignature([string]$Scope) {
    (@($Scope.Split(',') | ForEach-Object {
        $range = Get-IPv4Range $_.Trim()
        "$($range.Start)-$($range.End)"
    } | Sort-Object -Unique) -join ',')
}

function Test-NarrowerScope([string]$Allowed, [string]$Parent) {
    $outer = Get-IPv4Range $Parent
    foreach ($entry in $Allowed.Split(',')) {
        $inner = Get-IPv4Range $entry.Trim()
        if ($inner.Start -lt $outer.Start -or $inner.End -gt $outer.End) { return $false }
    }
    $true
}

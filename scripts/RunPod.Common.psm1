Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-QwenProjectRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-RunPodStateDirectory {
    $directory = Join-Path (Get-QwenProjectRoot) '.runpod'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    return $directory
}

function Get-RunPodSessionPath {
    return (Join-Path (Get-RunPodStateDirectory) 'session.json')
}

function Get-RunPodSessionForLocalCleanup {
    $path = Get-RunPodSessionPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $session = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        Write-Warning "RunPod session is unreadable; local Docker cleanup will continue without changing it: $path"
        return $null
    }
    if ($session -isnot [pscustomobject]) {
        Write-Warning "RunPod session is not a JSON object; local Docker cleanup will continue without changing it: $path"
        return $null
    }
    return $session
}

function Get-RunPodApiKeyPath {
    return (Join-Path (Get-RunPodStateDirectory) 'api-key')
}

function Get-OpenCodeWebPasswordPath {
    return (Join-Path (Get-RunPodStateDirectory) 'opencode-password')
}

function Protect-RunPodSecretFile {
    param([Parameter(Mandatory)][string]$Path)

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $currentAcl = Get-Acl -LiteralPath $Path
    $currentRules = @($currentAcl.Access)
    $alreadyProtected = $currentAcl.AreAccessRulesProtected -and
        $currentRules.Count -eq 1 -and
        $currentRules[0].IdentityReference.Value -eq $identity -and
        $currentRules[0].AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
        (($currentRules[0].FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
            [System.Security.AccessControl.FileSystemRights]::FullControl)
    if ($alreadyProtected) {
        return
    }

    # Build a fresh DACL instead of modifying the FileSecurity object returned
    # by Get-Acl. Windows PowerShell can request SeSecurityPrivilege when an
    # already protected ACL is written again, so the exact desired state above
    # is deliberately treated as a no-op.
    $acl = New-Object -TypeName System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $accessRule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($accessRule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function New-RunPodApiKey {
    $path = Get-RunPodApiKeyPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $bytes = New-Object byte[] 32
        $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $generator.GetBytes($bytes)
        }
        finally {
            $generator.Dispose()
        }
        $key = ([Convert]::ToBase64String($bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        Set-Content -LiteralPath $path -Value $key -NoNewline -Encoding ascii
        Protect-RunPodSecretFile -Path $path
    }
    return $path
}

function New-OpenCodeWebPassword {
    $path = Get-OpenCodeWebPasswordPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $bytes = New-Object byte[] 32
        $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $generator.GetBytes($bytes)
        }
        finally {
            $generator.Dispose()
        }
        $password = ([Convert]::ToBase64String($bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        Set-Content -LiteralPath $path -Value $password -NoNewline -Encoding ascii
        Protect-RunPodSecretFile -Path $path
    }
    return $path
}

function Get-RunPodApiKey {
    $path = Get-RunPodApiKeyPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "RunPod API key missing: $path. Run scripts/runpod-deploy.ps1 first."
    }
    $value = (Get-Content -LiteralPath $path -Raw -Encoding ascii).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "RunPod API key is empty: $path"
    }
    return $value
}

function Save-RunPodSession {
    param([Parameter(Mandatory)]$Session)

    $path = Get-RunPodSessionPath
    $temporaryPath = "$path.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    $backupPath = "$path.previous"
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($temporaryPath, ($Session | ConvertTo-Json -Depth 8), $utf8)
        Protect-RunPodSecretFile -Path $temporaryPath
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            [IO.File]::Replace($temporaryPath, $path, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        else {
            [IO.File]::Move($temporaryPath, $path)
        }
        Protect-RunPodSecretFile -Path $path
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-RunPodSession {
    $path = Get-RunPodSessionPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "RunPod session missing: $path. Run scripts/runpod-deploy.ps1 first."
    }
    $session = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-RunPodQualifiedSession -Session $session
    return $session
}

function Get-RunPodModel {
    param([Parameter(Mandatory)][ValidateSet('uncensored-q6', 'uncensored-q8', 'uncensored-q4', 'whitehat-q4')][string]$Model)

    $manifestPath = Join-Path (Get-QwenProjectRoot) 'config\models.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $record = @($manifest.models | Where-Object { $_.id -eq $Model })
    if ($record.Count -ne 1) {
        throw "Model '$Model' is missing or duplicated in $manifestPath."
    }
    return $record[0]
}

function Write-OpenCodeRuntimeConfig {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('uncensored-q6', 'uncensored-q8', 'uncensored-q4', 'whitehat-q4')]
        [string]$ActiveModel
    )

    $projectRoot = Get-QwenProjectRoot
    $manifestPath = Join-Path $projectRoot 'config\models.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $knownModelIds = @($manifest.models | ForEach-Object { [string]$_.id })
    if ($knownModelIds -notcontains $ActiveModel) {
        throw "Active model '$ActiveModel' is missing from $manifestPath."
    }
    $interactiveOpenCodeModel = 'uncensored-q6-interactive-v1'
    $activeOpenCodeModel = if ($ActiveModel -eq 'uncensored-q6') {
        $interactiveOpenCodeModel
    }
    else {
        $ActiveModel
    }
    $modelOverrides = [ordered]@{}
    foreach ($modelId in $knownModelIds) {
        $modelOverrides[$modelId] = [ordered]@{
            disabled = ($modelId -ne $activeOpenCodeModel)
        }
    }
    $modelOverrides[$interactiveOpenCodeModel] = [ordered]@{
        disabled = ($activeOpenCodeModel -ne $interactiveOpenCodeModel)
    }
    $runtimeConfig = [ordered]@{
        '$schema' = 'https://opencode.ai/config.json'
        model = "runpod/$activeOpenCodeModel"
        agents = [ordered]@{
            build = [ordered]@{
                model = "runpod/$activeOpenCodeModel"
            }
        }
        providers = [ordered]@{
            runpod = [ordered]@{
                models = $modelOverrides
            }
        }
    }
    $runtimeConfigDirectory = Join-Path $projectRoot '.opencode'
    $runtimeConfigPath = Join-Path $runtimeConfigDirectory 'opencode.json'
    [IO.Directory]::CreateDirectory($runtimeConfigDirectory) | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($runtimeConfigPath, ($runtimeConfig | ConvertTo-Json -Depth 6), $utf8)
    return [pscustomobject]@{
        Path = $runtimeConfigPath
        ActiveOpenCodeModel = $activeOpenCodeModel
        Config = $runtimeConfig
    }
}

function Assert-RunPodSession {
    param([Parameter(Mandatory)]$Session)

    if ($Session.SshHost -notmatch '^[A-Za-z0-9.-]+$') {
        throw "Unsafe SSH host in session: $($Session.SshHost)"
    }
    if ([int]$Session.SshPort -lt 1 -or [int]$Session.SshPort -gt 65535) {
        throw "Invalid SSH port in session: $($Session.SshPort)"
    }
    if ($Session.SshUser -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
        throw "Unsafe SSH user in session: $($Session.SshUser)"
    }
    if ($Session.RemoteDir -notmatch '^/workspace/[A-Za-z0-9_-]+(?:/[A-Za-z0-9._-]+)*$' -or @($Session.RemoteDir -split '/') -contains '..') {
        throw "Unsafe remote directory in session: $($Session.RemoteDir)"
    }
    if (-not (Test-Path -LiteralPath $Session.IdentityFile -PathType Leaf)) {
        throw "SSH identity file missing: $($Session.IdentityFile)"
    }
}

function Assert-RunPodQualifiedSession {
    param([Parameter(Mandatory)]$Session)

    Assert-RunPodSession -Session $Session
    $requiredProperties = @(
        'PodId',
        'DeploymentId',
        'DeploymentProfileId',
        'DeploymentPlanSha256',
        'LifecycleStatus',
        'GpuName',
        'GpuCount',
        'GpuMemoryMiB',
        'ComputeCapability',
        'CudaRelease',
        'LlamaBuildInfo'
    )
    foreach ($property in $requiredProperties) {
        if ($Session.PSObject.Properties.Name -notcontains $property) {
            throw "RunPod session is stale and lacks deployment binding '$property'. Prepare and execute a qualified deployment."
        }
    }
    if (
        [string]$Session.PodId -notmatch '^[a-z0-9]{8,32}$' -or
        [string]$Session.DeploymentId -notmatch '^a100-pcie-[a-z0-9-]{8,80}$' -or
        [string]$Session.DeploymentProfileId -ne 'a100-pcie-80gb-q6-v1' -or
        [string]$Session.DeploymentPlanSha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]$Session.LifecycleStatus -ne 'ready' -or
        [string]$Session.GpuName -ne 'NVIDIA A100 80GB PCIe' -or
        [int]$Session.GpuCount -ne 1 -or
        [int64]$Session.GpuMemoryMiB -lt 80000 -or
        [string]$Session.ComputeCapability -ne '8.0' -or
        [string]$Session.CudaRelease -ne '12.4' -or
        [string]$Session.LlamaBuildInfo -ne 'b1-bb4caa754'
    ) {
        throw 'RunPod session does not match the qualified A100 PCIe deployment contract.'
    }
}

function Get-RunPodSshArguments {
    param([Parameter(Mandatory)]$Session)

    Assert-RunPodSession -Session $Session
    return @(
        '-p', [string]$Session.SshPort,
        '-i', [string]$Session.IdentityFile,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=10',
        '-o', 'ServerAliveCountMax=2'
    )
}

function ConvertTo-NativeCommandLineArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes += 1
            continue
        }
        if ($character -eq [char]'"') {
            if ($backslashes -gt 0) {
                [void]$builder.Append((('\' * ($backslashes * 2)) -join ''))
            }
            [void]$builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append((('\' * $backslashes) -join ''))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append((('\' * ($backslashes * 2)) -join ''))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-BoundedNativeProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 300)][int]$TimeoutSeconds
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (@(
        $Arguments | ForEach-Object { ConvertTo-NativeCommandLineArgument -Value ([string]$_) }
    ) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Native process did not start.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
            catch {
                # The exact process may already have exited at the timeout
                # boundary. Never target a name, process group, or other PID.
            }
            throw "Native process exceeded the local $TimeoutSeconds-second timeout."
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Native process failed with exit code $($process.ExitCode)."
        }
        if ([string]::IsNullOrWhiteSpace($stdout)) {
            return @()
        }
        return @($stdout.TrimEnd("`r", "`n") -split "`r?`n")
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-RunPodSshBounded {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 40
    )

    $arguments = @(Get-RunPodSshArguments -Session $Session)
    $arguments += "$($Session.SshUser)@$($Session.SshHost)"
    $arguments += $RemoteCommand
    $sshPath = (Get-Command ssh.exe -ErrorAction Stop).Source
    return Invoke-BoundedNativeProcess `
        -FilePath $sshPath `
        -Arguments $arguments `
        -TimeoutSeconds $TimeoutSeconds
}

function Invoke-RunPodSsh {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$RemoteCommand
    )

    $arguments = @(Get-RunPodSshArguments -Session $Session)
    $arguments += "$($Session.SshUser)@$($Session.SshHost)"
    $arguments += $RemoteCommand
    & ssh.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed with exit code $LASTEXITCODE."
    }
}

function Copy-RunPodItem {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemotePath,
        [switch]$Recurse
    )

    Assert-RunPodSession -Session $Session
    if (-not (Test-Path -LiteralPath $LocalPath)) {
        throw "Local upload path missing: $LocalPath"
    }
    $arguments = @(
        '-P', [string]$Session.SshPort,
        '-i', [string]$Session.IdentityFile,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=accept-new'
    )
    if ($Recurse) {
        $arguments += '-r'
    }
    $arguments += $LocalPath
    $arguments += "$($Session.SshUser)@$($Session.SshHost):$RemotePath"
    & scp.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "SCP upload failed with exit code $LASTEXITCODE."
    }
}

function Test-RunPodTunnelProcess {
    param([Parameter(Mandatory)]$Session)

    if ($Session.PSObject.Properties.Name -notcontains 'TunnelPid' -or -not $Session.TunnelPid) {
        return $false
    }
    try {
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$Session.TunnelPid)" -ErrorAction Stop
    }
    catch {
        return $false
    }
    if ($null -eq $process -or $process.Name -notin @('ssh.exe', 'ssh')) {
        return $false
    }
    $commandLine = [string]$process.CommandLine
    $forward = "127.0.0.1:$($Session.LocalPort):127.0.0.1:$($Session.RemotePort)"
    $destination = "$($Session.SshUser)@$($Session.SshHost)"
    return $commandLine.Contains($forward) -and $commandLine.Contains($destination)
}

function Assert-RunPodLocalEndpointIdentity {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Models,
        [Parameter(Mandatory)]$Props
    )

    $manifestModel = Get-RunPodModel -Model ([string]$Session.ActiveModel)
    $modelIds = @($Models.data | ForEach-Object { [string]$_.id })
    $expectedModelPath = (
        ([string]$Session.RemoteDir).TrimEnd('/') + '/models/' +
        [string]$manifestModel.id + '/' + [string]$manifestModel.filename
    )
    $actualContext = [int64]$Props.default_generation_settings.n_ctx
    $manifestPath = Join-Path (Get-QwenProjectRoot) 'config\models.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (
        -not [string]::Equals([string]$Session.ActiveAlias, [string]$manifestModel.alias, [StringComparison]::Ordinal) -or
        $modelIds.Count -ne 1 -or
        -not [string]::Equals($modelIds[0], [string]$manifestModel.alias, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$Props.model_alias, [string]$manifestModel.alias, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$Props.model_ftype, [string]$manifestModel.quantization, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$Props.model_path, $expectedModelPath, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$Props.build_info, [string]$manifest.llama_cpp.expected_build_info, [StringComparison]::Ordinal) -or
        $actualContext -ne [int64]$manifestModel.context_size
    ) {
        throw [IO.InvalidDataException]::new(
            'The local endpoint does not match the pinned model, quantization, build, path, and context contract.'
        )
    }
}

function Wait-RunPodLocalEndpoint {
    param(
        [Parameter(Mandatory)]$Session,
        [int]$TimeoutSeconds = 120
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$($Session.LocalPort)/health" -TimeoutSec 3
            if ($health.status -eq 'ok') {
                $headers = @{ Authorization = "Bearer $(Get-RunPodApiKey)" }
                $models = Invoke-RestMethod -Uri "http://127.0.0.1:$($Session.LocalPort)/v1/models" -Headers $headers -TimeoutSec 10
                $props = Invoke-RestMethod -Uri "http://127.0.0.1:$($Session.LocalPort)/props" -Headers $headers -TimeoutSec 10
                Assert-RunPodLocalEndpointIdentity -Session $Session -Models $models -Props $props
                return
            }
        }
        catch [IO.InvalidDataException] {
            throw
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Local RunPod endpoint did not become ready on port $($Session.LocalPort)."
}

function ConvertTo-NativeQuotedArgument {
    param([Parameter(Mandatory)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-RunPodTunnel {
    param([Parameter(Mandatory)]$Session)

    Assert-RunPodSession -Session $Session
    if (Test-RunPodTunnelProcess -Session $Session) {
        Wait-RunPodLocalEndpoint -Session $Session
        return $Session
    }

    $listener = Get-NetTCPConnection -State Listen -LocalPort ([int]$Session.LocalPort) -ErrorAction SilentlyContinue
    if ($listener) {
        throw "Local port $($Session.LocalPort) is already in use by another process."
    }
    $arguments = @(
        '-N', '-T',
        '-p', [string]$Session.SshPort,
        '-i', [string]$Session.IdentityFile,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=3',
        '-L', "127.0.0.1:$($Session.LocalPort):127.0.0.1:$($Session.RemotePort)",
        "$($Session.SshUser)@$($Session.SshHost)"
    )
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-NativeQuotedArgument -Value $_ }) -join ' '
    $process = Start-Process -FilePath 'ssh.exe' -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
    $Session | Add-Member -NotePropertyName TunnelPid -NotePropertyValue $process.Id -Force
    try {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) {
            throw "SSH tunnel exited immediately with code $($process.ExitCode)."
        }
        Wait-RunPodLocalEndpoint -Session $Session
    }
    catch {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        $Session | Add-Member -NotePropertyName TunnelPid -NotePropertyValue $null -Force
        throw
    }
    return $Session
}

function Stop-RunPodTunnel {
    param([Parameter(Mandatory)]$Session)

    if (Test-RunPodTunnelProcess -Session $Session) {
        Stop-Process -Id ([int]$Session.TunnelPid) -Force
    }
    $Session | Add-Member -NotePropertyName TunnelPid -NotePropertyValue $null -Force
    Save-RunPodSession -Session $Session
}

function ConvertTo-RunPodWslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)

    $resolved = (Resolve-Path -LiteralPath $WindowsPath).Path
    if ($resolved -notmatch '^(?<drive>[A-Za-z]):\\(?<tail>.*)$') {
        throw "Only absolute Windows drive paths can be mapped into WSL: $resolved"
    }
    $drive = $Matches.drive.ToLowerInvariant()
    $tail = $Matches.tail.Replace('\', '/')
    return "/mnt/$drive/$tail"
}

function Start-RunPodWslTunnel {
    param([Parameter(Mandatory)]$Session)

    Assert-RunPodSession -Session $Session
    $knownHostsPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh\known_hosts'
    if (-not (Test-Path -LiteralPath $knownHostsPath -PathType Leaf)) {
        throw "SSH known_hosts file missing: $knownHostsPath"
    }
    $identityWsl = ConvertTo-RunPodWslPath -WindowsPath $Session.IdentityFile
    $knownHostsWsl = ConvertTo-RunPodWslPath -WindowsPath $knownHostsPath
    $projectRoot = Get-QwenProjectRoot
    & wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- bash scripts/wsl-runpod-tunnel.sh `
        start `
        ([string]$Session.SshHost) `
        ([string]$Session.SshPort) `
        ([string]$Session.SshUser) `
        $identityWsl `
        $knownHostsWsl `
        ([string]$Session.LocalPort) `
        ([string]$Session.RemotePort)
    if ($LASTEXITCODE -ne 0) {
        throw "The WSL-local RunPod tunnel failed to start (exit code $LASTEXITCODE)."
    }
}

function Stop-RunPodWslTunnel {
    param([Parameter(Mandatory)]$Session)

    Assert-RunPodSession -Session $Session
    $projectRoot = Get-QwenProjectRoot
    & wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- bash scripts/wsl-runpod-tunnel.sh `
        stop `
        ([string]$Session.SshHost) `
        ([string]$Session.SshUser) `
        ([string]$Session.LocalPort) `
        ([string]$Session.RemotePort)
    if ($LASTEXITCODE -ne 0) {
        throw "The WSL-local RunPod tunnel failed to stop (exit code $LASTEXITCODE)."
    }
}

function Get-OpenCodeDockerInspectionRecord {
    param(
        [Parameter(Mandatory)][ValidateSet('container', 'network')][string]$Kind,
        [Parameter(Mandatory)][string]$Name
    )

    $listArguments = if ($Kind -eq 'container') {
        @('container', 'ls', '--all', '--format', '{{.Names}}')
    }
    else {
        @('network', 'ls', '--format', '{{.Name}}')
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $resourceNames = @(& docker.exe @listArguments 2>$null)
        $listExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($listExitCode -ne 0) {
        throw "Docker failed to enumerate $Kind resources while checking '$Name'."
    }
    $exactMatches = @(
        $resourceNames |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ -ceq $Name }
    )
    if ($exactMatches.Count -eq 0) {
        return $null
    }
    if ($exactMatches.Count -ne 1) {
        throw "Docker returned an ambiguous $Kind name '$Name'."
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        if ($Kind -eq 'container') {
            $inspectionOutput = @(& docker.exe container inspect $Name 2>$null)
        }
        else {
            $inspectionOutput = @(& docker.exe network inspect $Name 2>$null)
        }
        $inspectionExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($inspectionExitCode -ne 0) {
        throw "Docker failed to inspect existing $Kind '$Name'."
    }
    try {
        $parsedInspection = ($inspectionOutput -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        throw "Docker returned invalid JSON while inspecting $Kind '$Name'."
    }
    if ($parsedInspection -is [Array]) {
        if ($parsedInspection.Count -ne 1) {
            throw "Docker returned an ambiguous inspection for $Kind '$Name'."
        }
        return $parsedInspection[0]
    }
    return $parsedInspection
}

function Get-OpenCodeComposeProjectLabel {
    param(
        [Parameter(Mandatory)]$Inspection,
        [Parameter(Mandatory)][ValidateSet('container', 'network')][string]$Kind
    )

    $labels = if ($Kind -eq 'container') {
        $Inspection.Config.Labels
    }
    else {
        $Inspection.Labels
    }
    if ($null -eq $labels) {
        return ''
    }
    $projectProperty = $labels.PSObject.Properties['com.docker.compose.project']
    if ($null -eq $projectProperty) {
        return ''
    }
    return ([string]$projectProperty.Value).Trim()
}

function Test-OpenCodeWebProcess {
    param([Parameter(Mandatory)]$Session)

    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
        return $false
    }
    $inspection = Get-OpenCodeDockerInspectionRecord -Kind container -Name 'qwen-eval-opencode'
    if ($null -eq $inspection) {
        return $false
    }
    return (
        (Get-OpenCodeComposeProjectLabel -Inspection $inspection -Kind container) -eq 'qwen-eval-agent' -and
        $inspection.State.Running -eq $true
    )
}

function Stop-OpenCodeWeb {
    param([AllowNull()]$Session = $null)

    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
        throw 'Docker is required to ownership-check and stop the local OpenCode stack; session state was not changed.'
    }
    if (Get-Command docker.exe -ErrorAction SilentlyContinue) {
        $containerNames = @(
            'qwen-eval-ui-proxy',
            'qwen-eval-opencode',
            'qwen-eval-model-gateway',
            'qwen-eval-controlled-web'
        )
        $networkNames = @(
            'qwen-eval-agent_agent-internal',
            'qwen-eval-agent_gateway-egress',
            'qwen-eval-agent_ui-ingress',
            'qwen-eval-agent_controlled-web-egress'
        )
        $ownedContainers = @()
        $ownedNetworks = @()

        # Preflight every exact target before deleting anything. This prevents a
        # foreign late-listed resource from causing a partial owned-stack stop.
        foreach ($containerName in $containerNames) {
            $inspection = Get-OpenCodeDockerInspectionRecord -Kind container -Name $containerName
            if ($null -eq $inspection) {
                continue
            }
            if ((Get-OpenCodeComposeProjectLabel -Inspection $inspection -Kind container) -ne 'qwen-eval-agent') {
                throw "Refusing to remove unexpected container '$containerName'."
            }
            if ([string]::IsNullOrWhiteSpace([string]$inspection.Id)) {
                throw "Docker inspection omitted the ID for container '$containerName'."
            }
            $ownedContainers += [pscustomobject]@{
                Name = $containerName
                Id = [string]$inspection.Id
            }
        }
        foreach ($networkName in $networkNames) {
            $inspection = Get-OpenCodeDockerInspectionRecord -Kind network -Name $networkName
            if ($null -eq $inspection) {
                continue
            }
            if ((Get-OpenCodeComposeProjectLabel -Inspection $inspection -Kind network) -ne 'qwen-eval-agent') {
                throw "Refusing to remove unexpected network '$networkName'."
            }
            if ([string]::IsNullOrWhiteSpace([string]$inspection.Id)) {
                throw "Docker inspection omitted the ID for network '$networkName'."
            }
            $ownedNetworks += [pscustomobject]@{
                Name = $networkName
                Id = [string]$inspection.Id
            }
        }

        foreach ($container in $ownedContainers) {
            & docker.exe container rm --force $container.Id | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to stop isolated GUI container '$($container.Name)'."
            }
        }
        foreach ($network in $ownedNetworks) {
            & docker.exe network rm $network.Id | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to remove isolated GUI network '$($network.Name)'."
            }
        }

        foreach ($containerName in $containerNames) {
            if ($null -ne (Get-OpenCodeDockerInspectionRecord -Kind container -Name $containerName)) {
                throw "Isolated GUI container '$containerName' still exists after cleanup."
            }
        }
        foreach ($networkName in $networkNames) {
            if ($null -ne (Get-OpenCodeDockerInspectionRecord -Kind network -Name $networkName)) {
                throw "Isolated GUI network '$networkName' still exists after cleanup."
            }
        }
    }
    if ($null -ne $Session) {
        $Session | Add-Member -NotePropertyName OpenCodePort -NotePropertyValue $null -Force
        $Session | Add-Member -NotePropertyName OpenCodeRuntime -NotePropertyValue $null -Force
        $Session | Add-Member -NotePropertyName OpenCodeNetworkMode -NotePropertyValue $null -Force
        Save-RunPodSession -Session $Session
    }
}

Export-ModuleMember -Function @(
    'Get-QwenProjectRoot',
    'Get-RunPodStateDirectory',
    'Get-RunPodSessionPath',
    'Get-RunPodSessionForLocalCleanup',
    'Get-RunPodApiKeyPath',
    'Get-OpenCodeWebPasswordPath',
    'Protect-RunPodSecretFile',
    'New-RunPodApiKey',
    'New-OpenCodeWebPassword',
    'Get-RunPodApiKey',
    'Save-RunPodSession',
    'Get-RunPodSession',
    'Get-RunPodModel',
    'Write-OpenCodeRuntimeConfig',
    'Assert-RunPodSession',
    'Assert-RunPodQualifiedSession',
    'Invoke-RunPodSsh',
    'Invoke-RunPodSshBounded',
    'Copy-RunPodItem',
    'Start-RunPodTunnel',
    'Stop-RunPodTunnel',
    'Start-RunPodWslTunnel',
    'Stop-RunPodWslTunnel',
    'Wait-RunPodLocalEndpoint',
    'Test-OpenCodeWebProcess',
    'Stop-OpenCodeWeb'
)

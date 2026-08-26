Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RunPodApiBase = 'https://rest.runpod.io/v1'
$script:RunPodGraphQLApiBase = 'https://api.runpod.io/graphql'

function Get-RunPodProviderApiBase {
    return $script:RunPodApiBase
}

function Get-RunPodProviderGraphQLApiBase {
    return $script:RunPodGraphQLApiBase
}

function Get-RunPodMemberValue {
    param(
        [AllowNull()][Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $InputObject) {
        return $null
    }
    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in $InputObject.Keys) {
                if ([string]::Equals([string]$key, $name, [StringComparison]::OrdinalIgnoreCase)) {
                    return $InputObject[$key]
                }
            }
        }
        $property = $InputObject.PSObject.Properties |
            Where-Object { [string]::Equals($_.Name, $name, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
        if ($null -ne $property) {
            return $property.Value
        }
    }
    return $null
}

function Get-RunPodResponseObject {
    param([AllowNull()][Parameter(Mandatory)]$Response)

    $data = Get-RunPodMemberValue -InputObject $Response -Names @('data')
    if ($null -ne $data -and $data -isnot [System.Array]) {
        $dataId = Get-RunPodMemberValue -InputObject $data -Names @('id', 'podId')
        if ($null -ne $dataId) {
            return $data
        }
    }
    $pod = Get-RunPodMemberValue -InputObject $Response -Names @('pod')
    if ($null -ne $pod) {
        return $pod
    }
    return $Response
}

function Get-RunPodResponseItems {
    param([AllowNull()][Parameter(Mandatory)]$Response)

    if ($Response -is [System.Array]) {
        return @($Response)
    }
    foreach ($name in @('data', 'gpuTypes', 'items', 'pods')) {
        $candidate = Get-RunPodMemberValue -InputObject $Response -Names @($name)
        if ($candidate -is [System.Array]) {
            return @($candidate)
        }
        if ($null -ne $candidate) {
            $nested = Get-RunPodMemberValue -InputObject $candidate -Names @('gpuTypes', 'items', 'pods')
            if ($nested -is [System.Array]) {
                return @($nested)
            }
            if ($null -ne $nested) {
                $nestedId = Get-RunPodMemberValue -InputObject $nested -Names @('id', 'podId', 'gpuTypeId')
                if ($null -ne $nestedId) {
                    return @($nested)
                }
            }
            $candidateId = Get-RunPodMemberValue -InputObject $candidate -Names @('id', 'podId', 'gpuTypeId')
            if ($null -ne $candidateId) {
                return @($candidate)
            }
        }
    }
    return @()
}

function Invoke-RunPodRestRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][ValidatePattern('^/[A-Za-z0-9_./-]+$')][string]$Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiKey,
        [AllowNull()]$Body = $null,
        [AllowNull()][hashtable]$Query = $null,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $uriBuilder = [System.UriBuilder]::new($script:RunPodApiBase.TrimEnd('/') + $Path)
    if ($null -ne $Query -and $Query.Count -gt 0) {
        $pairs = @(
            foreach ($key in @($Query.Keys | Sort-Object)) {
                '{0}={1}' -f (
                    [Uri]::EscapeDataString([string]$key),
                    [Uri]::EscapeDataString([string]$Query[$key])
                )
            }
        )
        $uriBuilder.Query = $pairs -join '&'
    }
    $uri = $uriBuilder.Uri.AbsoluteUri
    $headers = @{ Authorization = "Bearer $ApiKey" }
    $parameters = @{
        Uri = $uri
        Method = $Method
        Headers = $headers
        TimeoutSec = $TimeoutSeconds
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 16 -Compress
    }
    try {
        return Invoke-RestMethod @parameters
    }
    catch {
        # Deliberately omit request headers and response bodies. Either can
        # contain provider diagnostics that should not enter shell logs.
        throw "RunPod API request failed: $Method $Path. No automatic retry was attempted."
    }
}

function Invoke-RunPodGraphQLQuery {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiKey,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Query,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    # RunPod's published GraphQL contract authenticates via api_key in the
    # query string. Build it in memory and never include the URI, response, or
    # provider diagnostics in errors or state files.
    $uri = '{0}?api_key={1}' -f (
        $script:RunPodGraphQLApiBase,
        [Uri]::EscapeDataString($ApiKey)
    )
    try {
        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method POST `
            -ContentType 'application/json' `
            -Body (@{ query = $Query } | ConvertTo-Json -Compress) `
            -TimeoutSec $TimeoutSeconds `
            -ErrorAction Stop
    }
    catch {
        throw 'RunPod GraphQL preflight failed. No create request was sent.'
    }
    $errors = Get-RunPodMemberValue -InputObject $response -Names @('errors')
    if ($null -ne $errors -and @($errors).Count -gt 0) {
        throw 'RunPod GraphQL preflight returned an error. No create request was sent.'
    }
    return $response
}

function Get-RunPodGpuOffer {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiKey,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9 ._-]+$')][string]$GpuTypeId
    )

    $escapedGpuTypeId = $GpuTypeId.Replace('\', '\\').Replace('"', '\"')
    $query = @"
query {
  gpuTypes(input: { id: "$escapedGpuTypeId" }) {
    id
    displayName
    memoryInGb
    secureCloud
    lowestPrice(input: { gpuCount: 1, secureCloud: true }) {
      stockStatus
      uninterruptablePrice
      availableGpuCounts
    }
  }
}
"@
    $response = Invoke-RunPodGraphQLQuery -ApiKey $ApiKey -Query $query
    $matches = @(
        Get-RunPodResponseItems -Response $response | Where-Object {
            $id = Get-RunPodMemberValue -InputObject $_ -Names @('id', 'gpuTypeId')
            [string]::Equals([string]$id, $GpuTypeId, [StringComparison]::Ordinal)
        }
    )
    if ($matches.Count -ne 1) {
        throw "Expected exactly one RunPod GPU offer for '$GpuTypeId', found $($matches.Count)."
    }
    $record = $matches[0]
    $lowestPrice = Get-RunPodMemberValue -InputObject $record -Names @('lowestPrice')
    $securePrice = Get-RunPodMemberValue -InputObject $lowestPrice -Names @('uninterruptablePrice')
    $stockStatus = Get-RunPodMemberValue -InputObject $lowestPrice -Names @('stockStatus')
    $availableGpuCounts = Get-RunPodMemberValue -InputObject $lowestPrice -Names @('availableGpuCounts')
    $memoryInGb = Get-RunPodMemberValue -InputObject $record -Names @(
        'memoryInGb', 'memoryGB', 'vramInGb'
    )
    $secureCloud = Get-RunPodMemberValue -InputObject $record -Names @(
        'secureCloud', 'secureCloudAvailable', 'isSecureCloud'
    )
    return [pscustomobject]@{
        id = [string](Get-RunPodMemberValue -InputObject $record -Names @('id', 'gpuTypeId'))
        display_name = [string](Get-RunPodMemberValue -InputObject $record -Names @('displayName', 'name'))
        memory_in_gb = if ($null -eq $memoryInGb) { $null } else { [decimal]$memoryInGb }
        secure_cloud = if ($null -eq $secureCloud) { $null } else { [bool]$secureCloud }
        secure_price = if ($null -eq $securePrice) { $null } else { [decimal]$securePrice }
        stock_status = if ($null -eq $stockStatus) { $null } else { [string]$stockStatus }
        available_gpu_counts = @($availableGpuCounts)
    }
}

function Assert-RunPodGpuOffer {
    param(
        [Parameter(Mandatory)]$Offer,
        [Parameter(Mandatory)][string]$ExpectedGpuTypeId,
        [ValidateRange(1, 1024)][int]$MinimumMemoryGb,
        [ValidateRange(0.01, 1000.0)][decimal]$MaximumSecurePrice
    )

    if (-not [string]::Equals([string]$Offer.id, $ExpectedGpuTypeId, [StringComparison]::Ordinal)) {
        throw "RunPod GPU type mismatch: '$($Offer.id)'."
    }
    if ($null -eq $Offer.memory_in_gb -or [decimal]$Offer.memory_in_gb -lt $MinimumMemoryGb) {
        throw "RunPod GPU offer does not provide the required $MinimumMemoryGb GB VRAM."
    }
    if ($null -eq $Offer.secure_cloud -or -not [bool]$Offer.secure_cloud) {
        throw 'The exact GPU is not offered in Secure Cloud.'
    }
    if ($null -eq $Offer.secure_price) {
        throw 'RunPod did not return a Secure Cloud compute price.'
    }
    if ([decimal]$Offer.secure_price -gt $MaximumSecurePrice) {
        throw "RunPod Secure Cloud price $($Offer.secure_price) exceeds the approved limit $MaximumSecurePrice USD/h."
    }
    if (
        [string]::IsNullOrWhiteSpace([string]$Offer.stock_status) -or
        [string]::Equals([string]$Offer.stock_status, 'None', [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw 'The exact Secure Cloud GPU has no reported stock.'
    }
    # RunPod currently returns null for availableGpuCounts on some valid
    # low-stock offers even though stockStatus, price, and the exact
    # gpuCount=1 REST create contract are available. Treat the optional field
    # as an additional constraint only when it contains concrete counts. The
    # create request and authoritative post-create binding still require
    # exactly one GPU and never permit a hardware fallback.
    $reportedCounts = @(
        $Offer.available_gpu_counts |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if ($reportedCounts.Count -gt 0) {
        $availableCounts = @($reportedCounts | ForEach-Object { [int]$_ })
        if ($availableCounts -notcontains 1) {
            throw 'The exact Secure Cloud GPU is not available as a single-GPU Pod.'
        }
    }
}

function New-RunPodPod {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiKey,
        [Parameter(Mandatory)]$CreateRequest
    )

    $requestNames = @($CreateRequest.PSObject.Properties.Name)
    foreach ($forbidden in @('templateId', 'templateName', 'networkVolumeId')) {
        if ($requestNames -contains $forbidden) {
            throw "Forbidden RunPod create field: $forbidden"
        }
    }
    # This is the sole create submission. It is intentionally not wrapped in
    # any retry helper: an ambiguous response must never create a second pod.
    $response = Invoke-RunPodRestRequest -Method POST -Path '/pods' -ApiKey $ApiKey -Body $CreateRequest -TimeoutSeconds 60
    return Get-RunPodResponseObject -Response $response
}

function Get-RunPodPod {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiKey,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$PodId
    )

    $escapedId = [Uri]::EscapeDataString($PodId)
    $response = Invoke-RunPodRestRequest `
        -Method GET `
        -Path "/pods/$escapedId" `
        -ApiKey $ApiKey `
        -Query @{ includeMachine = 'true' }
    $pod = Get-RunPodResponseObject -Response $response
    $actualId = Get-RunPodPodId -Pod $pod
    if (-not [string]::Equals([string]$actualId, $PodId, [StringComparison]::Ordinal)) {
        throw "RunPod GET response id mismatch for pod '$PodId'."
    }
    return $pod
}

function Get-RunPodPods {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiKey)

    $response = Invoke-RunPodRestRequest `
        -Method GET `
        -Path '/pods' `
        -ApiKey $ApiKey `
        -Query @{ includeMachine = 'true'; computeType = 'GPU' }
    return @(Get-RunPodResponseItems -Response $response)
}

function Get-RunPodPodsByName {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiKey,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$Name
    )

    return @(
        Get-RunPodPods -ApiKey $ApiKey | Where-Object {
            $actualName = Get-RunPodMemberValue -InputObject $_ -Names @('name')
            [string]::Equals([string]$actualName, $Name, [StringComparison]::Ordinal)
        }
    )
}

function Stop-RunPodPod {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiKey,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$PodId,
        [ValidateRange(10, 300)][int]$TimeoutSeconds = 120,
        [ValidateRange(1, 15)][int]$PollIntervalSeconds = 3
    )

    $escapedId = [Uri]::EscapeDataString($PodId)
    $stopResponse = Invoke-RunPodRestRequest -Method POST -Path "/pods/$escapedId/stop" -ApiKey $ApiKey -TimeoutSeconds 30
    $responseId = if ($null -eq $stopResponse) { '' } else { Get-RunPodPodId -Pod $stopResponse }
    if (
        -not [string]::IsNullOrWhiteSpace($responseId) -and
        -not [string]::Equals($responseId, $PodId, [StringComparison]::Ordinal)
    ) {
        throw "RunPod stop response id mismatch for pod '$PodId'."
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $pod = Get-RunPodPod -ApiKey $ApiKey -PodId $PodId
        $status = [string](Get-RunPodMemberValue -InputObject $pod -Names @('desiredStatus'))
        if ([string]::Equals($status, 'EXITED', [StringComparison]::OrdinalIgnoreCase)) {
            return $pod
        }
        if ([string]::Equals($status, 'TERMINATED', [StringComparison]::OrdinalIgnoreCase)) {
            throw "RunPod pod '$PodId' was unexpectedly TERMINATED instead of stopped."
        }
        if ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "RunPod pod '$PodId' did not reach EXITED after the stop request."
}

function Get-RunPodPodId {
    param([Parameter(Mandatory)]$Pod)

    return [string](Get-RunPodMemberValue -InputObject (Get-RunPodResponseObject -Response $Pod) -Names @('id', 'podId'))
}

function Assert-RunPodPodOwnership {
    param(
        [Parameter(Mandatory)]$Pod,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$ExpectedPodId,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$ExpectedName
    )

    $podRecord = Get-RunPodResponseObject -Response $Pod
    $actualPodId = Get-RunPodPodId -Pod $podRecord
    if (-not [string]::Equals($actualPodId, $ExpectedPodId, [StringComparison]::Ordinal)) {
        throw "RunPod ownership id mismatch for pod '$ExpectedPodId'."
    }
    $actualName = [string](Get-RunPodMemberValue -InputObject $podRecord -Names @('name'))
    if (-not [string]::Equals($actualName, $ExpectedName, [StringComparison]::Ordinal)) {
        throw "RunPod ownership name mismatch for pod '$ExpectedPodId'."
    }
    return $actualPodId
}

function Assert-RunPodPodContract {
    param(
        [Parameter(Mandatory)]$Pod,
        [Parameter(Mandatory)]$Target
    )

    $podRecord = Get-RunPodResponseObject -Response $Pod
    $podId = Get-RunPodPodId -Pod $podRecord
    if ([string]::IsNullOrWhiteSpace($podId)) {
        throw 'RunPod pod response does not contain a pod id.'
    }
    $podName = [string](Get-RunPodMemberValue -InputObject $podRecord -Names @('name'))
    if (-not [string]::Equals($podName, [string]$Target.pod_name, [StringComparison]::Ordinal)) {
        throw "Created pod name mismatch: '$podName'."
    }
    $desiredStatus = [string](Get-RunPodMemberValue -InputObject $podRecord -Names @('desiredStatus'))
    if (-not [string]::Equals($desiredStatus, 'RUNNING', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Created or adopted pod is not RUNNING: '$desiredStatus'."
    }
    $machine = Get-RunPodMemberValue -InputObject $podRecord -Names @('machine')
    if ($null -eq $machine) {
        throw 'RunPod pod response omitted the required machine contract.'
    }
    $secureCloud = Get-RunPodMemberValue -InputObject $machine -Names @('secureCloud')
    if ($null -eq $secureCloud -or -not [bool]$secureCloud) {
        throw 'Created pod is not bound to Secure Cloud.'
    }
    $gpuType = Get-RunPodMemberValue -InputObject $machine -Names @('gpuTypeId')
    if ($null -eq $gpuType) {
        $machineGpuType = Get-RunPodMemberValue -InputObject $machine -Names @('gpuType')
        $gpuType = Get-RunPodMemberValue -InputObject $machineGpuType -Names @('id')
    }
    if (-not [string]::Equals([string]$gpuType, [string]$Target.gpu_type_id, [StringComparison]::Ordinal)) {
        throw "Created pod GPU mismatch: '$gpuType'."
    }
    # The current REST v1 response exposes gpuCount and imageName at the top
    # level. Older/documented responses may instead expose gpu.count and
    # image. Accept both shapes while preserving exact-value checks.
    $gpuCount = Get-RunPodMemberValue -InputObject $podRecord -Names @('gpuCount')
    if ($null -eq $gpuCount) {
        $gpu = Get-RunPodMemberValue -InputObject $podRecord -Names @('gpu')
        $gpuCount = Get-RunPodMemberValue -InputObject $gpu -Names @('count')
    }
    if ($null -eq $gpuCount -or [int]$gpuCount -ne [int]$Target.gpu_count) {
        throw "Created pod GPU count mismatch: '$gpuCount'."
    }
    $imageName = [string](Get-RunPodMemberValue -InputObject $podRecord -Names @('image', 'imageName'))
    if (-not [string]::Equals($imageName, [string]$Target.image_name, [StringComparison]::Ordinal)) {
        throw "Created pod image mismatch: '$imageName'."
    }
    $interruptible = Get-RunPodMemberValue -InputObject $podRecord -Names @('interruptible')
    # REST v1 currently omits false-valued default booleans from GET
    # responses. The sole create request sets both values explicitly. Reject
    # an affirmative response value; an omitted value retains the provider's
    # documented false default.
    if ($null -ne $interruptible -and [bool]$interruptible) {
        throw 'Created pod unexpectedly uses interruptible compute.'
    }
    $locked = Get-RunPodMemberValue -InputObject $podRecord -Names @('locked')
    if ($null -ne $locked -and [bool]$locked) {
        throw 'Created pod lock state does not permit safe rollback.'
    }
    $volumeInGb = Get-RunPodMemberValue -InputObject $podRecord -Names @('volumeInGb', 'volume_gb')
    if ($null -eq $volumeInGb -or [int]$volumeInGb -ne [int]$Target.volume_gb) {
        throw "Created pod volume size mismatch: '$volumeInGb'."
    }
    $volumeMountPath = [string](Get-RunPodMemberValue -InputObject $podRecord -Names @('volumeMountPath', 'volume_mount_path'))
    if (-not [string]::Equals($volumeMountPath, [string]$Target.volume_mount_path, [StringComparison]::Ordinal)) {
        throw "Created pod volume mount mismatch: '$volumeMountPath'."
    }
    $containerDisk = Get-RunPodMemberValue -InputObject $podRecord -Names @('containerDiskInGb', 'container_disk_gb')
    if ($null -eq $containerDisk -or [int]$containerDisk -ne [int]$Target.container_disk_gb) {
        throw "Created pod container disk mismatch: '$containerDisk'."
    }
    $ports = @(Get-RunPodMemberValue -InputObject $podRecord -Names @('ports'))
    if ($ports.Count -ne 1 -or -not [string]::Equals([string]$ports[0], '22/tcp', [StringComparison]::Ordinal)) {
        throw 'Created pod ports do not match the SSH-only contract.'
    }
    $publicIpSupported = Get-RunPodMemberValue -InputObject $machine -Names @('supportPublicIp')
    if ($null -eq $publicIpSupported -or -not [bool]$publicIpSupported) {
        throw 'Created pod machine does not support the required public IP.'
    }
    $costPerHour = Get-RunPodMemberValue -InputObject $podRecord -Names @('costPerHr', 'costPerHour')
    if ($null -eq $costPerHour) {
        throw 'RunPod pod response omitted the authoritative compute price.'
    }
    if ([decimal]$costPerHour -gt [decimal]$Target.max_compute_usd_per_hour) {
        throw "Created pod price $costPerHour exceeds the approved compute limit."
    }
    return $podId
}

function Get-RunPodSshEndpoint {
    param([Parameter(Mandatory)]$Pod)

    $podRecord = Get-RunPodResponseObject -Response $Pod
    $hostValue = Get-RunPodMemberValue -InputObject $podRecord -Names @('publicIp', 'public_ip', 'ipAddress')
    $runtime = Get-RunPodMemberValue -InputObject $podRecord -Names @('runtime')
    if ([string]::IsNullOrWhiteSpace([string]$hostValue) -and $null -ne $runtime) {
        $hostValue = Get-RunPodMemberValue -InputObject $runtime -Names @('publicIp', 'public_ip', 'ipAddress')
    }

    $portValue = $null
    $mappings = Get-RunPodMemberValue -InputObject $podRecord -Names @('portMappings', 'port_mappings')
    if ($null -ne $mappings) {
        $portValue = Get-RunPodMemberValue -InputObject $mappings -Names @('22', '22/tcp')
    }
    if ($null -eq $portValue -and $null -ne $runtime) {
        $runtimeMappings = Get-RunPodMemberValue -InputObject $runtime -Names @('portMappings', 'port_mappings')
        if ($null -ne $runtimeMappings) {
            $portValue = Get-RunPodMemberValue -InputObject $runtimeMappings -Names @('22', '22/tcp')
        }
        $runtimePorts = Get-RunPodMemberValue -InputObject $runtime -Names @('ports')
        foreach ($entry in @($runtimePorts)) {
            $privatePort = Get-RunPodMemberValue -InputObject $entry -Names @('privatePort', 'containerPort')
            if ($null -ne $privatePort -and [int]$privatePort -eq 22) {
                $portValue = Get-RunPodMemberValue -InputObject $entry -Names @('publicPort', 'port')
                $entryIp = Get-RunPodMemberValue -InputObject $entry -Names @('ip', 'publicIp')
                if (-not [string]::IsNullOrWhiteSpace([string]$entryIp)) {
                    $hostValue = $entryIp
                }
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$hostValue) -or $null -eq $portValue) {
        return $null
    }
    $port = [int]$portValue
    if ($port -lt 1 -or $port -gt 65535) {
        return $null
    }
    return [pscustomobject]@{
        SshHost = [string]$hostValue
        SshPort = $port
    }
}

function Test-RunPodTcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [ValidateRange(1, 30)][int]$TimeoutSeconds
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutSeconds * 1000)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Wait-RunPodSsh {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApiKey,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$PodId,
        [ValidateRange(30, 3600)][int]$TimeoutSeconds,
        [ValidateRange(1, 60)][int]$PollIntervalSeconds,
        [ValidateRange(1, 30)][int]$ConnectTimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $pod = Get-RunPodPod -ApiKey $ApiKey -PodId $PodId
        $status = [string](Get-RunPodMemberValue -InputObject $pod -Names @('desiredStatus', 'status'))
        if ($status.ToUpperInvariant() -in @('EXITED', 'STOPPED', 'TERMINATED', 'FAILED')) {
            throw "RunPod pod entered terminal status '$status' before SSH became ready."
        }
        $endpoint = Get-RunPodSshEndpoint -Pod $pod
        if (
            $null -ne $endpoint -and
            (Test-RunPodTcpPort -HostName $endpoint.SshHost -Port $endpoint.SshPort -TimeoutSeconds $ConnectTimeoutSeconds)
        ) {
            return [pscustomobject]@{
                SshHost = $endpoint.SshHost
                SshPort = $endpoint.SshPort
                Pod = $pod
            }
        }
        if ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "RunPod pod '$PodId' did not expose reachable SSH within $TimeoutSeconds seconds."
}

Export-ModuleMember -Function @(
    'Get-RunPodProviderApiBase',
    'Get-RunPodProviderGraphQLApiBase',
    'Get-RunPodGpuOffer',
    'Assert-RunPodGpuOffer',
    'New-RunPodPod',
    'Get-RunPodPod',
    'Get-RunPodPods',
    'Get-RunPodPodsByName',
    'Stop-RunPodPod',
    'Get-RunPodPodId',
    'Assert-RunPodPodOwnership',
    'Assert-RunPodPodContract',
    'Get-RunPodSshEndpoint',
    'Wait-RunPodSsh'
)

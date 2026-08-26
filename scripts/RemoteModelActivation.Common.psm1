Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-QwenRemoteArtifactCheckCommand {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][object[]]$Artifacts
    )

    if ($Directory -notmatch '^/workspace/[A-Za-z0-9._/-]+$') {
        throw "Unsafe remote artifact directory: $Directory"
    }
    $checks = @()
    foreach ($artifact in $Artifacts) {
        $filename = [string]$artifact.Filename
        $sha256 = [string]$artifact.Sha256
        $size = [int64]$artifact.Size
        if (
            $filename -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
            $sha256 -notmatch '^[0-9a-f]{64}$' -or
            $size -le 0
        ) {
            throw 'Unsafe remote model artifact contract.'
        }
        $path = "$Directory/$filename"
        $checks += "test ! -L '$path'"
        $checks += "test -f '$path'"
        $checks += ('test "$(stat -c %s ''{0}'')" = ''{1}''' -f $path, $size)
        $checks += "printf '%s  %s\n' '$sha256' '$path' | sha256sum -c - >/dev/null"
    }
    if ($checks.Count -eq 0) {
        throw 'Remote activation requires at least one artifact.'
    }
    return '( ' + ($checks -join ' && ') + ' )'
}

function Get-QwenRemoteActivationShellPreamble {
    return @(
        'qwen_fail() { printf ''%s\n'' "$1" >&2; exit 1; }'
        'qwen_path_type() { if test -L "$1"; then printf symlink; elif test -d "$1"; then printf directory; elif test -f "$1"; then printf file; elif test -e "$1"; then printf other; else printf absent; fi; }'
        'qwen_move_directory() { test "$(qwen_path_type "$1")" = directory || qwen_fail "move source is not a directory: $1"; test "$(qwen_path_type "$2")" = absent || qwen_fail "move destination is not absent: $2"; mv -- "$1" "$2" || qwen_fail "directory move failed: $1"; test "$(qwen_path_type "$1")" = absent || qwen_fail "move source still exists: $1"; test "$(qwen_path_type "$2")" = directory || qwen_fail "move destination is not a directory: $2"; }'
        'qwen_remove_directory() { test "$(qwen_path_type "$1")" = directory || qwen_fail "remove target is not a directory: $1"; rm -rf -- "$1" || qwen_fail "directory removal failed: $1"; test "$(qwen_path_type "$1")" = absent || qwen_fail "directory removal left a path behind: $1"; }'
    ) -join '; '
}

function Get-QwenRemoteModelRecoveryCommand {
    param(
        [Parameter(Mandatory)][string]$RemoteDir,
        [Parameter(Mandatory)][ValidateSet('uncensored-q6', 'uncensored-q4', 'whitehat-q4')][string]$Model,
        [Parameter(Mandatory)][object[]]$Artifacts,
        [ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedOwnerToken,
        [switch]$AllowStaleRecovery
    )

    if ($RemoteDir -notmatch '^/workspace/[A-Za-z0-9_-]+(?:/[A-Za-z0-9._-]+)*$') {
        throw "Unsafe remote directory: $RemoteDir"
    }
    $modelsDirectory = "$RemoteDir/models"
    $finalDirectory = "$modelsDirectory/$Model"
    $transactionDirectory = "$modelsDirectory/.activation-$Model"
    $previousDirectory = "$transactionDirectory/previous"
    $ownerPath = "$transactionDirectory/owner"
    $phasePath = "$transactionDirectory/phase"
    $finalCheck = Get-QwenRemoteArtifactCheckCommand -Directory $finalDirectory -Artifacts $Artifacts
    $previousCheck = Get-QwenRemoteArtifactCheckCommand -Directory $previousDirectory -Artifacts $Artifacts

    if (-not [string]::IsNullOrWhiteSpace($ExpectedOwnerToken) -and $AllowStaleRecovery) {
        throw 'Choose either an expected activation owner or explicit stale recovery.'
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedOwnerToken) -and -not $AllowStaleRecovery) {
        throw 'Recovery requires an expected owner token or explicit stale-recovery approval.'
    }

    $ownerGate = if (-not [string]::IsNullOrWhiteSpace($ExpectedOwnerToken)) {
        'test "$(qwen_path_type ''{0}'')" = file || qwen_fail ''activation owner journal is missing or unsafe''; test "$(cat ''{0}'')" = ''{1}'' || qwen_fail ''foreign or live model activation transaction refused''' -f $ownerPath, $ExpectedOwnerToken
    }
    else {
        'test "$(qwen_path_type ''{0}'')" = file || qwen_fail ''stale activation owner journal is missing or unsafe''; stale_owner=$(cat ''{0}'') || qwen_fail ''stale activation owner journal cannot be read''; printf ''%s'' "$stale_owner" | grep -Eq ''^[0-9a-f]{{32}}$'' || qwen_fail ''stale activation owner journal is invalid''' -f $ownerPath
    }

    $preamble = Get-QwenRemoteActivationShellPreamble

    return @(
        $preamble
        'models_type=$(qwen_path_type ''{0}''); if test "$models_type" = absent; then mkdir -p ''{0}'' || qwen_fail ''models directory creation failed''; test "$(qwen_path_type ''{0}'')" = directory || qwen_fail ''models directory creation produced an unsafe path''; elif test "$models_type" != directory; then qwen_fail ''models path is not a directory''; fi' -f $modelsDirectory
        'transaction_type=$(qwen_path_type ''{0}''); final_type=$(qwen_path_type ''{1}''); if test "$transaction_type" = absent; then case "$final_type" in absent|directory) ;; *) qwen_fail ''active model path has an unsafe type'' ;; esac; printf ''%s'' RECOVERY_OK; exit 0; fi; test "$transaction_type" = directory || qwen_fail ''activation transaction path is not a directory''' -f $transactionDirectory, $finalDirectory
        $ownerGate
        'phase_type=$(qwen_path_type ''{0}''); test "$phase_type" = file || qwen_fail ''activation phase journal is missing or unsafe''; phase=$(cat ''{0}'') || qwen_fail ''activation phase journal cannot be read''; case "$phase" in uploading:*) printf ''%s'' "$phase" | grep -Eq ''^uploading:[0-9a-f]{{32}}$'' || qwen_fail ''activation upload phase journal is invalid'' ;; verified|previous_moved|activated|rollback_pending|consumer_verified) ;; *) qwen_fail ''activation phase journal is invalid'' ;; esac; phase_next_type=$(qwen_path_type ''{1}''); case "$phase_next_type" in absent|file) ;; *) qwen_fail ''activation phase-next journal has an unsafe type'' ;; esac' -f $phasePath, "$transactionDirectory/phase.next"
        'previous_type=$(qwen_path_type ''{0}''); case "$previous_type" in absent|directory) ;; *) qwen_fail ''previous generation path has an unsafe type'' ;; esac; final_type=$(qwen_path_type ''{1}''); case "$final_type" in absent|directory) ;; *) qwen_fail ''active model path has an unsafe type'' ;; esac' -f $previousDirectory, $finalDirectory
        'generation_count=0; generation_path=''''; for candidate in ''{0}''/generation-*; do candidate_type=$(qwen_path_type "$candidate"); test "$candidate_type" = absent && continue; test "$candidate_type" = directory || qwen_fail ''transaction generation path has an unsafe type''; generation_count=$((generation_count + 1)); generation_path="$candidate"; done; test "$generation_count" -le 1 || qwen_fail ''activation transaction contains multiple generations''' -f $transactionDirectory
        'if test "$phase" = consumer_verified; then test "$generation_count" -eq 0 || qwen_fail ''consumer-verified activation still has a transaction generation''; test "$final_type" = directory || qwen_fail ''consumer-verified activation has no active directory''; {0} || qwen_fail ''consumer-verified active generation failed verification''; qwen_remove_directory ''{1}''; printf ''%s'' RECOVERY_OK; exit 0; fi' -f $finalCheck, $transactionDirectory
        'if test "$previous_type" = directory; then case "$phase" in verified|previous_moved|activated|rollback_pending) ;; *) qwen_fail ''previous generation is inconsistent with the activation phase'' ;; esac; {0} || qwen_fail ''previous generation failed verification''; printf ''%s\n'' rollback_pending >''{1}'' || qwen_fail ''rollback_pending phase write failed''; mv -f -- ''{1}'' ''{2}'' || qwen_fail ''rollback_pending phase install failed''; test "$(cat ''{2}'')" = rollback_pending || qwen_fail ''rollback_pending phase check failed''; if test "$final_type" = directory; then qwen_remove_directory ''{3}''; fi; qwen_move_directory ''{4}'' ''{3}''; {5} || qwen_fail ''restored previous generation failed verification''; qwen_remove_directory ''{6}''; printf ''%s'' RECOVERY_OK; exit 0; fi' -f $previousCheck, "$transactionDirectory/phase.next", $phasePath, $finalDirectory, $previousDirectory, $finalCheck, $transactionDirectory
        'if test "$phase" = rollback_pending; then test "$final_type" = directory || qwen_fail ''rollback-pending transaction lost both generations''; {0} || qwen_fail ''rollback-restored generation failed verification''; qwen_remove_directory ''{1}''; printf ''%s'' RECOVERY_OK; exit 0; fi' -f $finalCheck, $transactionDirectory
        'case "$phase" in uploading:*) qwen_remove_directory ''{0}'' ;; verified) if test "$generation_count" -eq 0 -a "$final_type" = directory; then qwen_remove_directory ''{1}''; fi; qwen_remove_directory ''{0}'' ;; activated) test "$generation_count" -eq 0 || qwen_fail ''activated transaction still has a generation''; if test "$final_type" = directory; then qwen_remove_directory ''{1}''; fi; qwen_remove_directory ''{0}'' ;; previous_moved) qwen_fail ''previous_moved phase has no previous generation'' ;; *) qwen_fail ''unsupported rollback phase'' ;; esac' -f $transactionDirectory, $finalDirectory
        "printf '%s' RECOVERY_OK"
    ) -join ' && '
}

function Repair-QwenRemoteModelActivation {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$RemoteDir,
        [Parameter(Mandatory)][ValidateSet('uncensored-q6', 'uncensored-q4', 'whitehat-q4')][string]$Model,
        [Parameter(Mandatory)][object[]]$Artifacts,
        [ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedOwnerToken,
        [switch]$AllowStaleRecovery
    )

    $recoveryParameters = @{
        RemoteDir = $RemoteDir
        Model = $Model
        Artifacts = $Artifacts
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedOwnerToken)) {
        $recoveryParameters.ExpectedOwnerToken = $ExpectedOwnerToken
    }
    if ($AllowStaleRecovery) {
        $recoveryParameters.AllowStaleRecovery = $true
    }
    $command = Get-QwenRemoteModelRecoveryCommand @recoveryParameters
    $output = @(
        Invoke-RunPodSshBounded `
            -Session $Session `
            -RemoteCommand $command `
            -TimeoutSeconds 300
    )
    if ($output.Count -ne 1 -or [string]$output[0] -ne 'RECOVERY_OK') {
        throw 'Remote model activation recovery returned an unexpected result.'
    }
}

function Invoke-QwenRemoteModelActivation {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RemoteDir,
        [Parameter(Mandatory)][ValidateSet('uncensored-q6', 'uncensored-q4', 'whitehat-q4')][string]$Model,
        [Parameter(Mandatory)]$Backup
    )

    $artifacts = @($Backup.Artifacts)
    [void](Get-QwenRemoteArtifactCheckCommand -Directory "$RemoteDir/models/$Model" -Artifacts $artifacts)
    $lockDirectory = Join-Path $ProjectRoot '.runpod'
    [IO.Directory]::CreateDirectory($lockDirectory) | Out-Null
    $lockPath = Join-Path $lockDirectory "model-activation-$($Session.PodId)-$Model.lock"
    $ownerToken = [Guid]::NewGuid().ToString('N')
    $lockStream = $null
    try {
        try {
            $lockStream = [IO.File]::Open(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch {
            throw "Another local process is activating model '$Model' on this pod."
        }

        try {
            Repair-QwenRemoteModelActivation `
                -Session $Session `
                -RemoteDir $RemoteDir `
                -Model $Model `
                -Artifacts $artifacts `
                -ExpectedOwnerToken $ownerToken
        }
        catch {
            throw "Remote activation recovery refused an unsafe or foreign transaction. If its owner is known to be stale, run Repair-QwenRemoteModelActivation explicitly with -AllowStaleRecovery. $($_.Exception.Message)"
        }

        $remotePresence = @(
            Invoke-RunPodSshBounded `
                -Session $Session `
                -RemoteCommand "if QWEN_MODEL_SOURCE=local-only bash '$RemoteDir/runpod/modelctl.sh' download '$Model' >/dev/null 2>&1; then printf REMOTE_VERIFIED; else printf REMOTE_MISSING; fi" `
                -TimeoutSeconds 300
        )
        if ($remotePresence.Count -ne 1 -or $remotePresence[0] -notin @('REMOTE_VERIFIED', 'REMOTE_MISSING')) {
            throw 'Remote model-presence probe returned an unexpected result.'
        }

        $uploaded = $false
        if ($remotePresence[0] -eq 'REMOTE_MISSING') {
            $requiredBytes = [int64]5368709120
            foreach ($artifact in $artifacts) {
                $requiredBytes += [int64]$artifact.Size
            }
            $freeOutput = @(
                Invoke-RunPodSshBounded `
                    -Session $Session `
                    -RemoteCommand "mkdir -p '$RemoteDir/models' && df -PB1 '$RemoteDir/models' | awk 'NR==2 {print `$4}'" `
                    -TimeoutSeconds 30
            )
            [int64]$remoteFreeBytes = 0
            if (
                $freeOutput.Count -ne 1 -or
                -not [int64]::TryParse([string]$freeOutput[0], [ref]$remoteFreeBytes) -or
                $remoteFreeBytes -lt $requiredBytes
            ) {
                throw 'Remote model volume lacks the required transaction space plus 5 GiB reserve.'
            }

            $modelsDirectory = "$RemoteDir/models"
            $finalDirectory = "$modelsDirectory/$Model"
            $transactionDirectory = "$modelsDirectory/.activation-$Model"
            $activationId = [Guid]::NewGuid().ToString('N')
            $generationDirectory = "$transactionDirectory/generation-$activationId"
            $previousDirectory = "$transactionDirectory/previous"
            $ownerPath = "$transactionDirectory/owner"
            $phasePath = "$transactionDirectory/phase"
            $phaseNextPath = "$transactionDirectory/phase.next"
            $shellPreamble = Get-QwenRemoteActivationShellPreamble
            $ownerGuard = 'test "$(qwen_path_type ''{0}'')" = file || qwen_fail ''activation owner journal is missing or unsafe''; test "$(cat ''{0}'')" = ''{1}'' || qwen_fail ''foreign or live model activation transaction refused''' -f $ownerPath, $ownerToken
            try {
                $creationCommand = @(
                    $shellPreamble
                    'transaction_type=$(qwen_path_type ''{0}''); test "$transaction_type" = absent || qwen_fail ''model activation transaction already exists or has an unsafe type''; mkdir ''{0}'' || qwen_fail ''model activation transaction creation failed''; test "$(qwen_path_type ''{0}'')" = directory || qwen_fail ''model activation transaction is not a directory''' -f $transactionDirectory
                    'printf ''%s\n'' ''{0}'' >''{1}'' || qwen_fail ''activation owner journal write failed''; test "$(qwen_path_type ''{1}'')" = file || qwen_fail ''activation owner journal has an unsafe type''; test "$(cat ''{1}'')" = ''{0}'' || qwen_fail ''activation owner journal verification failed''' -f $ownerToken, $ownerPath
                    'printf ''%s\n'' ''uploading:{0}'' >''{1}'' || qwen_fail ''activation phase journal write failed''; test "$(qwen_path_type ''{1}'')" = file || qwen_fail ''activation phase journal has an unsafe type''; test "$(cat ''{1}'')" = ''uploading:{0}'' || qwen_fail ''activation phase journal verification failed''' -f $activationId, $phasePath
                    'mkdir ''{0}'' || qwen_fail ''activation generation creation failed''; test "$(qwen_path_type ''{0}'')" = directory || qwen_fail ''activation generation is not a directory''' -f $generationDirectory
                ) -join ' && '
                Invoke-RunPodSsh -Session $Session -RemoteCommand $creationCommand

                foreach ($artifact in $artifacts) {
                    Write-Host "Uploading verified archive artifact $($artifact.Filename)..."
                    Copy-RunPodItem `
                        -Session $Session `
                        -LocalPath ([string]$artifact.Path) `
                        -RemotePath "$generationDirectory/$($artifact.Filename)"
                }

                $incomingCheck = Get-QwenRemoteArtifactCheckCommand `
                    -Directory $generationDirectory `
                    -Artifacts $artifacts
                $finalCheck = Get-QwenRemoteArtifactCheckCommand `
                    -Directory $finalDirectory `
                    -Artifacts $artifacts
                $activationCommand = @(
                    $shellPreamble
                    $ownerGuard
                    $incomingCheck
                    'test "$(qwen_path_type ''{0}'')" = absent || qwen_fail ''activation phase-next path is not absent''; printf ''%s\n'' verified >''{0}'' || qwen_fail ''verified phase write failed''; mv -- ''{0}'' ''{1}'' || qwen_fail ''verified phase install failed''; test "$(cat ''{1}'')" = verified || qwen_fail ''verified phase check failed''' -f $phaseNextPath, $phasePath
                    'final_type=$(qwen_path_type ''{0}''); previous_type=$(qwen_path_type ''{1}''); test "$previous_type" = absent || qwen_fail ''previous generation path is not absent''; case "$final_type" in directory) qwen_move_directory ''{0}'' ''{1}''; test "$(qwen_path_type ''{2}'')" = absent || qwen_fail ''activation phase-next path is not absent''; printf ''%s\n'' previous_moved >''{2}'' || qwen_fail ''previous_moved phase write failed''; mv -- ''{2}'' ''{3}'' || qwen_fail ''previous_moved phase install failed''; test "$(cat ''{3}'')" = previous_moved || qwen_fail ''previous_moved phase check failed'' ;; absent) ;; *) qwen_fail ''active model path has an unsafe type'' ;; esac' -f $finalDirectory, $previousDirectory, $phaseNextPath, $phasePath
                    'qwen_move_directory ''{0}'' ''{1}''' -f $generationDirectory, $finalDirectory
                    $finalCheck
                    'test "$(qwen_path_type ''{0}'')" = absent || qwen_fail ''activation phase-next path is not absent''; printf ''%s\n'' activated >''{0}'' || qwen_fail ''activated phase write failed''; mv -- ''{0}'' ''{1}'' || qwen_fail ''activated phase install failed''; test "$(cat ''{1}'')" = activated || qwen_fail ''activated phase check failed''' -f $phaseNextPath, $phasePath
                ) -join ' && '
                Invoke-RunPodSsh -Session $Session -RemoteCommand $activationCommand
                $uploaded = $true
            }
            catch {
                try {
                    Repair-QwenRemoteModelActivation `
                        -Session $Session `
                        -RemoteDir $RemoteDir `
                        -Model $Model `
                        -Artifacts $artifacts `
                        -ExpectedOwnerToken $ownerToken
                }
                catch {
                    # Preserve the original failure and every unrecoverable
                    # transaction generation for manual inspection.
                }
                throw
            }
        }

        try {
            $modelctlVerificationCommand = "QWEN_MODEL_SOURCE=local-only bash '$RemoteDir/runpod/modelctl.sh' download '$Model' >/dev/null && QWEN_MODEL_SOURCE=local-only bash '$RemoteDir/runpod/modelctl.sh' verify '$Model' >/dev/null && printf REMOTE_VERIFIED"
            if ($uploaded) {
                $modelctlVerificationCommand = @(
                    $shellPreamble
                    $ownerGuard
                    $modelctlVerificationCommand
                ) -join ' && '
            }
            $finalVerification = @(
                Invoke-RunPodSshBounded `
                    -Session $Session `
                    -RemoteCommand $modelctlVerificationCommand `
                    -TimeoutSeconds 300
            )
            if ($finalVerification.Count -ne 1 -or $finalVerification[0] -ne 'REMOTE_VERIFIED') {
                throw 'Remote model failed final local-only verification.'
            }
        }
        catch {
            $verificationFailure = $_
            if ($uploaded) {
                try {
                    Repair-QwenRemoteModelActivation `
                        -Session $Session `
                        -RemoteDir $RemoteDir `
                        -Model $Model `
                        -Artifacts $artifacts `
                        -ExpectedOwnerToken $ownerToken
                }
                catch {
                    throw "Remote model verification failed and rollback could not complete; the owned transaction journal was preserved. Verification: $($verificationFailure.Exception.Message) Rollback: $($_.Exception.Message)"
                }
            }
            throw $verificationFailure
        }

        if ($uploaded) {
            $commitCommand = @(
                $shellPreamble
                $ownerGuard
                'test "$(qwen_path_type ''{0}'')" = file || qwen_fail ''activation phase journal is missing or unsafe''; test "$(cat ''{0}'')" = activated || qwen_fail ''activation is not ready for consumer commit''' -f $phasePath
                'test "$(qwen_path_type ''{0}'')" = directory || qwen_fail ''active model directory is missing at commit''' -f $finalDirectory
                $finalCheck
                'test "$(qwen_path_type ''{0}'')" = absent || qwen_fail ''activation phase-next path is not absent''; printf ''%s\n'' consumer_verified >''{0}'' || qwen_fail ''consumer_verified phase write failed''; mv -- ''{0}'' ''{1}'' || qwen_fail ''consumer_verified phase install failed''; test "$(cat ''{1}'')" = consumer_verified || qwen_fail ''consumer_verified phase check failed''' -f $phaseNextPath, $phasePath
                'qwen_remove_directory ''{0}''' -f $transactionDirectory
                "printf '%s' COMMIT_OK"
            ) -join ' && '
            $commitOutput = @(
                Invoke-RunPodSshBounded `
                    -Session $Session `
                    -RemoteCommand $commitCommand `
                    -TimeoutSeconds 300
            )
            if ($commitOutput.Count -ne 1 -or $commitOutput[0] -ne 'COMMIT_OK') {
                throw 'Remote model activation commit returned an unexpected result.'
            }
        }
        return [pscustomobject]@{ Uploaded = $uploaded; RemoteVerified = $true }
    }
    finally {
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }
    }
}

Export-ModuleMember -Function @(
    'Get-QwenRemoteModelRecoveryCommand',
    'Repair-QwenRemoteModelActivation',
    'Invoke-QwenRemoteModelActivation'
)

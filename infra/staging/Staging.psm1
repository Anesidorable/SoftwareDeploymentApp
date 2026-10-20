Set-StrictMode -Version Latest
function Wait-StagingCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$GetInvocation,
        [int]$TimeoutSeconds = 2100,
        [scriptblock]$Pause = { Start-Sleep -Seconds 5 }
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { $invocation = & $GetInvocation }
        catch {
            if ($_.Exception.Message -notmatch 'InvocationDoesNotExist') { throw }
            & $Pause
            continue
        }
        if ($invocation.Status -eq 'Success') {
            if ($invocation.ResponseCode -ne 0) { throw "SSM Success with response code $($invocation.ResponseCode)" }
            return $invocation
        }
        if ($invocation.Status -notin @('Pending','InProgress','Delayed','Cancelling')) {
            throw "SSM command failed: $($invocation.Status); response code $($invocation.ResponseCode)"
        }
        & $Pause
    }
    throw 'SSM command polling timed out; no success. Remote command may still run; inspect status before retrying.'
}
function Assert-StagingImageIndex {
    param(
        [Parameter(Mandatory)][string]$ManifestJson,
        [Parameter(Mandatory)][string]$ExpectedDigest,
        [Parameter(Mandatory)][string]$ExpectedRuntimeDigest
    )
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($ManifestJson))
    $actual = 'sha256:' + [Convert]::ToHexString($hash).ToLowerInvariant()
    if ($actual -ne $ExpectedDigest) { throw 'Index content does not match selected digest' }
    $manifest = $ManifestJson | ConvertFrom-Json
    if ($manifest.mediaType -notin @('application/vnd.oci.image.index.v1+json','application/vnd.docker.distribution.manifest.list.v2+json')) {
        throw 'Expected an immutable image index'
    }
    $amd64 = @($manifest.manifests | Where-Object {
        $_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64'
    })
    if ($amd64.Count -ne 1 -or $amd64[0].digest -ne $ExpectedRuntimeDigest) {
        throw 'Selected index does not contain the locked linux/amd64 runtime image'
    }
    return $amd64[0].digest
}
Export-ModuleMember -Function Wait-StagingCommand, Assert-StagingImageIndex

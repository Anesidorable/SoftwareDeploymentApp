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
Export-ModuleMember -Function Wait-StagingCommand

#requires -Version 7.0
[CmdletBinding()]
param([switch]$Containers)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Staging.psm1') -Force
foreach ($file in Get-ChildItem $PSScriptRoot -Recurse -File | Where-Object Extension -in '.ps1','.psm1') {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors -join [Environment]::NewLine) }
}
function Expect-Failure([scriptblock]$Action,[string]$Pattern) {
    $caught=$false
    try { & $Action | Out-Null } catch { $caught=$true; if ($_.Exception.Message -notmatch $Pattern) { throw } }
    if (-not $caught) { throw "Expected failure: $Pattern" }
}
$null=Wait-StagingCommand -GetInvocation { [pscustomobject]@{Status='Success';ResponseCode=0} }
foreach ($status in @('Failed','TimedOut','Cancelled','Delivery Timed Out','Execution Timed Out')) {
    Expect-Failure { Wait-StagingCommand -GetInvocation { [pscustomobject]@{Status=$status;ResponseCode=1} } } 'failed'
}
Expect-Failure { Wait-StagingCommand -GetInvocation { [pscustomobject]@{Status='Success';ResponseCode=1} } } 'response code'
Expect-Failure { Wait-StagingCommand -TimeoutSeconds 0 -GetInvocation { throw 'Should not poll' } } 'timed out'
$script:polls=0
$null=Wait-StagingCommand -Pause {} -GetInvocation {
    $script:polls++
    if ($script:polls -eq 1) { throw 'InvocationDoesNotExist' }
    if ($script:polls -eq 2) { return [pscustomobject]@{Status='InProgress';ResponseCode=-1} }
    return [pscustomobject]@{Status='Success';ResponseCode=0}
}
if ($script:polls -ne 3) { throw 'Propagation/in-progress handling failed' }
Write-Host 'PowerShell parsing and SSM success/failure/timeout/propagation tests passed.'
$fixtureRuntime='sha256:' + ('a' * 64)
$fixtureIndex=@{mediaType='application/vnd.oci.image.index.v1+json';manifests=@(@{
    digest=$fixtureRuntime;platform=@{os='linux';architecture='amd64'}
})} | ConvertTo-Json -Depth 8 -Compress
$fixtureIndexDigest='sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fixtureIndex))).ToLowerInvariant()
$null=Assert-StagingImageIndex -ManifestJson $fixtureIndex -ExpectedDigest $fixtureIndexDigest -ExpectedRuntimeDigest $fixtureRuntime
Expect-Failure { Assert-StagingImageIndex -ManifestJson $fixtureIndex -ExpectedDigest ('sha256:' + ('b' * 64)) -ExpectedRuntimeDigest $fixtureRuntime } 'content'
Expect-Failure { Assert-StagingImageIndex -ManifestJson $fixtureIndex -ExpectedDigest $fixtureIndexDigest -ExpectedRuntimeDigest ('sha256:' + ('c' * 64)) } 'linux/amd64'
Write-Host 'Immutable index hash and locked amd64 manifest checks passed.'

if (-not $Containers) { return }
function Invoke-TestDocker([string[]]$Arguments) {
    $output=& docker.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed: $($Arguments[0]); inspect the disposable test resources." }
    return $output
}
$lock=Get-Content (Join-Path $PSScriptRoot 'release.json') -Raw | ConvertFrom-Json
# Explicit TEST SOURCE ONLY: same public CI manifests, never a deployment registry fallback.
$api="ghcr.io/anesidorable/softwaredeploymentapp/api@$($lock.api.digest)"
$web="ghcr.io/anesidorable/softwaredeploymentapp/web@$($lock.web.digest)"
$prefix='grocery-staging-check-'+[guid]::NewGuid().ToString('N').Substring(0,12)
$dbName="$prefix-db";$apiName="$prefix-api";$webName="$prefix-web"
# Deliberately public fake fixture, including URI-special characters; not an AWS/application credential.
$fixture='validation-only-@:/%+?#=!\$-password'
$apiEnv=@('-e','HOST=0.0.0.0','-e','PORT=5000','-e','APP_ENV=staging','-e',"GIT_SHA=$($lock.release)",
    '-e','DB_HOST=db','-e','DB_USER=grocery_staging','-e','DB_NAME=grocery_staging','-e',"DB_PASSWORD=$fixture")
function Start-TestDb {
    $null=Invoke-TestDocker -Arguments @('run','-d','--name',$dbName,'--network',$prefix,'--network-alias','db',
        '--log-driver','none','-v',"$($prefix):/var/lib/postgresql/data",
        '-e','POSTGRES_USER=grocery_staging','-e','POSTGRES_DB=grocery_staging','-e',"POSTGRES_PASSWORD=$fixture",$lock.postgres)
    for ($i=0;$i -lt 60;$i++) {
        & docker.exe exec $dbName pg_isready -U grocery_staging -d grocery_staging *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    throw 'Disposable test DB did not become ready'
}
try {
    $null=Invoke-TestDocker -Arguments @('pull','--platform','linux/amd64',$api)
    $null=Invoke-TestDocker -Arguments @('pull','--platform','linux/amd64',$web)
    $null=Invoke-TestDocker -Arguments @('pull',$lock.postgres)
    (Get-Content (Join-Path $PSScriptRoot 'deploy.sh') -Raw).Replace("`r`n","`n") | & docker.exe run --rm -i --entrypoint bash $lock.postgres -n
    if ($LASTEXITCODE) { throw 'Bash syntax validation failed' }
    $null=Invoke-TestDocker -Arguments @('network','create',$prefix)
    $null=Invoke-TestDocker -Arguments @('volume','create',$prefix)
    Start-TestDb
    $null=Invoke-TestDocker -Arguments (@('run','--rm','--network',$prefix,'--log-driver','none')+$apiEnv+@($api,'npx','--no-install','prisma','db','migrate'))
    $null=Invoke-TestDocker -Arguments (@('run','-d','--name',$apiName,'--network',$prefix,'--network-alias','api','--log-driver','none')+$apiEnv+@($api,'node','index.js'))
    $null=Invoke-TestDocker -Arguments @('run','-d','--name',$webName,'--network',$prefix,'-e','API_UPSTREAM=api:5000',
        '-p','127.0.0.1::8080',$web)
    $info=(& docker.exe inspect $webName | ConvertFrom-Json)[0]
    $port=$info.NetworkSettings.Ports.'8080/tcp'[0].HostPort
    $url="http://127.0.0.1:$port"
    $healthy=$false
    for ($i=0;$i -lt 60;$i++) {
        try {
            $health=Invoke-RestMethod "$url/api/health" -TimeoutSec 3
            $list=Invoke-RestMethod "$url/api/list" -TimeoutSec 3
            if ($health.env -eq 'staging' -and $health.version -eq $lock.release -and $list -is [array]) {
                $healthy=$true;break
            }
        } catch {}
        Start-Sleep -Seconds 1
    }
    if (-not $healthy) { throw 'Published API migration, database authentication or web proxy health failed' }
    $page=Invoke-WebRequest $url -TimeoutSec 5
    if ($page.StatusCode -ne 200) { throw 'Frontend did not respond' }
    # Seed through SQL, verify the app reads it, recreate DB container and verify persistence.
    $sql='INSERT INTO "GroceryList" (item,count,ticked) VALUES (''staging-persistence-fixture'',1,false);'
    $sql | & docker.exe exec -i $dbName psql -U grocery_staging -d grocery_staging -v ON_ERROR_STOP=1 *> $null
    if ($LASTEXITCODE) { throw 'Persistence fixture insert failed' }
    $null=Invoke-TestDocker -Arguments @('rm','-f',$dbName)
    Start-TestDb
    $persisted=$false
    for ($i=0;$i -lt 30;$i++) {
        try {
            $items=Invoke-RestMethod "$url/api/list" -TimeoutSec 3
            if (@($items | Where-Object item -eq 'staging-persistence-fixture').Count -eq 1) { $persisted=$true;break }
        } catch {}
        Start-Sleep -Seconds 1
    }
    if (-not $persisted) { throw 'Database persistence check failed' }
    $null=Invoke-TestDocker -Arguments (@('run','--rm','--network',$prefix,'--log-driver','none')+$apiEnv+@($api,'npx','--no-install','prisma','db','migrate'))
    $items=Invoke-RestMethod "$url/api/list" -TimeoutSec 3
    if (@($items | Where-Object item -eq 'staging-persistence-fixture').Count -ne 1) { throw 'Migration rerun did not preserve fixture data' }
    Write-Host 'Exact published images passed: actual Prisma migration, special-character password, frontend, API/database, proxy and DB container replacement persistence.'
} finally {
    # Delete only resources named by this test's unique prefix.
    & docker.exe rm -f $webName $apiName $dbName *> $null
    & docker.exe network rm $prefix *> $null
    & docker.exe volume rm $prefix *> $null
}

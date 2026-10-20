#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$ResumeExisting,
    [string]$ExpectedInstanceId,
    [string]$ExpectedVolumeId,
    [string]$ExpectedFilesystemUuid,
    [string]$Profile = 'learnerlab',
    [ValidateSet('us-east-1')][string]$Region = 'us-east-1',
    [ValidateSet('grocery-staging')][string]$StackName = 'grocery-staging',
    [string]$AwsCli = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
    [string]$VpcId = 'vpc-0d06ded968993a487',
    [string]$SubnetId = 'subnet-0f01d6a2f0f1ae895',
    [string]$AvailabilityZone = 'us-east-1a',
    [ValidateSet('LabInstanceProfile')][string]$InstanceProfileName = 'LabInstanceProfile',
    [string]$PasswordParameter = '/grocery/staging/db-password',
    [string]$ReleaseFile = (Join-Path $PSScriptRoot 'release.json'),
    [string]$WebCidr = '0.0.0.0/0'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($ResumeExisting -and (
    $ExpectedInstanceId -notmatch '^i-[a-f0-9]+$' -or
    $ExpectedVolumeId -notmatch '^vol-[a-f0-9]+$' -or
    $ExpectedFilesystemUuid -notmatch '^[a-f0-9-]{36}$')) {
    throw 'ResumeExisting requires the expected instance, data volume and existing filesystem UUID'
}
Import-Module (Join-Path $PSScriptRoot 'Staging.psm1') -Force
function Invoke-Aws {
    param([string[]]$Arguments, [string]$AwsRegion = $Region)
    $result = & $AwsCli @Arguments --profile $Profile --region $AwsRegion --output json --no-cli-pager 2>&1
    if ($LASTEXITCODE -ne 0) { throw "AWS $($Arguments[0..1] -join ' ') failed: $($result -join [Environment]::NewLine)" }
    if ($result) { return ($result -join [Environment]::NewLine | ConvertFrom-Json) }
}
function Invoke-AwsRequest {
    param([string[]]$Arguments, [object]$Request)
    $path = Join-Path ([IO.Path]::GetTempPath()) ("grocery-staging-" + [guid]::NewGuid() + '.json')
    try {
        # Requests contain only nonsecret infrastructure parameters and scripts.
        [IO.File]::WriteAllText($path, ($Request | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        Invoke-Aws -Arguments ($Arguments + @('--cli-input-json', "file://$path"))
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
$identity = Invoke-Aws -Arguments @('sts','get-caller-identity')
if ($identity.Account -ne '245606545178') { throw 'Refusing AWS account other than 245606545178' }
$release = Get-Content -LiteralPath $ReleaseFile -Raw | ConvertFrom-Json
if ($release.release -notmatch '^[a-f0-9]{40}$' -or
    $release.registry -ne '960607644670.dkr.ecr.us-east-1.amazonaws.com' -or
    $release.registryAccount -ne '960607644670' -or $release.registryRegion -ne 'us-east-1' -or
    $release.api.repository -ne 'app/api' -or $release.web.repository -ne 'app/web' -or
    $release.postgres -notmatch '^postgres:17@sha256:[a-f0-9]{64}$') {
    throw 'Invalid release lock or unexpected registry'
}
foreach ($image in @($release.api, $release.web)) {
    if ($image.runtimeDigest -notmatch '^sha256:[a-f0-9]{64}$') { throw 'Locked amd64 runtime digest required' }
    if ($image.digest -notmatch '^sha256:[a-f0-9]{64}$') { throw 'Immutable image digest required' }
}
if ($PasswordParameter -notmatch '^/grocery/staging/[a-zA-Z0-9/_-]+$') { throw 'Secret must use the Staging parameter namespace' }
$template = Join-Path $PSScriptRoot 'cloudformation.yml'
$null = Invoke-Aws -Arguments @('cloudformation','validate-template','--template-body',"file://$template")
$subnet = (Invoke-Aws -Arguments @('ec2','describe-subnets','--subnet-ids',$SubnetId)).Subnets[0]
if ($subnet.VpcId -ne $VpcId -or $subnet.AvailabilityZone -ne $AvailabilityZone -or -not $subnet.MapPublicIpOnLaunch) {
    throw 'Selected subnet must match VPC/AZ and support public addressing'
}
$routes = Invoke-Aws -Arguments @('ec2','describe-route-tables','--filters',"Name=vpc-id,Values=$VpcId")
$tables = @($routes.RouteTables | Where-Object { @($_.Associations | Where-Object { $_.PSObject.Properties['SubnetId'] -and $_.SubnetId -eq $SubnetId }).Count })
if (-not $tables) { $tables = @($routes.RouteTables | Where-Object { @($_.Associations | Where-Object { $_.PSObject.Properties['Main'] -and $_.Main }).Count }) }
if (-not @($tables.Routes | Where-Object {
    $_.DestinationCidrBlock -eq '0.0.0.0/0' -and $_.GatewayId -like 'igw-*' -and $_.State -eq 'active'
})) { throw 'Subnet requires an active internet gateway default route' }
$profileInfo = Invoke-Aws -Arguments @('iam','get-instance-profile','--instance-profile-name',$InstanceProfileName)
$roles = @($profileInfo.InstanceProfile.Roles)
if ($roles.Count -ne 1 -or $roles[0].Arn -ne 'arn:aws:iam::245606545178:role/LabRole') { throw 'Unexpected instance profile role' }
# Metadata only: never get-parameter/decrypt locally.
$parameters = Invoke-Aws -Arguments @('ssm','describe-parameters','--parameter-filters',"Key=Name,Option=Equals,Values=$PasswordParameter")
$issues = [Collections.Generic.List[string]]::new()
if (@($parameters.Parameters).Count -ne 1 -or $parameters.Parameters[0].Type -ne 'SecureString') {
    $issues.Add("Missing SecureString $PasswordParameter (create after review, using the AWS console and aws/ssm key)")
}
$required = @(
    @{Action='ssm:GetParameter';Resource="arn:aws:ssm:us-east-1:245606545178:parameter$PasswordParameter"},
    @{Action='kms:Decrypt';Resource='*'},
    @{Action='ecr:GetAuthorizationToken';Resource='*'},
    @{Action='ecr:BatchGetImage';Resource='arn:aws:ecr:us-east-1:960607644670:repository/app/api'},
    @{Action='ecr:GetDownloadUrlForLayer';Resource='arn:aws:ecr:us-east-1:960607644670:repository/app/api'},
    @{Action='ecr:BatchCheckLayerAvailability';Resource='arn:aws:ecr:us-east-1:960607644670:repository/app/api'},
    @{Action='ecr:BatchGetImage';Resource='arn:aws:ecr:us-east-1:960607644670:repository/app/web'},
    @{Action='ecr:GetDownloadUrlForLayer';Resource='arn:aws:ecr:us-east-1:960607644670:repository/app/web'},
    @{Action='ecr:BatchCheckLayerAvailability';Resource='arn:aws:ecr:us-east-1:960607644670:repository/app/web'}
)
foreach ($permission in $required) {
    $simulation = Invoke-Aws -Arguments @('iam','simulate-principal-policy','--policy-source-arn',$roles[0].Arn,
        '--action-names',$permission.Action,'--resource-arns',$permission.Resource,
        '--context-entries',"ContextKeyName=aws:RequestedRegion,ContextKeyValues=$Region,ContextKeyType=string")
    if ($simulation.EvaluationResults[0].EvalDecision -ne 'allowed') { $issues.Add("LabRole identity permission not allowed: $($permission.Action)") }
}
foreach ($kind in @('api','web')) {
    $image = $release.$kind
    try {
        $details = Invoke-Aws -AwsRegion $release.registryRegion -Arguments @(
            'ecr','describe-images','--registry-id',$release.registryAccount,
            '--repository-name',$image.repository,'--image-ids',"imageDigest=$($image.digest)")
        if (@($details.imageDetails).Count -ne 1 -or $details.imageDetails[0].imageDigest -ne $image.digest) {
            throw "Selected immutable ECR digest missing or mismatched for $kind"
        }
        $pull = Invoke-Aws -AwsRegion $release.registryRegion -Arguments @(
            'ecr','batch-get-image','--registry-id',$release.registryAccount,
            '--repository-name',$image.repository,'--image-ids',"imageDigest=$($image.digest)")
        if (@($pull.images).Count -ne 1 -or @($pull.failures).Count -ne 0) { throw "ECR manifest pull failed for $kind" }
        if ($pull.images[0].imageId.imageDigest -ne $image.digest) { throw "ECR returned wrong index digest for $kind" }
        $null = Assert-StagingImageIndex -ManifestJson $pull.images[0].imageManifest -ExpectedDigest $image.digest -ExpectedRuntimeDigest $image.runtimeDigest
        $child = Invoke-Aws -AwsRegion $release.registryRegion -Arguments @(
            'ecr','batch-get-image','--registry-id',$release.registryAccount,
            '--repository-name',$image.repository,'--image-ids',"imageDigest=$($image.runtimeDigest)")
        if (@($child.images).Count -ne 1 -or @($child.failures).Count -ne 0 -or
            $child.images[0].imageId.imageDigest -ne $image.runtimeDigest) { throw "Missing selected amd64 runtime manifest for $kind" }

    } catch { $issues.Add($_.Exception.Message) }
}
if ($issues.Count) { throw ("Staging preflight blocked before resource creation:`n" + ($issues -join "`n")) }
Write-Host 'Read-only preflight passed: account, template, networking, profile, secret metadata and both ECR digests.'
if ($ValidateOnly) { return }

$stacks = Invoke-Aws -Arguments @('cloudformation','describe-stacks')
$existing = @($stacks.Stacks | Where-Object StackName -eq $StackName)
if ($existing.Count) {
    if (-not @($existing[0].Tags | Where-Object { $_.Key -eq 'Environment' -and $_.Value -eq 'Staging' })) {
        throw 'Existing stack lacks the Staging ownership tag'
    }
    if ($existing[0].StackStatus -notin @('CREATE_COMPLETE','UPDATE_COMPLETE','UPDATE_ROLLBACK_COMPLETE')) {
        throw "Existing Staging stack is not ready: $($existing[0].StackStatus)"
    }
}
if ($ResumeExisting) {
    if ($existing.Count -ne 1) { throw 'ResumeExisting requires an existing owned Staging stack' }
    Write-Host 'ResumeExisting: retaining infrastructure; no CloudFormation change set will be created.'
} else {
$changeSetName = 'staging-' + [guid]::NewGuid().ToString('N')
$parameters = @(
    @{ParameterKey='VpcId';ParameterValue=$VpcId},
    @{ParameterKey='SubnetId';ParameterValue=$SubnetId},
    @{ParameterKey='AvailabilityZone';ParameterValue=$AvailabilityZone},
    @{ParameterKey='InstanceProfileName';ParameterValue=$InstanceProfileName},
    @{ParameterKey='WebCidr';ParameterValue=$WebCidr}
)
$changeType = if ($existing.Count) { 'UPDATE' } else { 'CREATE' }
$null = Invoke-AwsRequest -Arguments @('cloudformation','create-change-set') -Request @{
    StackName=$StackName;ChangeSetName=$changeSetName;ChangeSetType=$changeType
    TemplateBody=[IO.File]::ReadAllText($template);Parameters=$parameters
    Tags=@(@{Key='Environment';Value='Staging'},@{Key='Application';Value='grocery'})
}
try {
    $null = Invoke-Aws -Arguments @('cloudformation','wait','change-set-create-complete','--stack-name',$StackName,'--change-set-name',$changeSetName)
} catch {
    $status = Invoke-Aws -Arguments @('cloudformation','describe-change-set','--stack-name',$StackName,'--change-set-name',$changeSetName)
    if ($changeType -ne 'UPDATE' -or $status.StatusReason -notmatch "didn't contain changes|No updates are to be performed") { throw }
}
$plan = Invoke-Aws -Arguments @('cloudformation','describe-change-set','--stack-name',$StackName,'--change-set-name',$changeSetName)
if ($plan.Status -eq 'CREATE_COMPLETE') {
    foreach ($item in $plan.Changes) {
        $resource = $item.ResourceChange
        if ($resource.ResourceType -notin @('AWS::EC2::Instance','AWS::EC2::SecurityGroup','AWS::EC2::Volume','AWS::EC2::VolumeAttachment') -or
            $resource.Action -eq 'Remove' -or ($resource.Action -eq 'Modify' -and $resource.Replacement -ne 'False')) {
            throw 'Change set contains a removal, replacement or unexpected resource; review manually'
        }
    }
    $null = Invoke-Aws -Arguments @('cloudformation','execute-change-set','--stack-name',$StackName,'--change-set-name',$changeSetName)
    $waiter = if ($changeType -eq 'CREATE') { 'stack-create-complete' } else { 'stack-update-complete' }
    $null = Invoke-Aws -Arguments @('cloudformation','wait',$waiter,'--stack-name',$StackName)
} elseif ($changeType -eq 'UPDATE' -and $plan.StatusReason -match "didn't contain changes|No updates are to be performed") {
    $null = Invoke-Aws -Arguments @('cloudformation','delete-change-set','--stack-name',$StackName,'--change-set-name',$changeSetName)
} else { throw 'Change set is not executable' }
}
$stack = (Invoke-Aws -Arguments @('cloudformation','describe-stacks','--stack-name',$StackName)).Stacks[0]
$outputs = @{}
foreach ($item in $stack.Outputs) { $outputs[$item.OutputKey] = $item.OutputValue }
$instanceId = $outputs.InstanceId
if ($ResumeExisting -and ($instanceId -ne $ExpectedInstanceId -or $outputs.DataVolumeId -ne $ExpectedVolumeId)) {
    throw 'Existing Staging instance or volume differs from the explicit resume target'
}
if ($instanceId -eq 'i-02d58257bb276bbf5') { throw 'Refusing protected test instance' }
$instance = (Invoke-Aws -Arguments @('ec2','describe-instances','--instance-ids',$instanceId)).Reservations[0].Instances[0]
if (-not @($instance.Tags | Where-Object { $_.Key -eq 'aws:cloudformation:stack-id' -and $_.Value -eq $stack.StackId }) -or
    -not @($instance.Tags | Where-Object { $_.Key -eq 'Environment' -and $_.Value -eq 'Staging' })) { throw 'Instance ownership check failed' }
$online = $false
for ($attempt=0; $attempt -lt 120; $attempt++) {
    $ssm = Invoke-Aws -Arguments @('ssm','describe-instance-information','--filters',"Key=InstanceIds,Values=$instanceId")
    if (@($ssm.InstanceInformationList).Count -and $ssm.InstanceInformationList[0].PingStatus -eq 'Online') { $online=$true; break }
    Start-Sleep -Seconds 5
}
if (-not $online) { throw 'Staging instance did not come online in SSM' }
$config = @{
    volumeId=$outputs.DataVolumeId;region=$Region;registry=$release.registry
    registryRegion=$release.registryRegion;release=$release.release;secretParameter=$PasswordParameter
    api="$($release.registry)/$($release.api.repository)@$($release.api.digest)"
    web="$($release.registry)/$($release.web.repository)@$($release.web.digest)"
    postgres=$release.postgres;ciRun=$release.ciRun
}
if ($ResumeExisting) { $config.existingFilesystemUuid = $ExpectedFilesystemUuid }
$commands = [Collections.Generic.List[string]]::new()
$commands.Add('set -euo pipefail')
$commands.Add('exec 8>/run/grocery-staging-upload.lock; flock -n 8')
$commands.Add('cloud-init status --wait >/dev/null')
$commands.Add('install -d -m 700 /opt/grocery-staging')
foreach ($name in @('deploy.sh','secrets.py','verify.py','config.json')) {
    $body = if ($name -eq 'config.json') { $config | ConvertTo-Json -Depth 10 } else { [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)) }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body.Replace("`r`n","`n")))
    $commands.Add("printf '%s' '$encoded' | base64 -d > /opt/grocery-staging/$name")
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body.Replace("`r`n","`n")))).ToLowerInvariant()
    $commands.Add("printf '%s\n' '$hash  /opt/grocery-staging/$name' | sha256sum --check --status")

}
$commands.Add('chmod 600 /opt/grocery-staging/*')
$commands.Add('sha256sum /opt/grocery-staging/deploy.sh /opt/grocery-staging/secrets.py /opt/grocery-staging/verify.py')
$commands.Add('bash /opt/grocery-staging/deploy.sh')
# Explicit Bash because AWS-RunShellScript invokes /bin/sh.
$payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($commands -join "`n")))
$sent = Invoke-AwsRequest -Arguments @('ssm','send-command') -Request @{
    InstanceIds=@($instanceId);DocumentName='AWS-RunShellScript';TimeoutSeconds=1800
    Comment="Deploy grocery-staging $($release.release)"
    Parameters=@{commands=@("printf '%s' '$payload' | base64 -d | bash");executionTimeout=@('1800')}
}
$commandId = $sent.Command.CommandId
Write-Host "SSM command: $commandId; instance: $instanceId"
$null = Wait-StagingCommand -GetInvocation {
    Invoke-Aws -Arguments @('ssm','get-command-invocation','--command-id',$commandId,'--instance-id',$instanceId,
        '--query','{Status:Status,ResponseCode:ResponseCode}')
}
$receipt = $config + @{instanceId=$instanceId;stackId=$stack.StackId;commandId=$commandId;webUrl=$outputs.WebUrl;deployedAt=[DateTime]::UtcNow.ToString('o')}
$receiptPath = Join-Path ([IO.Path]::GetTempPath()) ("grocery-staging-release-" + $commandId + '.json')
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 10))
Write-Host "Staging deployment successful: $($outputs.WebUrl). Release receipt: $receiptPath"

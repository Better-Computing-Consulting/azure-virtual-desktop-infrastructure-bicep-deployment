param (
    [string]$projectId = $(throw "-projectId is required.")
)

Update-AzConfig -DisplayBreakingChangeWarning $false | out-null
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'
$rgName = $projectId + "-RG"

function Show-PoolHosts{
    ""
    $currentHosts = Get-AzWvdSessionHost `
        -ResourceGroupName $rgName `
        -HostPoolName $outputs.hostPoolName.value

    $format = "{0,-35}{1,-13}{2,-10}{3,-15}{4}"
    $format -f "Name", "Status", "Sessions", "Image Version", "VM Power State"

    foreach ($ahost in $currentHosts){ 
        $vmPowerState = (Get-AzVM -ResourceId $ahost.ResourceId -Status).Statuses[1].Code
        $imgVer = (Get-AzVM -ResourceId $ahost.ResourceId).StorageProfile.ImageReference.ExactVersion
        $format -f $ahost.Name, $ahost.Status, $ahost.Session, $imgVer, $vmPowerState 
    }
    ""
}
#
# Validate VDI environment and get needed outputs
#
$context = get-azcontext
if ($context.Account.Type -eq 'User'){
    $userObjectId = $context.Account.ExtendedProperties.HomeAccountId.Split('.')[0]
} 
elseif ($context.Account.Type -eq 'ServicePrincipal') {
    $userObjectId = (Get-AzADServicePrincipal -ApplicationId $context.Account.Id).id
}
else{
    throw "Current user account type is neither User or ServicePrincipal. Re-run Connect-AzAccount."
}
$deploymentName = "VDIdeployment-" + (get-date).ToString('yyyyMMddHHmm')
$outputs = (New-AzResourceGroupDeployment -ResourceGroupName $rgName `
    -Name $deploymentName `
    -TemplateFile '.\vdi.bicep' `
    -projectId $projectId `
    -tenantId $context.Tenant.Id `
    -keyVaultUser $userObjectId).Outputs

Show-PoolHosts

#
# Determine what is the latest golden image version in the Gallery.
#
$imgVersions = Get-AzGalleryImageVersion `
    -ResourceGroupName $rgName `
    -GalleryName $outputs.galleryName.value `
    -GalleryImageDefinitionName $outputs.imageName.value

$latestImage = $imgVersions | Select-Object -first 1

foreach ($ver in $imgVersions){
    if ($latestImage.PublishingProfile.PublishedDate -lt $ver.PublishingProfile.PublishedDate){
        $latestImage = $ver
    }
}
"Latest image version: " + $latestImage.Name

#
# Determine how many of the current hosts were deployed using and older image version.
#
$hostsToReplace = @()

$activeHosts = Get-AzWvdSessionHost `
    -ResourceGroupName $rgName `
    -HostPoolName $outputs.hostPoolName.value `
    | Where-Object {$_.AllowNewSession -eq $true} 

foreach ($ahost in $activeHosts){ 
        $vm = Get-AzVM -ResourceId $ahost.ResourceId
        $vm.Name + " version: " + $vm.StorageProfile.ImageReference.ExactVersion
        if ($vm.StorageProfile.ImageReference.ExactVersion -ne $latestImage.name){
            $hostsToReplace += $ahost
        }
}

#
# If there are no hosts created with an older image version, end the script.
#
if ( $hostsToReplace.Count -eq 0 ){ 
    "All host are at the latest image version"
    Exit 
}
"Number of hosts to replace: " + $hostsToReplace.Count

#
# Get the information required to deploy new hosts, i.e, Pool registration key, Username and Password.
#
$hpToken = New-AzWvdRegistrationInfo `
    -ResourceGroupName $rgName `
    -HostPoolName $outputs.hostPoolName.value `
    -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))

"Issued and retrieved hostpool registration token"

#
# Momentarily allow public network access to the KeyVault.
#
Update-AzKeyVaultNetworkRuleSet -DefaultAction Allow -VaultName $outputs.keyVaultName.value -WarningAction Ignore
"Set keyVault DefaultAction to Allow"

$vdiHostAdminUsername = Get-AzKeyVaultSecret -VaultName $outputs.keyVaultName.value -Name vdiHostAdminUsername -AsPlainText `
    -ErrorAction SilentlyContinue -ErrorVariable kvError
$textPassword = Get-AzKeyVaultSecret -VaultName $outputs.keyVaultName.value -Name vdiHostAdminPassword -AsPlainText `
    -ErrorAction SilentlyContinue -ErrorVariable +kvError

#
# Sometimes it takes a few seconds for the DefaultAction to take effect, so we retry.
#
while ($kvError.Count -ne 0) {
    $vdiHostAdminUsername = Get-AzKeyVaultSecret -VaultName $outputs.keyVaultName.value -Name vdiHostAdminUsername -AsPlainText `
        -ErrorAction SilentlyContinue -ErrorVariable kvError
    $textPassword = Get-AzKeyVaultSecret -VaultName $outputs.keyVaultName.value -Name vdiHostAdminPassword -AsPlainText `
        -ErrorAction SilentlyContinue -ErrorVariable +kvError
}
"Retrieved vm admin username and password from KeyVault"

Update-AzKeyVaultNetworkRuleSet -DefaultAction Deny -VaultName $outputs.keyVaultName.value

"Set keyVault DefaultAction to Deny"

$vdiHostAdminPassword = ConvertTo-SecureString $textPassword -AsPlainText -Force

$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $rgName -Name $outputs.storageAccountName.value)[0].Value

"Retrieved storage account key"

$storageAccountKeySecure = ConvertTo-SecureString $storageAccountKey -AsPlainText -Force

#
# Upload the script that the CustomScriptExtension will use to add the vm to the hostpool
#
$context = New-AzStoragecontext -StorageAccountName $outputs.storageAccountName.value -StorageAccountKey $storageAccountKey

#
# Momentarily allow public network access to the storage account.
# The user uploading must have access from RBAC, SAS key or access token.
#
$newDefault = Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $rgName -Name $outputs.storageAccountName.value `
    -DefaultAction Allow 

"Changed storage account DefaultAction to " + $newDefault.DefaultAction

$upload = (Set-AzStorageBlobContent -Container "scripts" -File ".\setWVDClient.ps1" -Blob "setWVDClient.ps1" -context $context `
    -Force -ErrorAction SilentlyContinue -ErrorVariable saError)
#
# Sometimes it takes a few seconds for new default action to take effect, so we retry the upload.
#
while ($saError.Count -ne 0) {
    Start-Sleep -Seconds 5
    "Retrying file upload..."
    $upload = (Set-AzStorageBlobContent -Container "scripts" -File ".\setWVDClient.ps1" -Blob "setWVDClient.ps1" -context $context `
        -Force -ErrorAction SilentlyContinue -ErrorVariable saError)
}
"Uploaded to blob storage script " + $upload.Name + " to add VMs to hostpool."

#
# Upload done. Change back the default action to Deny.
#
$newDefault = Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $rgName -Name $outputs.storageAccountName.value `
    -DefaultAction Deny 

"Changed storage account DefaultAction to " + $newDefault.DefaultAction

$fileUri = $outputs.blobEndpoint.value + "scripts/setWVDClient.ps1"

#
# Deploy hostpool VMs based on the latest golden image.
#
"Deploying " + $hostsToReplace.Count + " replacement hostpool VMs"

$vmName = "hp" + (get-date).ToString('ddHHmm') + "v" + $latestImage.name.Replace(".","")
$deploymentName = "hostPoolVMdeployment-" + (get-date).ToString('yyyyMMddHHmm')
$deployment = New-AzResourceGroupDeployment -ResourceGroupName $rgName `
    -Name $deploymentName `
    -TemplateFile '.\vm.bicep' `
    -vmName $vmName `
    -vmType 'hostPool' `
    -vmCount $hostsToReplace.Count `
    -adminUserName $vdiHostAdminUsername `
    -adminPassword $vdiHostAdminPassword `
    -subnetId $outputs.subnetId.value `
    -osImageId $latestImage.id `
    -storageAccountName $outputs.storageAccountName.value `
    -storageAccountKey $storageAccountKeySecure `
    -fileUri $fileUri `
    -registrationToken $hpToken.Token

$deployment.DeploymentName + " " + $deployment.ProvisioningState

#
# Disable and deallocate previous-version hosts.
#
foreach ($shost in $hostsToReplace){ 

    $vm = Get-AzVM -ResourceId $shost.ResourceId
    "Disabling new sessions on VM: " + $vm.Name

    Update-AzWvdSessionHost `
        -ResourceGroupName $rgName `
        -HostPoolName $outputs.hostPoolName.value `
        -Name $vm.Name `
        -AllowNewSession:$false `
        | Select-Object Name, Session, Status, AllowNewSession | Format-Table

    if ($shost.Session -eq 0){
        "Stopping VM: " + $vm.Name
        Stop-AzVM -Id $vm.Id -Force | Select-Object Status
    }
}

Show-PoolHosts

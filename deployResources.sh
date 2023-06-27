#!/bin/bash

set -ev

SECONDS=0
projectId=bccVDIDemo01

echo $'\e[1;33m'$projectId$'\e[0m'

location="westus"
rgName=$projectId-RG

az config set defaults.location=$location defaults.group=$rgName core.output=tsv --only-show-errors

az group create -n $rgName -o none

#
# List resources before deployment. There should be none.
#
az resource list --query "[].{Name:name, Type:type}" -o table

#
# Deploy VDI infrastructure and get needed outputs for the remainder of the script.
#
tenantId=$(az account show --query tenantId)
userName=$(az account show --query user.name)
userObjectId=$(az ad user show --id $userName --query id)

outputs=$(az deployment group create \
    --name VDIdeployment-$(date +%Y%m%d%H%M) \
    --template-file vdi.bicep \
    --parameters \
        projectId=$projectId \
        tenantId=$tenantId \
        keyVaultUser=$userObjectId \
    --query properties.outputs -o json)

galleryName=$(jq -r .galleryName.value <<< "$outputs")
imageName=$(jq -r .imageName.value <<< "$outputs")
keyVaultName=$(jq -r .keyVaultName.value <<< "$outputs")
subnetId=$(jq -r .subnetId.value <<< "$outputs")
storageAccountName=$(jq -r .storageAccountName.value <<< "$outputs")
blobEndpoint=$(jq -r .blobEndpoint.value <<< "$outputs")
hostPoolName=$(jq -r .hostPoolName.value <<< "$outputs")

#
# List resources after deployment.
#
az resource list --query "[].{Name:name, Type:type}" -o table

#
# Create random password for the vm administrator account, then
# save it in the KeyVault.
#
vdiHostAdminUsername=vdivmadmin
vdiHostAdminPassword=$(openssl rand -base64 8)

#
# Momentarily allowing public network access.
#
az keyvault update --name $keyVaultName --default-action Allow -o none

set +e
az keyvault secret set --vault-name $keyVaultName --name vdiHostAdminUsername --value $vdiHostAdminUsername -o none
kvErrors=$?
az keyvault secret set --vault-name $keyVaultName --name vdiHostAdminPassword --value $vdiHostAdminPassword -o none
kvErrors=$(( $kvErrors + $? ))

#
# Sometimes it takes a few seconds for the new default action to take effect, so we retry.
#
while [ $kvErrors -ne 0 ]; do
    sleep 5
    echo "Retrying saving secrets..."
    az keyvault secret set --vault-name $keyVaultName --name vdiHostAdminUsername --value $vdiHostAdminUsername -o none
    kvErrors=$?
    az keyvault secret set --vault-name $keyVaultName --name vdiHostAdminPassword --value $vdiHostAdminPassword -o none
    kvErrors=$(( $kvErrors + $? ))  
done
set -e

#
# Re-disable public network access to the KeyVault.
#
az keyvault update --name $keyVaultName --default-action Deny -o none

#
# Deploy the first version temporary VM.
#
outputs=$(az deployment group create \
    --name firstVersionVMdeployment-$(date +%Y%m%d%H%M) \
    --template-file vm.bicep \
    --parameters \
        vmType=firstVersion \
        adminUserName=$vdiHostAdminUsername \
        adminPassword=$vdiHostAdminPassword \
        subnetId=$subnetId \
    --query properties.outputs -o json)

vmId=$(jq -r .vmId.value <<< "$outputs")
osDiskId=$(jq -r .osDiskId.value <<< "$outputs")

connStr=$(az storage account show-connection-string -n $storageAccountName)

#
# Remote execute the script to configure FSLogix and OneDrive on the temp vm.
#
cmdResult=$(az vm run-command invoke \
    --command-id RunPowerShellScript \
    --ids $vmId \
	--scripts @setFSLogixOneDrive.ps1 \
	--parameters "connectionString=$connStr" "tennantId=$tenantId" \
	--query value[0].message)

sed 's/\\n/\'$'\n''/g' <<< $(sed "s|$tenantId|xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx|g" <<< $cmdResult)

az vm restart --ids $vmId

#
# Get snapshot of temp vm to later create updated image versions, and sysprep the vm.
#
az snapshot create -n imagevm-OSDisk-snapshot-$(date +%Y%m%d%H%M) --source $osDiskId --hyper-v-generation V2 -o none

az vm run-command invoke --command-id RunPowerShellScript --ids $vmId --scripts @sysprepVM.ps1 -o jsonc

vmState=$(az vm get-instance-view --ids $vmId --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus")
while [ "$vmState" != "VM stopped" ]
do
	echo $vmState
	sleep 2
	vmState=$(az vm get-instance-view --ids $vmId --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus")
done

az vm deallocate --ids $vmId
az vm generalize --ids $vmId

#
# Create the firt golden image version for the hospool servers.
#
imgId=$(az sig image-version create  -r $galleryName -i $imageName -e 0.1.0 --virtual-machine $vmId --query id)

az vm delete --ids $vmId --force-deletion yes -y

#
# Upload to blob storage the script that joins the servers to the hostpol.
#
export AZURE_STORAGE_KEY=$(az storage account keys list --account-name $storageAccountName --query [0].value)
export AZURE_STORAGE_ACCOUNT=$storageAccountName

#
# Momentarily enable uploads from any ip. The user uploading must have access from RBAC, SAS key or access token.
#
az storage account update --name $storageAccountName --default-action Allow -o none --only-show-errors

set +e
az storage blob upload -c scripts -n setWVDClient.ps1 -f setWVDClient.ps1 --overwrite --auth-mode key >/dev/null 2>&1

#
# Sometimes it takes a few seconds for new default action to take effect, so we retry the upload.
#
while [ $? -ne 0 ]; do
    sleep 5
    echo "Retrying file upload..."
    az storage blob upload -c scripts -n setWVDClient.ps1 -f setWVDClient.ps1 --overwrite --auth-mode key >/dev/null 2>&1
done
set -e

#
# Upload done. Change back the default action to Deny.
#
az storage account update --name $storageAccountName --default-action Deny -o none --only-show-errors

#
# Get a hostpool registration key.
#
hpToken=$(az desktopvirtualization hostpool update \
	--name $hostPoolName \
	--registration-info \
		expiration-time=$(date +"%Y-%m-%dT%H:%M:%S.%7NZ" -d "$DATE + 1 day") \
		registration-token-operation="Update" \
	--query registrationInfo.token)

#
# Deploy two hostpool servers.
#
vmName=hp$(date +%d%H%M)v010

az deployment group create \
    --name hostPoolVMdeployment-$(date +%Y%m%d%H%M) \
    --template-file vm.bicep \
    --parameters \
        vmName=$vmName \
        vmType=hostPool \
        vmCount=2 \
        adminUserName=$vdiHostAdminUsername \
        adminPassword=$vdiHostAdminPassword \
        subnetId=$subnetId \
        osImageId=$imgId \
        storageAccountName=$storageAccountName \
        storageAccountKey=$AZURE_STORAGE_KEY \
        fileUri=${blobEndpoint}scripts/setWVDClient.ps1 \
        registrationToken=$hpToken \
    --query "{Name:name, ProvisioningState:properties.provisioningState}" -o table

#
# Display information about the new hostpool VMs.
#
az vm list --query "[].{Name:name, ImageVersion:storageProfile.imageReference.exactVersion}" -o table

#
# Display information about all bicep deployments in the script.
#
az deployment group list -o table

az config unset defaults.location defaults.group core.output --only-show-errors

duration=$SECONDS
echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

set +v
echo To grant a test user access to the Application Group and VDI hosts run:
echo
echo $'\e[1;33m'./addAssignment.sh $projectId '<testUserUPN>'$'\e[0m'
echo
echo To deploy the DevOps project with pipelines to automate update and replacement of vdi hosts run:
echo
echo $'\e[1;33m'az login$'\e[0m'
echo $'\e[1;33m'export AZURE_DEVOPS_EXT_GITHUB_PAT=enter-github-pat-here$'\e[0m'
echo $'\e[1;33m'./deployDevOpsProject.sh $projectId '<URL of Azure DevOps organization>' '<URL of cloned GitHub repository>' $'\e[0m' 
echo
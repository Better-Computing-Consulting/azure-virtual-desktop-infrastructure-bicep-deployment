#!/bin/bash

if [ -z "$2" ]; then
	echo "Pass projectId and path to Powershell script"
	exit
fi

set -ev

SECONDS=0
location="westus"
rgName=$1-RG

az config set defaults.location=$location defaults.group=$rgName core.output=tsv --only-show-errors

#
# Validate VDI environment and get needed outputs
#
outputs=$(az deployment group create \
    --name VDIdeployment-$(date +%Y%m%d%H%M) \
    --template-file vdi.bicep \
    --parameters \
        projectId=$1 \
        updateAccess=false \
    --query properties.outputs -o json)

galleryName=$(jq -r .galleryName.value <<< "$outputs")
imageName=$(jq -r .imageName.value <<< "$outputs")
subnetId=$(jq -r .subnetId.value <<< "$outputs")

az snapshot list --query "[].{Name:name, TimeCreated:timeCreated}" -o table

az sig image-version list -r $galleryName -i $imageName -o table

#
# Get the id of the most recent snapshot, i.e., the one with highest created time.
# Then create a VM by passing the snapshot id as a parameter to the vm.bicep script.
#
ssId=$(az snapshot list --query "[max_by(@, &timeCreated).id]")

outputs=$(az deployment group create \
    --name newVersionVMdeployment-$(date +%Y%m%d%H%M) \
    --template-file vm.bicep \
    --parameters \
        vmType=newVersion \
        snapshotId=$ssId \
        subnetId=$subnetId \
    --query properties.outputs -o json)

vmId=$(jq -r .vmId.value <<< "$outputs")
osDiskId=$(jq -r .osDiskId.value <<< "$outputs")

#
# Run the powershell script that will further customize the what will be the next version of the golden image
#	
cmdResult=$(az vm run-command invoke --command-id RunPowerShellScript --ids $vmId --scripts @"$2" --query value[0].message)

sed 's/\\n/\'$'\n''/g' <<< $cmdResult

#
# Reboot the computer, prior to remotely submitting powershell scrip to Sysprep server. 
# Take a snapshot of the disk to use in the next customization of the image, 
# then dealocate and generalize the vm in prepartion to image capture.
#
az vm restart --ids $vmId

az vm get-instance-view --ids $vmId --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus" -o jsonc

az snapshot create -n imagevm-OSDisk-snapshot-$(date +%Y%m%d%H%M) --source $osDiskId --hyper-v-generation V2 --output none

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
# Increment the patch numeber of the image version in the variable that we pass to the command that creates the new image version.
# And lastly, delete the vm.
#
latestversion=$(az sig image-version list -r $galleryName -i $imageName --query "[max_by(@, &publishingProfile.publishedDate).name]")

parts=(${latestversion//./ })
nextVersion=${parts[0]}.${parts[1]}.$((parts[2]+1))

az sig image-version create  -r $galleryName -i $imageName -e $nextVersion --virtual-machine $vmId --output none

az vm delete --ids $vmId --force-deletion yes -y

az snapshot list --query "[].{Name:name, TimeCreated:timeCreated}" -o table

az sig image-version list -r $galleryName -i $imageName -o table

az config unset defaults.location defaults.group core.output --only-show-errors

duration=$SECONDS
echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

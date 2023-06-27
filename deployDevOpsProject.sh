#!/bin/bash

if [ -z "$3" ]; then
	echo "Pass:"
	echo "  1) projectId"
	echo "  2) URL of DevOps organization, and"
	echo "  3) URL of your clone of the github repository"
	exit
fi

set -ev

SECONDS=0
rgName=$1-RG

az config set defaults.group=$rgName core.output=tsv --only-show-errors

#
# Deploy DevOps Project and Pipelines
#
# Register Azure Service Principal for the pipelines with enough rights to deploy virtual machines,
# assign managed identities, and add them to hostpool scoped to the project's resource group.
#
spName=$1-sp
rgId=$(az group show --query id)
spKey=$(az ad sp create-for-rbac \
	--name $spName \
	--role "Contributor" \
	--scopes $rgId --only-show-errors --query password)

#
# Must run az login before running the script and export your github personal access token to
# the enviroment variable for a completely unattended run of the script
#
# az login
#
# export AZURE_DEVOPS_EXT_GITHUB_PAT=enter-github-pat-here
#
export AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY=$spKey

az extension add --upgrade -n azure-devops --only-show-errors

az devops configure --defaults project=$1 organization=$2

# Create Azure DevOps project
az devops project create --name $1 -o none

# Create AzureRM service endpoint
spClientId=$(az ad sp list --display-name $spName --query [].appId)
subsId=$(az account show --query id)
subsName=$(az account show --query name)
tenantId=$(az account show --query tenantId)

azRMSvcId=$(az devops service-endpoint azurerm create \
	--name AzureServiceConnection \
	--azure-rm-service-principal-id $spClientId \
	--azure-rm-subscription-id $subsId \
	--azure-rm-subscription-name "$subsName" \
	--azure-rm-tenant-id $tenantId --query id)

# Enable AzureRM service endpoint for all pipelines
az devops service-endpoint update --id $azRMSvcId --enable-for-all true -o none

# Create GitHub service endpoint
gitHubSvcId=$(az devops service-endpoint github create \
    --github-url https://github.com/ \
    --name GitHubService --query id)

# Enable Github service endpoint for all pipelines
az devops service-endpoint update --id $gitHubSvcId --enable-for-all true -o none

# Create triggered update golden image pipeline
pipelineId=$(az pipelines create \
	--name TriggeredUpdateImagePipeline \
	--repository $3 \
	--branch main \
	--yml-path update-image.yml \
	--skip-first-run true \
	--service-connection $gitHubSvcId --only-show-errors --query id)

usrName=$(az account show --query user.name)

az pipelines variable create --name GitHubUser --value $usrName --pipeline-id $pipelineId -o none

# Create cron deploy latest image pipeline
pipelineId=$(az pipelines create \
    --name CronDeployImagePipeline \
    --repository $3 \
    --branch main \
    --yml-path deploy-image.yml \
    --skip-first-run true \
    --service-connection $gitHubSvcId --only-show-errors --query id)

# Create triggered update infrastructure pipeline
pipelineId=$(az pipelines create \
    --name TriggeredUpdateInfrastructurePipeline \
    --repository $3 \
    --branch main \
    --yml-path update-infrastructure.yml \
    --skip-first-run true \
    --service-connection $gitHubSvcId --only-show-errors --query id)

az devops configure --defaults project="" organization=""
az config unset defaults.group=$rgName core.output --only-show-errors

duration=$SECONDS
echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

set +v
parts=(${2///// })
orgonly=$(echo "${parts[3]}" | sed 's:/*$::')
echo Manually grant $'\e[1;33m''Bypass policies when pushing'$'\e[0m' and $'\e[1;33m''Contribute'$'\e[0m' rights to the $'\e[1;33m'$1 Build Service \($orgonly\)$'\e[0m' user account
echo under $'\e[1;33m'Project settings \> Repositories \> Security$'\e[0m':
echo
echo $'\e[1;33m'https://dev.azure.com/$orgonly/$1/_settings/repositories?_a=permissions$'\e[0m' 
echo

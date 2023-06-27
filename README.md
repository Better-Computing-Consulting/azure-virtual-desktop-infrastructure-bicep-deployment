# azure-virtual-desktop-infrastructure-bicep-deployment

This project will deploy an Azure Virtual Desktop infrastructure (VDI), including a Compute Gallery with a custom golden image, hostpool hosts, and an Azure DevOps project with three pipelines. One pipeline is triggered saving a new PowerShell onto the new_scrips directory. This pipeline will create a new version of the golden image by running the dropped script on a newly deployed a VM based on the most recent snapshot in the project's resource group. Each snapshot made right before running sysprep on the host from which the previous golden image version was created. The second pipeline runs on a schedule and will replace the existing hosts in the virtual desktop host pool, if they were created from an older golden image version. The third pipeline is triggered when the bicep file that deploys the VDI is updated.

This project is functionally the same as our previous project azure-virtual-desktop-infrastructure-deployment. 

https://github.com/Better-Computing-Consulting/azure-virtual-desktop-infrastructure-deployment

The main difference is that while the previous project all deployments were done with AZ CLI or PowerShell commands, in this project all deployments, both infrastructure components and VMs, are made with bicep files. This allows for easier maintenance of the VDI infrastructure and asserting the state of the infrastructure right before deploying new versions of the golden image or new VMs to the hostpool.

These are some of the features of the Virtual Desktop infrastructure:
+ The OS of the hostpool servers is Windows 11 multisession.
+ The servers are joined to Azure Active Directory (AAD), so cloud-only accounts can log onto them.
+ The initial golden image for the servers is configured with FSLogix profiles using blob storage.
+ Line of sight to on-prem Active Directory is not required for user login or FSLogix profile redirection.
+ The connection string for the storage account containing the FSLogix profiles is stored in the server on a secure key. Thus, the connection string is not visible to users or administrators logged on to the server.
+ The initial golden image of the servers is also configured with automatic logon to OneDrive and silent redirection of users’ Document, Desktop and Pictures folders.
+ There is a private endpoint connection between the storage account and the subnet of the hostpool server, so connections to the FSLogix containers travel through Microsoft’s backbone.
+ The storage account has a Network Rule to allow connections only from the subnet containing the hostpool servers.
      
> :warning: To successfully run the scripts the user should have sufficient permissions to 1) deploy new resource groups and resources, 2) assign managed identities, create custom roles and service principals, and 3) create new DevOps projects.

## deployResources.sh

To deploy the Virtual Desktop infrastructure run the **deployResources.sh**. This script will:

1.	Deploy the Resource group for the project.
2.	Create a deployment with the **vdi.bicep** file to deploy the VDI infrastructure: VNet, storage account for the FSLogix containers, subnet and storage account network rules, private endpoint between the storage account and hostpool VMs subnet, shared image gallery, image definition, Desktop virtualization hostpool, application group and workspace, and a KeyVault.
3.  Create administrator username and password that will be used for the all the VMs in the project and stores them in the KeyVault.
4.	Create a deployment with the **vm.bicep** file to deploy a temporary VM. The **vm.bicep** file takes as **vmType** parameter **firstVersion** to create a VM using a marketplace image of Windows 11 multiuser.
5.	Install and configure FSLogix and OneDrive on the VM by remote executing the **setFSLogixOneDrive.ps1** script, which takes as arguments the storage account connection string and the tenant id.
6.	Create a snapshot of the VM’s OS disk.
7.	Run **sysprep** on the VM by remote executing the **sysprepVM.ps1** script.
8.	Deallocate and generalize the VM.
9.	Create the first version of the image definition by capturing the temporary VM.
10. Delete the temporary VM.
11. Get the access key for the storage account.
12. Upload the **setWVDClient.ps1** script to the storage account. The **setWVDClient.ps1** adds the VM to the hostpool.
13. Request a registration token from the hostpool.
14.	Finally, create a deployment with the **vm.bicep** file to deploy hostpool VMs. The **vm.bicep** file takes as **vmType** parameter **hostPool** to create each VM with *Managed Identity*, joined to AAD and added to the hostpool. Other parameters are the number of VMs to deploy, the id of the new golden image definition, the hostpool registration token, and the URI of the **setWVDClient.ps1** script and the access key to the storage account.

## addAssignment.sh

When the **deployResources.sh** ends you can grant access to users to the virtual desktop by running the **addAssignment.sh** script, which takes the project id and the user UPN as arguments. This script will:

1.	Assign *Virtual Machine User Login* to the user at the resource group level. This allows the user to remote login to Azure Active Directory joined server.
2.	Assign *Desktop Virtualization User* to the user the application group level, so the get the Virtual Desktop assigned.

## updateImage.sh

To create a new golden image version the repository includes an **updateImage.sh** script. The script takes the project id and the path to a PowerShell script to add software or configuration to the image. The **updateImage.sh** script will:

1.  Create a deployment with the **vdi.bicep** file to assert the VDI infrastructure and get all the outputs required for the execution of the script.
2.  Get the id of the most recent snapshot in the project's resource group.
3.	Create a deployment with the **vm.bicep** file to deploy a temporary VM. The **vm.bicep** file takes as **vmType** parameter **newVersion** to create a VM based on the snapshot that is passed as another parameter.
4.	Remotely execute the provided PowerShell script to install additional software or configurations.
5.	Take a new snapshot of the OS disk.
6.	Run **sysprep** on the VM by remote executing the **sysprepVM.ps1** script.
7.	Deallocate and generalize the VM.
8.	Finally, capture the VM as the next version of the image definition in the gallery.
9.	(The repository includes a **setOffice365.ps1** script under the **done_scripts** folder to test this functionality. It will install Office 365 on the target computer.)

## deployNewImage.ps1

To replace existing VMs in the hostpool that were created with an older golden image version the repository includes a **deployNewImage.ps1** PowerShell script. This script takes the project id as an argument and will:

1.  Create a deployment with the **vdi.bicep** file to assert the VDI infrastructure and get all the outputs required for the execution of the script.
2.	Get the latest image definition version from the gallery.
3.	Get a list of hostpool servers based on an older version of the image. If there are no older version servers, the script will exit. Otherwise, the script will:
4. Request a registration token from the hostpool.
5.	Get the administrator username and password from the KeyVault.
6. Get the access key for the storage account.
7. Upload the **setWVDClient.ps1** script to the storage account. The **setWVDClient.ps1** adds the VM to the hostpool.
8. Create a deployment with the **vm.bicep** file to deploy replacement hostpool VMs. For the **vmCount** parameter the script passes the count of the list of older version servers. The **vm.bicep** file also takes as **vmType** parameter **hostPool** to create each VM with *Managed Identity*, joined to AAD and added it to the hostpool. Other parameters are the id of the latest golden image definition, the hostpool registration token, and the URI of the **setWVDClient.ps1** script and the access key to the storage account.
9.	Finally, disable connections to the old servers and deallocate them.

## deployDevOpsProject.sh

Both the **updateImage.sh** and **deployNewImage.ps1** can be run manually. However, the repository also includes a **deployDevOpsProject.sh** script which will deploy a DevOps project that contains two pipelines to run these scripts. The pipeline that run the **updateImage.sh** is triggered by saving a new **.ps1** script onto the **new_scrips** directory. The pipeline that runs the **deployNewImage.ps1** runs on a schedule. The script will also add a pipeline to update the VDI infrastructure by creating a deployment based on the **vdi.bicep**. This last pipeline is triggered when the **vdi.bicep** file changes.

> :warning: **An important note** relating to the update image pipeline. For it to work, after deploying the DevOps project you must **manually grant** ***Bypass policies when pushing*** and ***Contribute*** rights to the Project's **Build Service _User_ account** under **Project settings > Repositories > Security**. Otherwise, the GitHub command that commits the move of the script from the **new_script** to the **done_script** folder will fail.

The **deployDevOpsProject.sh** takes three arguments, the project’s id, the URL of your DevOps organization, and the URL of your clone of the GitHub repository. Before running the script, you should run **az login** again and export your GitHub *Personal Access Token* to the environment with the **AZURE_DEVOPS_EXT_GITHUB_PAT=enter-github-pat-here** command. The script will:

1.	Create a service account with the Contributor role scoped to the project’s resource group.
2.	Create a DevOps project.
3.	Create a service endpoint for Azure.
4.	Create a service endpoint for GitHub.
5.	Create the update image pipeline based on the **update-image.yml** script.
6.	Create a variable for the pipeline with the username of the account running the script, to set the email of the GitHub user for the git commands.
7.	Create the deploy image pipeline based on the **deploy-image.yml** script.
8. Finally, create an update VDI environment pipeline based on the **update-infrastructure.yml** script.

I hope you find this project useful. 

Enjoy.

:smiley:

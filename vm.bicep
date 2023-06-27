@description('Location for all resources.')
param location string = resourceGroup().location

@description('Types of VMs to deploy.')
@allowed([
  'hostPool'
  'firstVersion'
  'newVersion'
])
param vmType string

@description('Size of the VM.')
@allowed([
  'Standard_DS1_v2'
  'Standard_D2s_v3'
  'Standard_D8s_v5'
  'Standard_F8s_v2'
  'Standard_D8as_v4'
  'Standard_D16s_v5'
])
param vmSize string = 'Standard_DS1_v2'

@description('VM name prefix')
param vmName string = 'imagevm'

@description('Number of VMs to deploy.')
param vmCount int = 1

@description('VM administrator username needed for vmType hostPool or firstVersion')
param adminUserName string = ''

@description('VM administrator password needed for vmType hostPool or firstVersion')
@secure()
param adminPassword string = ''

@description('Snapshot id needed for vmType newVersion')
param snapshotId string = ''

@description('OS image version id needed for vmType hostPool')
param osImageId string = ''

@description('Hostpool registration token is needed for vmType hostPool')
param registrationToken string = ''

@description('Storage account name is needed for vmType hostPool')
param storageAccountName string = ''

@description('Storage account key is needed for vmType hostPool')
@secure()
param storageAccountKey string = ''

@description('setWVDClient.ps1 powershell script URI is needed for vmType hostPool')
param fileUri string = ''

@description('Id of destination subnet for the VM')
param subnetId string

@description('Definition of the properties for each kind of VM')
var properties = [for i in range(0, vmCount): {
  hostPool: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: networkProfile[i]
    storageProfile: {
      imageReference: {
        id: osImageId
      }
      osDisk: {
        osType: 'Windows'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      } 
    }
    osProfile: osProfile[i]
    licenseType: 'Windows_Client'
  }
  firstVersion: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: networkProfile[i]
    storageProfile:{
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-22h2-avd'
        version: 'latest'
      }
      osDisk: {
        osType: 'Windows'
        createOption: 'FromImage'
        caching: 'None'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    osProfile: osProfile[i]
  }
  newVersion: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: networkProfile[i]
    storageProfile: {
      osDisk: {
        osType: 'Windows'
        createOption: 'Attach'
        caching: 'None'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
          id: disk[i].id
        }
        deleteOption: 'Delete'
      }
    }
  }
}]

@description('networkProfile is the same for all VM kinds')
var networkProfile = [for i in range(0, vmCount): {
  networkInterfaces: [
    {
      id: networkInterface[i].id
      properties: {
        deleteOption: 'Delete'
      }
    }
  ]
}]

@description('osProfile is the same for VM kinds hostPool and firstVersion')
var osProfile = [for i in range(0, vmCount): {
  computerName: '${vmName}-${i}'
  adminUsername: adminUserName
  adminPassword: adminPassword
  windowsConfiguration: {
    provisionVMAgent: true
    enableAutomaticUpdates: false
    patchSettings: {
      patchMode: 'Manual'
      assessmentMode: 'ImageDefault'
    }
    enableVMAgentPlatformUpdates: false
  }
  allowExtensionOperations: true
}]

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-03-01' = [for i in range(0, vmCount): {
  name: '${vmName}-${i}' 
  location: location
  identity:{
    type: (vmType == 'hostPool') ? 'SystemAssigned' : 'None'
  }
  properties: properties[i][vmType]
}]

resource AADLoginForWindows 'Microsoft.Compute/virtualMachines/extensions@2022-11-01' = [for i in range(0, vmCount): if (vmType == 'hostPool') {
  name: 'AADLoginForWindows'
  parent: virtualMachine[i]
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}]

resource customScriptExtension 'Microsoft.Compute/virtualMachines/extensions@2022-11-01' = [for i in range(0, vmCount): if (vmType == 'hostPool') {
  name: 'CustomScriptExtension'
  parent: virtualMachine[i]
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File setWVDClient.ps1 -registrationtoken ${registrationToken}'
      storageAccountName: storageAccountName
      storageAccountKey: storageAccountKey
      fileUris: [ 
        fileUri
      ]
    }
  }
} ] 

resource networkInterface 'Microsoft.Network/networkInterfaces@2022-11-01' = [for i in range(0, vmCount): {
  name: '${vmName}-${i}-VMNic' 
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig${vmName}-${i}'
        type: 'Microsoft.Network/networkInterfaces/ipConfigurations'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          primary: true
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
  }
}]

resource disk 'Microsoft.Compute/disks@2022-07-02' = [for i in range(0, vmCount): if (vmType == 'newVersion') {
  name: '${vmName}-${i}-osDisk_1'
  location: location
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    hyperVGeneration: 'V2'
    creationData: {
      createOption: 'Copy'
      sourceResourceId: snapshotId
    }
  }
}]

output vmId string =  virtualMachine[0].id 
output osDiskId string = virtualMachine[0].properties.storageProfile.osDisk.managedDisk.id

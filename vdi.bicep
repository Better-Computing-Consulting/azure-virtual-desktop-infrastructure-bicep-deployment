
@description('Project ID for resource names.')
param projectId string = 'bccVDIDemo'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('The Azure Active Directory tenant ID that should be used for authenticating requests to the key vault.')
param tenantId string = ''

@description('The object ID of a user in the Azure Active Directory tenant for the vault.')
param keyVaultUser string = ''

@description('Set to false to only validate the VDI environment and no access is needed to KeyVault secrets or blob data.')
param updateAccess bool = true

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2022-11-01' = {
  name: 'VDIVNet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '172.23.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'VDIHostsSubnet'
        properties: {
          addressPrefix: '172.23.3.0/24'
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [
                'westus'
                'eastus'
              ]
            }
          ]
          delegations: []
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
        type: 'Microsoft.Network/virtualNetworks/subnets'
      }
    ]
    enableDdosProtection: false
  }
  resource defaultSubnet 'subnets' existing = {
    name: 'VDIHostsSubnet'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: take('${toLower(projectId)}sa${uniqueString(resourceGroup().id)}', 24) 
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: virtualNetwork::defaultSubnet.id
          action: 'Allow'
        }
      ]
      defaultAction: 'Deny'
    }
    accessTier: 'Hot'
  }
  resource blobService 'blobServices' = {
    name: 'default'
    resource container 'containers' = {
      name: 'scripts'
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2022-11-01' = {
  name: '${projectId}-private-endpoint'
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: '${projectId}-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
          privateLinkServiceConnectionState: {
            status: 'Approved'
            description: 'Auto-Approved'
            actionsRequired: 'None'
          }
        }
      }
    ]
    manualPrivateLinkServiceConnections: []
    subnet: {
      id: virtualNetwork::defaultSubnet.id
    }
  }
}

resource computeGallery 'Microsoft.Compute/galleries@2022-03-03' = {
  name: '${projectId}_Galery'
  location: location
  properties: {
    identifier: {}
  }
  resource computeImage 'images' = {
    name: 'win11-avd-vdi-apps'
    location: location
    properties: {
      hyperVGeneration: 'V2'
      architecture: 'x64'
      osType: 'Windows'
      osState: 'Generalized'
      identifier: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-avd'
      }
    }
  }
}

resource hostPool 'Microsoft.DesktopVirtualization/hostpools@2022-10-14-preview' = {
  name: '${projectId}-HP'
  location: location
  properties: {
    publicNetworkAccess: 'Enabled'
    friendlyName: 'VDI Demo'
    hostPoolType: 'Pooled'
    customRdpProperty: 'audiomode:i:0;videoplaybackmode:i:1;devicestoredirect:s:*;enablecredsspsupport:i:1;redirectwebauthn:i:1;targetisaadjoined:i:1;redirectclipboard:i:1;'
    maxSessionLimit: 10
    loadBalancerType: 'DepthFirst'
    validationEnvironment: false
    preferredAppGroupType: 'Desktop'
    startVMOnConnect: true
  }
}

resource applicationGroup 'Microsoft.DesktopVirtualization/applicationgroups@2022-10-14-preview' = {
  name: '${projectId}-AG'
  location: location
  kind: 'Desktop'
  properties: {
    hostPoolArmPath: hostPool.id
    applicationGroupType: 'Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2022-10-14-preview' = {
  name: '${projectId}-Workspace'
  location: location
  properties: {
    publicNetworkAccess: 'Enabled'
    applicationGroupReferences: [
      applicationGroup.id
    ]
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = if (updateAccess) {
  name: '${projectId}-KV'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    accessPolicies: [
      {
        tenantId: tenantId
        objectId: keyVaultUser
        permissions: {
          secrets: [
            'all'
          ]
        }
      }
    ]
  }
}

output keyVaultName string = keyVault.name
output galleryName string = computeGallery.name
output imageName string = computeGallery::computeImage.name
output subnetId string = virtualNetwork::defaultSubnet.id
output storageAccountName string = storageAccount.name
output hostPoolName string = hostPool.name
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob

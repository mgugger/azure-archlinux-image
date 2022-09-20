// parameters
param location string
param subnetId string
param name string
param principalId string

@allowed([
  'Storage'
  'StorageV2'
])
param kind string

@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Premium_LRS'
  'Premium_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
])
param storageSKU string = 'Standard_LRS'

// resource definition
resource stg 'Microsoft.Storage/storageAccounts@2021-02-01' = {
  name: name
  location: location
  kind: kind
  sku: {
    name: storageSKU
  }
  properties: {
    accessTier: 'Cool'    
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: subnetId
          action: 'Allow'
        }
      ]
    }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2019-06-01' = {
  name: '${stg.name}/default/archlinux'
  properties: {
    publicAccess: 'None'
    metadata: {}
  }
}

@description('This is the built-in Contributor role. See https://docs.microsoft.com/azure/role-based-access-control/built-in-roles#contributor')
resource contributorRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
}

@description('This is the built-in Contributor role. See https://docs.microsoft.com/azure/role-based-access-control/built-in-roles#contributor')
resource blobDataContributorRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

resource roleAssignment2 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  scope: stg
  name: guid(stg.id, principalId, blobDataContributorRoleDefinition.id)
  properties: {
    roleDefinitionId: blobDataContributorRoleDefinition.id
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  scope: stg
  name: guid(stg.id, principalId, contributorRoleDefinition.id)
  properties: {
    roleDefinitionId: contributorRoleDefinition.id
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output id string = stg.id
output name string = stg.name

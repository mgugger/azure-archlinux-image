targetScope = 'resourceGroup'
param location string = resourceGroup().location

// Parameters
param baseName string
param pubkeydata string
param vm_admin_name string
param local_public_ip string

module nsg 'modules/nsg/nsg.bicep' = {
  name: 'nsgdmz'
  params: {
    location: location
    local_public_ip: local_public_ip
  }
}

// VNET
module vnet 'modules/vnet/vnet.bicep' = {
  name: baseName
  params: {
    location: location
    vnetAddressSpace: {
      addressPrefixes: [
        '10.0.0.0/24'
      ]
    }
    vnetNamePrefix: baseName
    subnets: [
      {
        properties: {
          addressPrefix: '10.0.0.0/24'
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
          networkSecurityGroup: {
            id: nsg.outputs.nsgId
          }
        }
        name: 'nsg'
      }
    ]
  }
}

// VM for packer to build image
module publicip 'modules/vnet/publicip.bicep' = {
  name: 'publicip'
  params: {
    location: location
    publicipName: 'vm-imagebuilder-pip'
    publicipproperties: {
      publicIPAllocationMethod: 'Dynamic'
      dnsSettings: {
        domainNameLabel: baseName
      }
    }
    publicipsku: {
      name: 'Basic'
      tier: 'Regional'
    }
  }
}

output hostname string = publicip.outputs.fqdn

module vm 'modules/VM/virtualmachine.bicep' = {
  name: 'vm-imagebuilder'
  params: {
    location: location
    subnetId: vnet.outputs.vnetSubnets[0].id
    publicKey: pubkeydata
    publicIpId: publicip.outputs.publicipId
    vm_admin_name: vm_admin_name
  }
}

// Storage Account
module sta 'modules/storage/storage_account.bicep' = {
  name: format('{0}sta', baseName)
  params: {
    name: baseName
    kind: 'StorageV2'
    location: location
    subnetId: vnet.outputs.vnetSubnets[0].id
    principalId: vm.outputs.principalId
  }
}

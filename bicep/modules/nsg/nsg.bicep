param location string = resourceGroup().location
param local_public_ip string

resource nsg 'Microsoft.Network/networkSecurityGroups@2020-07-01' = {
  name: 'nsg'
  location: location
  tags: {}
  properties: {
    securityRules: [
      {
        name: 'ssh'
        properties: {
          description: 'Allow alternative ssh inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '22222'
          sourceAddressPrefix: local_public_ip
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1001
          direction: 'Inbound'
        }
      }
      {
        name: 'allow_intra_vnet'
        properties: {
          description: 'Allow alternative ssh inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 1201
          direction: 'Inbound'
        }
      }
      {
        name: 'deny_catchall'
        properties: {
          description: 'Deny all inbound traffic'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Deny'
          priority: 4000
          direction: 'Inbound'
        }
      }
    ]
  }
}

output nsgId string = nsg.id

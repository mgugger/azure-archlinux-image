param subnetId string
param publicKey string
param publicIpId string
param vm_admin_name string
param location string = resourceGroup().location

module nic '../vnet/nic.bicep' = {
  name: 'vm-wireguard-nic'
  params: {
    location: location
    subnetId: subnetId
    publicIpId: publicIpId
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2021-07-01' = {
  name: 'vm-imagebuilder'
  location: location
  properties: {
    osProfile: {
      customData: loadFileAsBase64('./cloud-init.sh')
      computerName: 'vm-imagebuilder'
      adminUsername: vm_admin_name
      linuxConfiguration: {
        ssh: {
          publicKeys: [
            {
              path: format('/home/{0}/.ssh/authorized_keys', vm_admin_name)
              keyData: publicKey
            }
          ]
        }
        disablePasswordAuthentication: true
      }
    }
    hardwareProfile: {
      vmSize: 'Standard_A4_v2'
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-focal'
        sku: '20_04-lts'
        version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.outputs.nicId
        }
      ]
    }
  }
}

resource autoShutdownScheduler 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vm.name}'
  location: location
  properties: {
    dailyRecurrence: {
      time: '0000'
    }
    notificationSettings: {
      status: 'Disabled'
    }
    status: 'Enabled'
    targetResourceId: vm.id
    taskType: 'ComputeVmShutdownTask'
    timeZoneId: 'W. Europe Standard Time'
  }
}

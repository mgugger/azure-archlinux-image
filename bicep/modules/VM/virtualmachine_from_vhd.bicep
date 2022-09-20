param subnetId string
param location string = resourceGroup().location
param staId string
param staName string

module nic '../vnet/nic.bicep' = {
  name: 'vm-from-vhd-nic'
  params: {
    name: 'vm-sample'
    location: location
    subnetId: subnetId
    publicIpId: 'None'
  }
}

resource vmDataDisk 'Microsoft.Compute/disks@2022-03-02' = {
  name: 'vm-sample-vhd'
  location: location
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    osType: 'Linux'
    diskSizeGB: 4
    creationData: {
      createOption: 'Import'
      sourceUri: 'https://${staName}.blob.core.windows.net/archlinux/archlinux.vhd'
      storageAccountId: staId
    }
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2021-07-01' = {
  name: 'vm-sample'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    storageProfile: {
      osDisk: {
        createOption: 'Attach'
        osType: 'Linux'
        managedDisk: {
          id: vmDataDisk.id
        }
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

output principalId string = vm.identity.principalId

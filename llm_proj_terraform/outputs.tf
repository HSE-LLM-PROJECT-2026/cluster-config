output "vm_summary" {
  description = "All VMs"
  value = {
    for name, vm in proxmox_virtual_environment_vm.vm : name => {
      vm_id  = vm.vm_id
      node   = vm.node_name
      cores  = vm.cpu[0].cores
      memory = "${vm.memory[0].dedicated} MB"
      disk   = "${vm.disk[0].size} GB"
      gpu    = length(vm.hostpci) > 0 ? "yes" : "no"
    }
  }
}

output "cluster_nodes" {
  description = "K8s cluster nodes"
  value = [
    for name, vm in proxmox_virtual_environment_vm.vm : {
      name  = name
      vm_id = vm.vm_id
      node  = vm.node_name
    }
  ]
}

output "host_resource_usage" {
  description = "Resource usage per Proxmox host"
  value = {
    for node in distinct([for vm in local.vms : vm.node]) : node => {
      total_cores   = sum([for vm in local.vms : vm.cores if vm.node == node])
      total_ram_gb  = sum([for vm in local.vms : vm.memory / 1024 if vm.node == node])
      total_disk_gb = sum([for vm in local.vms : vm.disk_size if vm.node == node])
      vms           = [for name, vm in local.vms : name if vm.node == node]
    }
  }
}

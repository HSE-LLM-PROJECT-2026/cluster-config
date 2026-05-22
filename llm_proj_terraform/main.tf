# ╔══════════════════════════════════════════════════════════════╗
# ║  Platform Flow — Single Cluster on 4 Proxmox hosts           ║
# ║                                                             ║
# ║  K8s Cluster: 5 Talos nodes (1 CP + 4 workers)             ║
# ╚══════════════════════════════════════════════════════════════╝

locals {
  vms = {

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # CONTROL PLANE — на Xeon (12C/24T, 128 GB disk)
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    cp = {
      description = "Control Plane — etcd, kube-apiserver"
      node        = var.node_xeon
      vm_id       = var.vm_id_base + 0
      cores       = 4
      memory      = 4096
      disk_size   = 30
      gpu         = null
      tags        = ["k8s", "controlplane", "llmops"]
    }

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # BACKEND WORKER — на Xeon (рядом с CP)
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    worker-1 = {
      description = "Backend Worker — FastAPI x6, React frontend"
      node        = var.node_xeon
      vm_id       = var.vm_id_base + 1
      cores       = 16
      memory      = 10240
      disk_size   = 80
      gpu         = null
      tags        = ["k8s", "worker", "backend", "llmops"]
    }

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # GPU WORKER V100 — на Ryzen (primary inference)
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    gpu-worker-v100 = {
      description = "GPU Worker — V100 passthrough, vLLM primary inference"
      node        = var.node_ryzen
      vm_id       = var.vm_id_base + 2
      cores       = 8
      memory      = 13300
      disk_size   = 200
      gpu = {
        pci_id = var.v100_pci_id
      }
      tags = ["k8s", "worker", "gpu", "v100", "llmops"]
    }

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # MONITORING WORKER — на Lenovo (500 GB disk)
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    worker-2 = {
      description = "Monitoring Worker — Prometheus, Loki, Grafana"
      node        = var.node_lenovo
      vm_id       = var.vm_id_base + 4
      cores       = 2
      memory      = 8192
      disk_size   = 400
      gpu         = null
      tags        = ["k8s", "worker", "monitoring", "llmops"]
    }

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # EXTRA CPU WORKER — дополнительная CPU-нода Kubernetes
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    worker-3 = {
      description = "CPU Worker — extra Kubernetes worker for platform workloads"
      node        = var.node_small_1
      vm_id       = var.vm_id_base + 10
      cores       = 2
      memory      = 4096
      disk_size   = 100
      gpu         = null
      tags        = ["k8s", "worker", "cpu", "llmops"]
    }

  }
}


# ══════════════════════════════════════════════════
# VM Resources
# ══════════════════════════════════════════════════

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = local.vms

  name        = each.key
  description = each.value.description
  tags        = each.value.tags
  node_name   = each.value.node
  vm_id       = each.value.vm_id
  on_boot     = true
  started     = true
  machine     = "q35"
  bios        = "ovmf"

  cpu {
    cores   = each.value.cores
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = each.value.memory
    floating  = 0
  }

  disk {
    interface    = "scsi0"
    datastore_id = var.disk_storage
    size         = each.value.disk_size
    file_format  = "raw"
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  cdrom {
    file_id   = var.talos_iso_file
    interface = "ide2"
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = var.vlan_tag
  }

  efi_disk {
    datastore_id = var.disk_storage
    type         = "4m"
  }

  serial_device {}

  vga {
    type = "std"
  }

  dynamic "hostpci" {
    for_each = each.value.gpu != null ? [each.value.gpu] : []
    content {
      device = "hostpci0"
      id     = hostpci.value.pci_id
      pcie   = true
      rombar = true
      xvga   = false
    }
  }

  boot_order = ["scsi0", "ide2"]

  lifecycle {
    ignore_changes = [
      cdrom,          # ISO ejected after install
      boot_order,     # may change after install
      disk,           # don't recreate on disk drift
      network_device, # don't recreate on MAC change
    ]
  }
}


# ══════════════════════════════════════════════════
# IOMMU setup (manual, on GPU hosts only)
# ══════════════════════════════════════════════════
#
# srv-heavy-4 (Ryzen + V100):
#   1. BIOS: AMD-Vi / SVM → Enabled
#   2. /etc/default/grub: GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"
#   3. update-grub && reboot
#
# GPU host:
#   4. /etc/modules: vfio, vfio_iommu_type1, vfio_pci, vfio_virqfd
#   5. /etc/modprobe.d/blacklist.conf: blacklist nouveau, blacklist nvidia*
#   6. update-initramfs -u && reboot
#   7. Verify: find /sys/kernel/iommu_groups/ -type l | sort -V

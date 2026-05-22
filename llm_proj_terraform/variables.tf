# ──────────────────────────────────────────────
# Proxmox connection
# ──────────────────────────────────────────────

variable "proxmox_endpoint" {
  description = "Proxmox API URL (e.g. https://10.19.87.4:8006)"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox API user"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Proxmox API password"
  type        = string
  sensitive   = true
}

# ──────────────────────────────────────────────
# Proxmox node names
# ──────────────────────────────────────────────

variable "node_xeon" {
  description = "Xeon E5-2650 v4 (10.19.87.4)"
  type        = string
  default     = "srv-heavy-3"
}

variable "node_ryzen" {
  description = "Ryzen 5 2600 + V100 (10.19.87.5)"
  type        = string
  default     = "srv-heavy-4"
}

variable "node_lenovo" {
  description = "Lenovo i3-2120 (10.19.87.6)"
  type        = string
  default     = "srv-small-2"
}

variable "node_small_1" {
  description = "Additional CPU-only Proxmox host for worker-3"
  type        = string
  default     = "srv-small-1"
}

# ──────────────────────────────────────────────
# Talos ISO
# ──────────────────────────────────────────────

variable "talos_iso_file" {
  description = "Path to Talos ISO on Proxmox storage"
  type        = string
  default     = "local:iso/talos-amd64.iso"
}

# ──────────────────────────────────────────────
# Storage & Network
# ──────────────────────────────────────────────

variable "disk_storage" {
  description = "Proxmox storage for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "vlan_tag" {
  description = "VLAN tag (null = no VLAN)"
  type        = number
  default     = null
}

# ──────────────────────────────────────────────
# GPU PCI passthrough
# lspci -nn | grep -i nvidia на каждом хосте
# ──────────────────────────────────────────────

variable "v100_pci_id" {
  description = "PCI address of V100 on srv-heavy-4"
  type        = string
  default     = "0000:01:00.0"
}

# ──────────────────────────────────────────────
# VM IDs
# ──────────────────────────────────────────────

variable "vm_id_base" {
  description = "Starting VM ID"
  type        = number
  default     = 200
}

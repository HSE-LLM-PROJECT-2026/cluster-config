#!/bin/bash
set -euo pipefail

# WireGuard/LAN gateway quick-fix for:
# VPN subnet: 10.19.87.0/24
# Cluster/LAN subnets: 10.42.0.0/24, 10.42.1.0/24
# VPN iface: wg-llm-project
# LAN iface: enp0s31f6

VPN_IFACE="${VPN_IFACE:-wg-llm-project}"
LAN_IFACE="${LAN_IFACE:-enp0s31f6}"
VPN_SUBNET="${VPN_SUBNET:-10.19.87.0/24}"
LAN_SUBNET="${LAN_SUBNET:-}"
if [[ -n "${LAN_SUBNET}" ]]; then
  LAN_SUBNETS="${LAN_SUBNETS:-${LAN_SUBNET}}"
else
  LAN_SUBNETS="${LAN_SUBNETS:-10.42.0.0/24 10.42.1.0/24}"
fi

echo "[wg-gateway-fix] Enabling IPv4 forwarding"
sudo sysctl -w net.ipv4.ip_forward=1

for subnet in ${LAN_SUBNETS}; do
  echo "[wg-gateway-fix] Allow FORWARD ${VPN_SUBNET} -> ${subnet}"
  if ! sudo iptables -C FORWARD -i "${VPN_IFACE}" -o "${LAN_IFACE}" -s "${VPN_SUBNET}" -d "${subnet}" -j ACCEPT 2>/dev/null; then
    sudo iptables -I FORWARD 1 -i "${VPN_IFACE}" -o "${LAN_IFACE}" -s "${VPN_SUBNET}" -d "${subnet}" -j ACCEPT
  fi

  echo "[wg-gateway-fix] Allow reverse FORWARD ${subnet} -> ${VPN_SUBNET} (ESTABLISHED,RELATED)"
  if ! sudo iptables -C FORWARD -i "${LAN_IFACE}" -o "${VPN_IFACE}" -s "${subnet}" -d "${VPN_SUBNET}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    sudo iptables -I FORWARD 1 -i "${LAN_IFACE}" -o "${VPN_IFACE}" -s "${subnet}" -d "${VPN_SUBNET}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  fi

  echo "[wg-gateway-fix] Enable NAT for VPN -> ${subnet} path (if needed)"
  if ! sudo iptables -t nat -C POSTROUTING -s "${VPN_SUBNET}" -d "${subnet}" -o "${LAN_IFACE}" -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}" -d "${subnet}" -o "${LAN_IFACE}" -j MASQUERADE
  fi
done

echo "[wg-gateway-fix] Done"
echo "[wg-gateway-fix] Check:"
echo "  ping 10.42.0.1"
echo "  ping 10.42.0.141"
echo "  ping 10.42.1.10"

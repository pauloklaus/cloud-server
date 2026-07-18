#!/usr/bin/env sh
set -eu

WG_VPN_IP="${WG_VPN_IP:-${VPN_GATEWAY:-172.18.0.1}}"
WG_SNAT_IP="${WG_SNAT_IP:-${WIREGUARD_IP:-172.19.0.3}}"
TRAEFIK_IP="${TRAEFIK_IP:-172.19.0.10}"
VPN_SUBNET="${VPN_SUBNET:-172.18.0.0/24}"
WG_IFACE="${WG_IFACE:-wg0}"
_auto_oif=$(ip route get "${TRAEFIK_IP}" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
OUT_IFACE="${OUT_IFACE:-${_auto_oif:-eth0}}"

iptables -t nat -D PREROUTING -i "${WG_IFACE}" -d "${WG_VPN_IP}" -p tcp --dport 80 -j DNAT --to-destination "${TRAEFIK_IP}:80" 2>/dev/null || true
iptables -t nat -D PREROUTING -i "${WG_IFACE}" -d "${WG_VPN_IP}" -p tcp --dport 443 -j DNAT --to-destination "${TRAEFIK_IP}:443" 2>/dev/null || true
iptables -t nat -D POSTROUTING -s "${VPN_SUBNET}" -d "${TRAEFIK_IP}" -p tcp -m multiport --dports 80,443 -o "${OUT_IFACE}" -j SNAT --to-source "${WG_SNAT_IP}" 2>/dev/null || true
iptables -t nat -D POSTROUTING -s "${VPN_SUBNET}" -d "${TRAEFIK_IP}" -p tcp -m multiport --dports 80,443 -o eth0 -j SNAT --to-source "${WG_SNAT_IP}" 2>/dev/null || true
# Migração: versões antigas do script usavam MASQUERADE em vez de SNAT explícito
iptables -t nat -D POSTROUTING -o "${OUT_IFACE}" -p tcp -d "${TRAEFIK_IP}" --dport 80 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -o "${OUT_IFACE}" -p tcp -d "${TRAEFIK_IP}" --dport 443 -j MASQUERADE 2>/dev/null || true

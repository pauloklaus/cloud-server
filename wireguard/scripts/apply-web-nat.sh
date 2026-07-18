#!/usr/bin/env sh
set -eu

# DNAT: tráfego para VPN_GATEWAY:80/443 (wg0) -> Traefik na rede Docker.
# SNAT explícito para o IP do *container* wireguard em SVC_SUBNET:
# sem isso, o Traefik responde para peers da VPN sem rota válida no namespace do Traefik -> timeout no cliente.
WG_VPN_IP="${WG_VPN_IP:-${VPN_GATEWAY:-172.18.0.1}}"
WG_SNAT_IP="${WG_SNAT_IP:-${WIREGUARD_IP:-172.19.0.3}}"
TRAEFIK_IP="${TRAEFIK_IP:-172.19.0.10}"
VPN_SUBNET="${VPN_SUBNET:-172.18.0.0/24}"
WG_IFACE="${WG_IFACE:-wg0}"
# Interface até o Traefik: em compose costuma ser eth1 (rede internal_services_net), não eth0 (bridge Docker).
_auto_oif=$(ip route get "${TRAEFIK_IP}" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
OUT_IFACE="${OUT_IFACE:-${_auto_oif:-eth0}}"

iptables -t nat -C PREROUTING -i "${WG_IFACE}" -d "${WG_VPN_IP}" -p tcp --dport 80 -j DNAT --to-destination "${TRAEFIK_IP}:80" 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "${WG_IFACE}" -d "${WG_VPN_IP}" -p tcp --dport 80 -j DNAT --to-destination "${TRAEFIK_IP}:80"
iptables -t nat -C PREROUTING -i "${WG_IFACE}" -d "${WG_VPN_IP}" -p tcp --dport 443 -j DNAT --to-destination "${TRAEFIK_IP}:443" 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "${WG_IFACE}" -d "${WG_VPN_IP}" -p tcp --dport 443 -j DNAT --to-destination "${TRAEFIK_IP}:443"

# Migração: SNAT criado com OUT_IFACE=eth0 quando o caminho até o Traefik é outra NIC (ex.: eth1 na rede internal_services_net).
iptables -t nat -D POSTROUTING -s "${VPN_SUBNET}" -d "${TRAEFIK_IP}" -p tcp -m multiport --dports 80,443 -o eth0 -j SNAT --to-source "${WG_SNAT_IP}" 2>/dev/null || true

# Origem VPN -> Traefik vira WIREGUARD_IP (reply volta para este container e desNAT pelo conntrack)
iptables -t nat -C POSTROUTING -s "${VPN_SUBNET}" -d "${TRAEFIK_IP}" -p tcp -m multiport --dports 80,443 -o "${OUT_IFACE}" -j SNAT --to-source "${WG_SNAT_IP}" 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}" -d "${TRAEFIK_IP}" -p tcp -m multiport --dports 80,443 -o "${OUT_IFACE}" -j SNAT --to-source "${WG_SNAT_IP}"

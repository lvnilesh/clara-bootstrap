#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root or via sudo." >&2
  exit 1
fi

desired_state=${1:-/etc/clara-bootstrap/desired-state.json}
for command in jq ufw iptables ip6tables ip; do
  command -v "$command" >/dev/null
done

jq -e '
  .host.firewall as $fw |
  ($fw.publicInterface | test("^[A-Za-z0-9_.:-]+$")) and
  ($fw.tailscaleInterface | test("^[A-Za-z0-9_.:-]+$")) and
  ($fw.tailscaleTcpPorts | type == "array" and length > 0 and all(.[]; type == "number" and . >= 1 and . <= 65535)) and
  ($fw.publicUdpPorts | type == "array" and length > 0 and all(.[]; type == "number" and . >= 1 and . <= 65535)) and
  ($fw.sourceTcpRules | type == "array" and all(.[];
    (.source | test("^[0-9.]+/[0-9]+$")) and
    (.port | type == "number" and . >= 1 and . <= 65535)
  ))
' "$desired_state" >/dev/null

public_interface=$(jq -r '.host.firewall.publicInterface' "$desired_state")
tailscale_interface=$(jq -r '.host.firewall.tailscaleInterface' "$desired_state")
mapfile -t tailscale_tcp_ports < <(jq -r '.host.firewall.tailscaleTcpPorts[]' "$desired_state")
mapfile -t public_udp_ports < <(jq -r '.host.firewall.publicUdpPorts[]' "$desired_state")
mapfile -t source_tcp_rules < <(jq -c '.host.firewall.sourceTcpRules[]' "$desired_state")

ip link show "$public_interface" >/dev/null
ip link show "$tailscale_interface" >/dev/null

ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw default deny routed >/dev/null

for port in "${tailscale_tcp_ports[@]}"; do
  ufw allow in on "$tailscale_interface" proto tcp to any port "$port" >/dev/null
done

for port in "${public_udp_ports[@]}"; do
  ufw allow in on "$public_interface" proto udp to any port "$port" >/dev/null
  ufw route allow in on "$public_interface" proto udp to any port "$port" >/dev/null
done
for rule in "${source_tcp_rules[@]}"; do
  source=$(jq -r '.source' <<<"$rule")
  port=$(jq -r '.port' <<<"$rule")
  ufw allow in on "$public_interface" proto tcp from "$source" to any port "$port" >/dev/null
  ufw route allow in on "$public_interface" proto tcp from "$source" to any port "$port" >/dev/null
done
ufw --force enable >/dev/null

# Docker publishes before UFW's forwarding chains. Enforce the same policy at
# DOCKER-USER, which Docker guarantees runs before its own accept rules.
docker_chain=CLARA-DOCKER-IN
iptables -N "$docker_chain" 2>/dev/null || true
iptables -F "$docker_chain"
iptables -A "$docker_chain" -i "$public_interface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for port in "${public_udp_ports[@]}"; do
  iptables -A "$docker_chain" -i "$public_interface" -p udp \
    -m conntrack --ctorigdstport "$port" -j ACCEPT
done
for rule in "${source_tcp_rules[@]}"; do
  source=$(jq -r '.source' <<<"$rule")
  port=$(jq -r '.port' <<<"$rule")
  iptables -A "$docker_chain" -i "$public_interface" -s "$source" -p tcp \
    -m conntrack --ctorigdstport "$port" -j ACCEPT
done
iptables -A "$docker_chain" -i "$public_interface" -j DROP
iptables -A "$docker_chain" -j RETURN
while iptables -C DOCKER-USER -j "$docker_chain" 2>/dev/null; do
  iptables -D DOCKER-USER -j "$docker_chain"
done
iptables -I DOCKER-USER 1 -j "$docker_chain"

# Clara has no public IPv6 allocation. Permit Gerbil if one is added later,
# while keeping every other Docker-published IPv6 port closed by default.
ip6tables -N "$docker_chain" 2>/dev/null || true
ip6tables -F "$docker_chain"
ip6tables -A "$docker_chain" -i "$public_interface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for port in "${public_udp_ports[@]}"; do
  ip6tables -A "$docker_chain" -i "$public_interface" -p udp \
    -m conntrack --ctorigdstport "$port" -j ACCEPT
done
ip6tables -A "$docker_chain" -i "$public_interface" -j DROP
ip6tables -A "$docker_chain" -j RETURN
while ip6tables -C DOCKER-USER -j "$docker_chain" 2>/dev/null; do
  ip6tables -D DOCKER-USER -j "$docker_chain"
done
ip6tables -I DOCKER-USER 1 -j "$docker_chain"

ufw status | grep -Fxq 'Status: active'
iptables -C DOCKER-USER -j "$docker_chain"
ip6tables -C DOCKER-USER -j "$docker_chain"
printf 'Host firewall reconciled: public=%s tailscale=%s udp=%s\n' \
  "$public_interface" "$tailscale_interface" "${public_udp_ports[*]}"

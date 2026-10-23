#!/usr/bin/env bash
set -euo pipefail

desired_state=${1:-infrastructure/desired-state.json}
output_state=${2:-$desired_state}

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"

api=https://api.cloudflare.com/client/v4
auth_header="Authorization: Bearer $CLOUDFLARE_API_TOKEN"

jq -e '
  .cloudflare.zone == "cloudgeni.us" and
  .cloudflare.homeHostname == "home.cloudgeni.us"
' "$desired_state" >/dev/null

zone_name=$(jq -r '.cloudflare.zone' "$desired_state")
home_hostname=$(jq -r '.cloudflare.homeHostname' "$desired_state")

zone_id=$(
  curl -fsS \
    -H "$auth_header" \
    -H 'Content-Type: application/json' \
    "$api/zones?name=$zone_name" \
    | jq -er --arg zone "$zone_name" '
      .result
      | map(select(.name == $zone))
      | if length == 1 then .[0].id else error("expected exactly one zone") end
    '
)

home_ip=$(
  curl -fsS \
    -H "$auth_header" \
    -H 'Content-Type: application/json' \
    "$api/zones/$zone_id/dns_records?type=A&name=$home_hostname" \
    | jq -er --arg name "$home_hostname" '
      .result
      | map(select(.name == $name and .type == "A" and .proxied == false))
      | if length == 1 then .[0].content else error("expected exactly one unproxied A record for " + $name) end
    '
)

if ! [[ $home_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  printf 'Invalid IPv4 address resolved for %s: %s\n' "$home_hostname" "$home_ip" >&2
  exit 1
fi

home_cidr="${home_ip}/32"
tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT

jq \
  --arg host "$home_hostname" \
  --arg cidr "$home_cidr" \
  '
  .azure.inboundRules |= map(if .source == $host then .source = $cidr else . end) |
  .host.firewall.sourceTcpRules |= map(if .source == $host then .source = $cidr else . end)
  ' "$desired_state" > "$tmp_file"

mv "$tmp_file" "$output_state"
printf 'Resolved %s via Cloudflare API -> %s\n' "$home_hostname" "$home_cidr"

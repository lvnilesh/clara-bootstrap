#!/usr/bin/env bash
set -euo pipefail

desired_state=${1:-infrastructure/desired-state.json}
resource_group=$(jq -r '.azure.resourceGroup' "$desired_state")
nsg_name=$(jq -r '.azure.networkSecurityGroup' "$desired_state")
principal_object_id=$(jq -r '.azure.networkReconciler.principalObjectId' "$desired_state")
network_role=$(jq -r '.azure.networkReconciler.role' "$desired_state")
nsg_scope=$(
  az network nsg show \
    --resource-group "$resource_group" \
    --name "$nsg_name" \
    --query id \
    --output tsv
)

assignment_count=$(
  az role assignment list \
    --assignee-object-id "$principal_object_id" \
    --scope "$nsg_scope" \
    --query "[?roleDefinitionName=='$network_role'] | length(@)" \
    --output tsv
)
if [[ $assignment_count != 1 ]]; then
  printf 'Missing Azure role assignment: principal=%s role=%s scope=%s\n' \
    "$principal_object_id" "$network_role" "$nsg_scope" >&2
  exit 1
fi

mapfile -t desired_names < <(jq -r '.azure.inboundRules[].name' "$desired_state")
mapfile -t current_names < <(
  az network nsg rule list \
    --resource-group "$resource_group" \
    --nsg-name "$nsg_name" \
    --query '[?direction==`Inbound` && priority < `65000`].name' \
    --output tsv
)

for current_name in "${current_names[@]}"; do
  if ! printf '%s\n' "${desired_names[@]}" | grep -Fxq "$current_name"; then
    az network nsg rule delete \
      --resource-group "$resource_group" \
      --nsg-name "$nsg_name" \
      --name "$current_name"
  fi
done

while IFS= read -r rule; do
  name=$(jq -r '.name' <<<"$rule")
  priority=$(jq -r '.priority' <<<"$rule")
  protocol=$(jq -r '.protocol' <<<"$rule")
  source=$(jq -r '.source' <<<"$rule")
  mapfile -t ports < <(jq -r '.destinationPorts[]' <<<"$rule")

  az network nsg rule create \
    --resource-group "$resource_group" \
    --nsg-name "$nsg_name" \
    --name "$name" \
    --priority "$priority" \
    --direction Inbound \
    --access Allow \
    --protocol "$protocol" \
    --source-address-prefixes "$source" \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges "${ports[@]}" \
    --output none
done < <(jq -c '.azure.inboundRules[]' "$desired_state")

actual=$(
  az network nsg rule list \
    --resource-group "$resource_group" \
    --nsg-name "$nsg_name" \
    --query '[?direction==`Inbound` && priority < `65000`].{name:name,priority:priority,protocol:protocol,source:sourceAddressPrefix,destinationPort:destinationPortRange,destinationPorts:destinationPortRanges}' \
    --output json | jq -S '
      map({
        name,
        priority,
        protocol,
        source,
        destinationPorts: (
          (if (.destinationPorts | length) > 0 then .destinationPorts else [.destinationPort] end) | sort
        )
      }) | sort_by(.priority)
    '
)
expected=$(
  jq -S '[.azure.inboundRules[] | {name,priority,protocol,source,destinationPorts: (.destinationPorts | sort)}] | sort_by(.priority)' \
    "$desired_state"
)

if [[ $actual != "$expected" ]]; then
  echo "Azure NSG reconciliation failed" >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  exit 1
fi

printf 'Azure NSG reconciled: %s\n' "${desired_names[*]}"
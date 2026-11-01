#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root or via sudo." >&2
  exit 1
fi

source_dir=${1:?Pass the Docker policy source directory}
install -d -m 0755 /etc/docker
config_file=$(mktemp /etc/docker/daemon.json.XXXXXX)
trap 'rm -f "$config_file"' EXIT

if [[ -f /etc/docker/daemon.json ]]; then
  jq -S -s '.[0] * .[1]' /etc/docker/daemon.json "$source_dir/etc/docker/daemon.json" > "$config_file"
else
  jq -S . "$source_dir/etc/docker/daemon.json" > "$config_file"
fi
dockerd --validate --config-file="$config_file"
if [[ ! -f /etc/docker/daemon.json ]] ||
    ! cmp -s <(jq -S . /etc/docker/daemon.json) "$config_file"; then
  install -m 0644 "$config_file" /etc/docker/daemon.json
  systemctl restart docker
fi

cleanup_changed=false
for unit in clara-docker-cleanup.service clara-docker-cleanup.timer; do
  if ! cmp -s "$source_dir/etc/systemd/system/$unit" "/etc/systemd/system/$unit"; then
    cleanup_changed=true
  fi
  install -m 0644 "$source_dir/etc/systemd/system/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now clara-docker-cleanup.timer
if [[ $cleanup_changed == true ]]; then
  systemctl start clara-docker-cleanup.service
fi
systemctl is-active --quiet docker
systemctl is-active --quiet clara-docker-cleanup.timer
jq -e '.["log-driver"] == "json-file" and .["log-opts"]["max-size"] == "10m" and .["log-opts"]["max-file"] == "3"' \
  /etc/docker/daemon.json >/dev/null

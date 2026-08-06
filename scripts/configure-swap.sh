#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root or via sudo." >&2
  exit 1
fi

swap_file="${CLARA_SWAP_FILE:-/swapfile}"
swap_size_gib="${CLARA_SWAP_SIZE_GIB:-2}"
swappiness="${CLARA_SWAPPINESS:-10}"

if [[ $swap_file != /* ]]; then
  echo "CLARA_SWAP_FILE must be an absolute path." >&2
  exit 1
fi
if [[ ! $swap_size_gib =~ ^[1-9][0-9]*$ ]]; then
  echo "CLARA_SWAP_SIZE_GIB must be a positive integer." >&2
  exit 1
fi
if [[ ! $swappiness =~ ^[0-9]+$ ]] || ((swappiness > 100)); then
  echo "CLARA_SWAPPINESS must be an integer from 0 through 100." >&2
  exit 1
fi

desired_bytes=$((swap_size_gib * 1024 * 1024 * 1024))
active=false
if swapon --noheadings --raw --show=NAME | grep -Fxq "$swap_file"; then
  active=true
fi

if [[ -e $swap_file ]] && [[ $(stat -c %s "$swap_file") -ne $desired_bytes ]]; then
  if [[ $active == true ]]; then
    swapoff "$swap_file"
    active=false
  fi
  rm -f "$swap_file"
fi

if [[ ! -e $swap_file ]]; then
  if ! fallocate -l "${swap_size_gib}G" "$swap_file"; then
    dd if=/dev/zero of="$swap_file" bs=1M count="$((swap_size_gib * 1024))" status=none
  fi
  chmod 0600 "$swap_file"
  mkswap "$swap_file" >/dev/null
elif [[ $active == false ]] && [[ $(blkid -p -s TYPE -o value "$swap_file" || true) != swap ]]; then
  chmod 0600 "$swap_file"
  mkswap "$swap_file" >/dev/null
else
  chmod 0600 "$swap_file"
fi

fstab_tmp=$(mktemp)
trap 'rm -f "$fstab_tmp"' EXIT
awk -v swap_file="$swap_file" '$1 != swap_file { print }' /etc/fstab > "$fstab_tmp"
printf '%s none swap sw 0 0\n' "$swap_file" >> "$fstab_tmp"
install -o root -g root -m 0644 "$fstab_tmp" /etc/fstab

if [[ $active == false ]]; then
  swapon "$swap_file"
fi

printf 'vm.swappiness=%s\n' "$swappiness" > /etc/sysctl.d/60-clara-swap.conf
sysctl -q -w "vm.swappiness=$swappiness"

actual_file_bytes=$(stat -c %s "$swap_file")
active_swap_bytes=$(swapon --bytes --noheadings --raw --show=NAME,SIZE \
  | awk -v swap_file="$swap_file" '$1 == swap_file { print $2 }')
if [[ $actual_file_bytes != "$desired_bytes" || -z $active_swap_bytes ]]; then
  printf 'Swap reconciliation failed: expected_file=%s actual_file=%s active_swap=%s\n' \
    "$desired_bytes" "$actual_file_bytes" "${active_swap_bytes:-absent}" >&2
  exit 1
fi

printf 'Swap reconciled: file=%s size_gib=%s active_bytes=%s swappiness=%s\n' \
  "$swap_file" "$swap_size_gib" "$active_swap_bytes" "$swappiness"

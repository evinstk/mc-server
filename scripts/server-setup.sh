#!/usr/bin/env bash
# Run ON the Oracle instance (Ubuntu ARM) as the default `ubuntu` user:
#   bash scripts/server-setup.sh
# Installs Docker and opens 25565, 80 and 443 in the instance's iptables. Idempotent.
set -euo pipefail

echo "==> Updating packages"
sudo apt-get update -y
sudo apt-get upgrade -y

if ! command -v docker >/dev/null; then
  echo "==> Installing Docker"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  echo "    (log out and back in for the docker group to apply)"
fi

echo "==> Opening 25565 (Minecraft), 80/443 (Caddy) in iptables"
# Oracle's Ubuntu images ship an INPUT chain that ends in a REJECT rule, so the
# ACCEPT must be inserted ahead of it (not appended).
for port in 25565 80 443; do
  if ! sudo iptables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
  fi
done

echo "==> Persisting iptables rules"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent
sudo netfilter-persistent save

echo "==> Done. Verify with: sudo iptables -L INPUT -n --line-numbers"

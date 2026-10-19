#!/usr/bin/env bash
# instalar_ns2.sh — Configura ns2 como SECUNDARIO. Se ejecuta DENTRO de ns2 como root, DESPUÉS de ns1.
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"; cd "$RAIZ"
[[ $EUID -eq 0 ]] || { echo "Ejecuta como root"; exit 1; }
[[ -s compartido/transferencia.key ]] || { echo "Falta compartido/transferencia.key: ejecuta primero instalar_ns1.sh en ns1"; exit 1; }

install -o root -g bind -m 640 compartido/transferencia.key /etc/bind/transferencia.key
install -d -o bind -g bind -m 755 /var/log/named
install -o root -g bind -m 644 ns2/named.conf.options ns2/named.conf.local /etc/bind/
named-checkconf

systemctl enable named >/dev/null 2>&1
if systemctl is-active -q named; then rndc reload; else systemctl start named; fi
sleep 2
rndc zonestatus horizonte.internal | grep -E 'serial|type' || true
echo "ns2 listo: dig @10.10.10.3 www.horizonte.internal"

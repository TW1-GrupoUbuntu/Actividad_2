#!/usr/bin/env bash
# instalar_ns1.sh — Configura ns1 como PRIMARIO de horizonte.internal. Se ejecuta DENTRO de ns1 como root.
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"; cd "$RAIZ"
[[ $EUID -eq 0 ]] || { echo "Ejecuta como root"; exit 1; }

# 1. Clave TSIG compartida (se crea una sola vez; ns2 la lee de compartido/). Nunca se muestra ni se sube al repo.
install -d -m 755 compartido
if [[ ! -s compartido/transferencia.key ]]; then
  tsig-keygen -a hmac-sha256 transferencia-horizonte > compartido/transferencia.key
fi
install -o root -g bind -m 640 compartido/transferencia.key /etc/bind/transferencia.key

# 2. Configuración, zonas y carpeta de registros (las zonas van en /var/lib/bind: BIND puede escribir ahí)
install -d -o bind -g bind -m 755 /var/log/named
install -o root -g bind -m 644 ns1/named.conf.options ns1/named.conf.local /etc/bind/
install -o bind -g bind -m 644 ns1/db.horizonte.internal ns1/db.10.10.10 ns1/db.2001.db8.10 /var/lib/bind/

# 3. Validar ANTES de aplicar
named-checkconf
named-checkzone horizonte.internal /var/lib/bind/db.horizonte.internal
named-checkzone 10.10.10.in-addr.arpa /var/lib/bind/db.10.10.10
named-checkzone 0.1.0.0.8.b.d.0.1.0.0.2.ip6.arpa /var/lib/bind/db.2001.db8.10

# 4. Aplicar
systemctl enable named >/dev/null 2>&1
if systemctl is-active -q named; then rndc reload; else systemctl start named; fi
sleep 1
echo "ns1 listo: dig @10.10.10.2 www.horizonte.internal"

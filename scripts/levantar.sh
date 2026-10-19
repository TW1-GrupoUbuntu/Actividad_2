#!/usr/bin/env bash
# levantar.sh — Construye la imagen, enciende ns1, ns2 y cliente, e instala BIND en los dos servidores.
# Se ejecuta en el equipo anfitrión (donde está Docker), desde la raíz del repositorio. Es repetible.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose up -d --build
for n in ns1 ns2; do                       # esperar a que systemd arranque dentro de cada contenedor
  for _ in $(seq 1 30); do
    docker exec "$n" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
    sleep 1
  done
done
docker exec ns1 bash /lab/scripts/instalar_ns1.sh
docker exec ns2 bash /lab/scripts/instalar_ns2.sh
sleep 3
echo "Listo. Ahora: bash scripts/verificar_zonas.sh"

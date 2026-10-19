#!/usr/bin/env bash
# subir_serial.sh — Reto 3: sube el serial (AAAAMMDDnn), valida con named-checkzone y recarga la zona.
# Uso (en ns1, como root):  bash /lab/scripts/subir_serial.sh <zona> <archivo-de-zona>
#   ej.: bash /lab/scripts/subir_serial.sh horizonte.internal /lab/ns1/db.horizonte.internal
# Si la zona nueva no valida, el archivo original queda intacto y no se recarga nada.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "Uso: $0 <zona> <archivo-de-zona>"; exit 2; }
ZONA=$1; ARCH=$2
[[ -f $ARCH ]] || { echo "No existe $ARCH"; exit 2; }

VIEJO=$(grep -oE -m1 '\b[0-9]{10}\b' "$ARCH") || { echo "No encuentro un serial de 10 dígitos en $ARCH"; exit 2; }
HOY=$(date +%Y%m%d)
if [[ ${VIEJO:0:8} == "$HOY" ]]; then NUEVO=$((VIEJO + 1)); else NUEVO=${HOY}01; fi
(( NUEVO > VIEJO )) || NUEVO=$((VIEJO + 1))      # el serial nunca puede bajar ni repetirse

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
sed "0,/$VIEJO/s//$NUEVO/" "$ARCH" > "$TMP"
if ! named-checkzone "$ZONA" "$TMP" > /tmp/subir_serial.log 2>&1; then
  cat /tmp/subir_serial.log
  echo "ERROR: la zona no valida; no se cambió nada (serial sigue en $VIEJO)"; exit 1
fi
cat "$TMP" > "$ARCH"                              # conserva permisos del original
install -o bind -g bind -m 644 "$ARCH" "/var/lib/bind/$(basename "$ARCH")"
rndc reload "$ZONA" >/dev/null
echo "OK: $ZONA serial $VIEJO -> $NUEVO (validada y recargada)"

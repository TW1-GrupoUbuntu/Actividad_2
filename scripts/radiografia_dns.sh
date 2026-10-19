#!/usr/bin/env bash
# radiografia_dns.sh — Diagnóstico de la salud DNS de un dominio (Tecnología Web I, Laboratorio 6).
# Uso:  bash radiografia_dns.sh <dominio>            ej.: bash radiografia_dns.sh upds.edu.bo
# Variable opcional RESOLUTOR (por defecto 1.1.1.1). En Docker no uses 127.0.0.11: no responde bien a la raíz.
set -uo pipefail

DOMINIO="${1:?Uso: bash radiografia_dns.sh <dominio>}"
DOMINIO="${DOMINIO%.}"
RES="${RESOLUTOR:-1.1.1.1}"
bien=0; total=0

# Reto 3: con INFORME_MD=archivo.md el script genera ademas su informe en Markdown
if [[ -n "${INFORME_MD:-}" && -z "${_INFORME_HIJO:-}" ]]; then
  SALIDA=$(_INFORME_HIJO=1 bash "$0" "$DOMINIO")
  echo "$SALIDA"
  {
    echo "# Informe DNS de $DOMINIO"; echo
    echo "Generado el $(date '+%Y-%m-%d %H:%M') con resolutor $RES."; echo
    echo "| Estado | Hallazgo |"; echo "|---|---|"
    grep -E '^(✅|⚠️|❌|ℹ️)' <<<"$SALIDA" | awk '{e=$1; $1=""; sub(/^ +/,""); print "| " e " | " $0 " |"}'
    echo; echo "**$(grep '^Puntaje' <<<"$SALIDA")**"
  } > "$INFORME_MD"
  exit 0
fi

ok()    { echo "✅ $*"; bien=$((bien + 1)); total=$((total + 1)); }
aviso() { echo "⚠️  $*"; total=$((total + 1)); }
mal()   { echo "❌ $*"; total=$((total + 1)); }
q()     { dig +short +time=3 +tries=1 @"$RES" "$@"; }

echo "Radiografía DNS de $DOMINIO (resolutor $RES) — $(date '+%Y-%m-%d %H:%M')"
echo "────────────────────────────────────────────────────────────"

# 1. Servidores de nombres: lo que dice la ZONA vs lo que dice el PADRE (la delegación)
NS_ZONA=$(q "$DOMINIO" NS | tr 'A-Z' 'a-z' | sort)
# El padre es la zona de arriba que tiene sus propios NS (edu.bo no los tiene: lo administra .bo)
PADRE="${DOMINIO#*.}"
while [[ "$PADRE" == *.* && -z $(q "$PADRE" NS) ]]; do PADRE="${PADRE#*.}"; done
NS_PADRE_SRV=$(q "$PADRE" NS | head -1)
NS_PADRE=$(dig +norec +time=3 +tries=1 @"$NS_PADRE_SRV" "$DOMINIO" NS | awk '$4=="NS"{print tolower($5)}' | sort -u)
[[ -z $NS_PADRE ]] && NS_PADRE="$NS_ZONA"     # si el padre es también autoritativo del hijo
if [[ -z $NS_ZONA ]]; then
  mal "NS: el dominio no tiene servidores de nombres (¿existe?)"; echo "Puntaje: 0"; exit 1
elif [[ "$NS_ZONA" == "$NS_PADRE" ]]; then
  ok "NS: $(echo $NS_ZONA | wc -w) servidores; la delegación del padre ($PADRE) coincide con la zona"
else
  aviso "NS: el padre ($PADRE) delega en [$(echo $NS_PADRE)] pero la zona declara [$(echo $NS_ZONA)]"
fi
if (( $(echo "$NS_ZONA" | wc -w) < 2 )); then mal "NS: menos de 2 servidores (sin redundancia)"; fi

# 2. ¿Responden todos los NS con autoridad y el mismo número de serie?
SERIALES=""; COJOS=""
for ns in $(echo "$NS_ZONA $NS_PADRE" | tr ' ' '
' | sort -u); do
  r=$(dig +norec +time=3 +tries=1 @"$ns" "$DOMINIO" SOA 2>/dev/null)
  if grep -q 'flags:.* aa' <<<"$r"; then
    SERIALES+="$(awk '$4=="SOA"{print $7}' <<<"$r") "
  else
    COJOS+="$ns "
  fi
done
if [[ -z $COJOS ]]; then ok "Todos los NS responden con autoridad"; else mal "Delegación coja (lame): $COJOS no responde con autoridad"; fi
if [[ -z ${SERIALES// /} ]]; then
  mal "SOA: ningún NS respondió con autoridad"
elif [[ $(echo $SERIALES | tr ' ' '\n' | sort -u | wc -l) -eq 1 ]]; then
  ok "SOA: mismo número de serie en todos los NS ($(echo $SERIALES | cut -d' ' -f1))"
else
  mal "SOA: números de serie distintos entre NS ($SERIALES) — secundarios desactualizados"
fi

# 3. SOA: el correo del responsable (RNAME) — error clásico: olvidar el punto final
RNAME=$(q "$DOMINIO" SOA | awk '{print $2}')
RESTO="${RNAME%.$DOMINIO.}"
if [[ "$RESTO" != "$RNAME" && "$RESTO" =~ \.(com|net|org|bo|edu|gob|gov|io)$ ]]; then
  aviso "SOA: el RNAME termina en '...$(sed 's/^[^.]*//' <<<"$RNAME")' — ¿faltó el punto final en el archivo de zona?"
else
  ok "SOA: RNAME coherente ($RNAME)"
fi

# 4. Direcciones del sitio
A=$(q "$DOMINIO" A | tr '\n' ' '); AAAA=$(q "$DOMINIO" AAAA | tr '\n' ' ')
[[ -n $A ]]    && ok "A (IPv4): $A"       || aviso "A: el dominio raíz no tiene IPv4"
[[ -n $AAAA ]] && ok "AAAA (IPv6): $AAAA" || aviso "AAAA: sin IPv6"
W=$(q "www.$DOMINIO" A | tail -1)
[[ -n $W ]] && ok "www.$DOMINIO → $W" || aviso "www.$DOMINIO no resuelve"

# 5. Correo: MX, SPF y DMARC
MX=$(q "$DOMINIO" MX | sort -n | tr '\n' ';')
[[ -n $MX ]] && ok "MX: $MX" || aviso "MX: el dominio no recibe correo"
SPF=$(q "$DOMINIO" TXT | tr -d '"' | grep -i '^v=spf1' | head -1)
if [[ -z $SPF ]];              then mal "SPF: no existe (cualquiera puede enviar correo con este dominio)"
elif [[ $SPF == *"-all"* ]];   then ok "SPF estricto: $SPF"
else                                aviso "SPF sin '-all': $SPF"; fi

# Consulta y evaluación de DMARC
DMARC=$(q "_dmarc.$DOMINIO" TXT | tr -d '"' | grep -i '^v=DMARC1' | head -1)
POL=$(grep -oE '(^|[;[:space:]])p=(none|quarantine|reject)' <<<"$DMARC" | grep -oE 'p=(none|quarantine|reject)' | head -1)
if [[ -z $DMARC ]]; then
  mal "DMARC: no existe"
elif [[ $POL == p=none ]]; then
  aviso "DMARC solo observa ($POL)"
elif [[ $POL == p=quarantine || $POL == p=reject ]]; then
  ok "DMARC con política $POL"
else
  mal "DMARC: política ausente o no reconocida"
fi

# 6. CAA: qué autoridades pueden emitir certificados

# Consulta y evaluación de CAA
CAA=$(q "$DOMINIO" CAA | tr '\n' ';')
if [[ -n $CAA ]]; then
  ok "CAA: $CAA"
else
  mal "CAA: sin registros en el nombre consultado; revisar herencia"
fi

# 7. DNSSEC: ¿hay DS en el padre y la respuesta viene validada (flag ad)?

# Retos 1 y 2 (informativos: no cuentan en el puntaje)
REDES=""
for ns in $NS_ZONA; do for ip in $(q "$ns" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'); do REDES+="${ip%.*}.0/24 "; done; done
NREDES=$(echo $REDES | tr ' ' '\n' | sort -u | grep -c .)
if (( NREDES >= 2 )); then echo "ℹ️  Reto 1: los NS están en $NREDES redes /24 distintas"; else echo "ℹ️  Reto 1: los NS están en $NREDES red /24 (poca independencia de red)"; fi
HTTPSREC=$(q "$DOMINIO" HTTPS | head -1)
[[ -n $HTTPSREC ]] && echo "ℹ️  Reto 2: registro HTTPS (tipo 65): ${HTTPSREC:0:60}" || echo "ℹ️  Reto 2: sin registro HTTPS (tipo 65)"
MTASTS=$(q "_mta-sts.$DOMINIO" TXT | tr -d '"' | head -1)
[[ -n $MTASTS ]] && echo "ℹ️  Reto 2: MTA-STS publicado: $MTASTS" || echo "ℹ️  Reto 2: sin MTA-STS (_mta-sts TXT)"
echo "────────────────────────────────────────────────────────────"
# Consulta y evaluación de DNSSEC
DS=$(q "$DOMINIO" DS)
AD=$(dig +dnssec +time=3 +tries=1 @"$RES" "$DOMINIO" SOA | grep -c 'flags:.* ad')
if [[ -n $DS && $AD -ge 1 ]]; then
  ok "DNSSEC: firmado y validado (DS en $PADRE, flag ad)"
elif [[ -n $DS ]]; then
  mal "DNSSEC: hay DS pero no se observó validación; revisar respuesta y resolutor"
else
  mal "DNSSEC: no firmado según DS consultado (sin DS en $PADRE)"
fi

echo "Puntaje: $bien de $total"

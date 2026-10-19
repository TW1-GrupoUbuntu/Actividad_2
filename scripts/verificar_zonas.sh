#!/usr/bin/env bash
# verificar_zonas.sh — Verificación automática del DNS autoritativo de horizonte.internal.
# Se ejecuta en el equipo anfitrión (con los contenedores ns1, ns2 y cliente en marcha):
#   bash scripts/verificar_zonas.sh
# Comprueba, en este orden: (1) sintaxis con named-checkconf y named-checkzone, (2) cada tipo de registro
# consultado desde el cliente SIN indicar servidor (usa el DNS propio), (3) respuestas con autoridad y serial
# igual en el secundario, (4) transferencia restringida por IP y por TSIG, (5) endurecimiento y (6) registros.
# Salida: ✅/❌ por prueba, "Resultado: N de M" y código de salida 0 solo si todo pasa.
# Opcional: AUTOR="Nombre" imprime una firma al final.
cd "$(dirname "$0")/.."
ok=0; total=0
Z=horizonte.internal; ZV4=10.10.10.in-addr.arpa; ZV6=0.1.0.0.8.b.d.0.1.0.0.2.ip6.arpa
KEY=/lab/compartido/transferencia.key
NS1=10.10.10.2; NS2=10.10.10.3

revisar() { local desc="$1"; shift; total=$((total + 1))
  if "$@" &>/dev/null; then echo "✅ $desc"; ok=$((ok + 1)); else echo "❌ $desc"; fi; }
en()      { local n=$1; shift; docker exec -i "$n" bash -c "$*"; }        # ejecutar dentro de un contenedor
cli()     { en cliente "$*"; }
# consulta con +short desde el cliente y compara con el valor esperado
es()      { [[ "$(cli "dig +short +time=3 +tries=1 $1")" == "$2" ]]; }
aa()      { cli "dig +norec +time=3 +tries=1 @$1 $2 ${3:-A}" | grep -q 'flags:.* aa'; }
serial()  { cli "dig +short +norec @$1 $2 SOA" | awk '{print $3}'; }
mismo_serial() { local a b; a=$(serial $NS1 "$1"); b=$(serial $NS2 "$1"); [[ -n $a && $a == "$b" ]]; }
# AXFR: salida de dig con "Transfer failed" = rechazada; con registros del dominio = permitida
axfr()    { en "$1" "dig $2 @$NS1 $Z AXFR"; }
permitida()  { axfr "$@" | grep -q 'aula-lab'; }
rechazada()  { axfr "$@" | grep -qE 'Transfer failed|REFUSED|connection refused|timed out'; }

echo "== 1. Sintaxis (named-checkconf / named-checkzone)"
revisar "named-checkconf en ns1"                       en ns1 named-checkconf
revisar "named-checkconf en ns2"                       en ns2 named-checkconf
revisar "named-checkzone $Z"                           en ns1 "named-checkzone $Z /var/lib/bind/db.$Z"
revisar "named-checkzone $ZV4"                         en ns1 "named-checkzone $ZV4 /var/lib/bind/db.10.10.10"
revisar "named-checkzone $ZV6"                         en ns1 "named-checkzone $ZV6 /var/lib/bind/db.2001.db8.10"
revisar "Archivos instalados = archivos del repositorio (ns1)" \
        en ns1 "cmp -s /lab/ns1/db.$Z /var/lib/bind/db.$Z && cmp -s /lab/ns1/db.10.10.10 /var/lib/bind/db.10.10.10"

echo "== 2. Registros vistos desde el cliente (DNS propio, sin @)"
revisar "cliente usa el DNS propio (resolv.conf o dns de Docker = ns1/ns2)" \
        bash -c "docker inspect cliente --format '{{json .HostConfig.Dns}}' | grep -q '$NS1'"
revisar "getent ahostsv4 www.$Z → 10.10.10.20 (libc)" bash -c "docker exec cliente getent ahostsv4 www.$Z | grep -q ^10.10.10.20"
revisar "SOA: primario ns1 y contacto ti"              bash -c "docker exec cliente dig +short SOA $Z | grep -q '^ns1.$Z. ti.$Z. '"
revisar "NS: ns1 y ns2"                                bash -c "[[ \"\$(docker exec cliente dig +short NS $Z | sort | tr '\n' ' ')\" == 'ns1.$Z. ns2.$Z. ' ]]"
revisar "A: www → 10.10.10.20"                         es "www.$Z A" 10.10.10.20
revisar "AAAA: www → 2001:db8:10::20"                  es "www.$Z AAAA" 2001:db8:10::20
revisar "CNAME: portal → www"                          bash -c "docker exec cliente dig +short CNAME portal.$Z | grep -qx 'www.$Z.'"
revisar "MX: 10 mail"                                  es "$Z MX" "10 mail.$Z."
revisar "TXT: SPF v=spf1 mx -all"                      es "$Z TXT" '"v=spf1 mx -all"'
revisar "CAA: solo la CA del colegio"                  bash -c "docker exec cliente dig +short CAA $Z | grep -q 'issue \"$Z\"'"
revisar "SRV: _ldap._tcp → ldap:389"                   es "_ldap._tcp.$Z SRV" "10 100 389 ldap.$Z."
revisar "PTR IPv4: 10.10.10.25 → mail"                 es "-x 10.10.10.25" "mail.$Z."
revisar "PTR IPv4: 10.10.10.20 → www"                  es "-x 10.10.10.20" "www.$Z."
revisar "PTR IPv6: 2001:db8:10::20 → www"              es "-x 2001:db8:10::20" "www.$Z."
revisar "Nombre inexistente → NXDOMAIN"                bash -c "docker exec cliente dig noexiste.$Z | grep -q 'status: NXDOMAIN'"

echo "== 3. Autoridad y sincronización del secundario"
revisar "ns1 responde con autoridad (aa)"              aa $NS1 www.$Z
revisar "ns2 responde con autoridad (aa)"              aa $NS2 www.$Z
revisar "ns2 responde el CNAME y la inversa copiados"  bash -c "[[ \"\$(docker exec cliente dig +short +norec @$NS2 -x 10.10.10.25)\" == 'mail.$Z.' ]]"
revisar "Mismo serial en ns1 y ns2: $Z"                mismo_serial $Z
revisar "Mismo serial en ns1 y ns2: $ZV4"              mismo_serial $ZV4
revisar "Mismo serial en ns1 y ns2: $ZV6"              mismo_serial $ZV6

echo "== 4. Transferencia de zona restringida (IP + TSIG)"
revisar "Desde el cliente, SIN clave: rechazada"                  rechazada cliente ""
revisar "Desde el cliente, CON clave TSIG (IP no autorizada): rechazada" rechazada cliente "-k $KEY"
revisar "Desde ns2, SIN clave (IP correcta): rechazada"           rechazada ns2 ""
revisar "Desde ns2, CON clave TSIG (IP y clave): permitida"       permitida ns2 "-k $KEY"
revisar "Zona inversa IPv6: desde ns2 con clave, permitida"       bash -c "docker exec ns2 dig -k $KEY @$NS1 $ZV6 AXFR | grep -q 'mail.$Z'"

echo "== 5. Endurecimiento"
revisar "ns1 no hace recursión (REFUSED a google.com)" bash -c "docker exec cliente dig @$NS1 google.com | grep -q 'status: REFUSED'"
revisar "ns2 no hace recursión (REFUSED a google.com)" bash -c "docker exec cliente dig @$NS2 google.com | grep -q 'status: REFUSED'"
revisar "Versión de BIND oculta en ns1 y ns2"          bash -c "[[ \"\$(docker exec cliente dig +short @$NS1 CH TXT version.bind)\" == '\"no disponible\"' && \"\$(docker exec cliente dig +short @$NS2 CH TXT version.bind)\" == '\"no disponible\"' ]]"

echo "== 6. Registros de BIND (revisión de logs)"
revisar "ns1 registró transferencias permitidas (AXFR ended)" en ns1 "grep -q 'AXFR ended' /var/log/named/transferencias.log"
revisar "ns1 registró transferencias denegadas (denied)"      en ns1 "grep -q 'denied' /var/log/named/transferencias.log"
revisar "ns2 registró la transferencia entrante firmada con TSIG" en ns2 "grep -q 'TSIG transferencia-horizonte' /var/log/named/transferencias.log"

echo "Resultado: $ok de $total comprobaciones"
[[ -n "${AUTOR:-}" ]] && echo "$AUTOR"
[[ $ok -eq $total ]]

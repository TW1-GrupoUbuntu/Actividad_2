# Ubuntu 24.04 con systemd + BIND 9.18 y herramientas de consulta (dig, tcpdump, ping).
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive TZ=America/La_Paz
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus tzdata ca-certificates iproute2 iputils-ping curl nano less \
      bind9 bind9-utils bind9-dnsutils tcpdump \
    && systemctl disable named \
    && find /etc/systemd/system /lib/systemd/system -path '*.wants/*' \
         \( -name '*getty*' -o -name 'systemd-logind*' -o -name 'systemd-resolved*' \) -delete || true \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

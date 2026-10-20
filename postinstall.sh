#!/usr/bin/env bash
# Router configuration for Debian 12. Runs inside the new system at the end
# of the install (also safe to run by hand later: sudo bash postinstall.sh).
set -euo pipefail

############################ EDIT THESE ############################
WAN_IF=ens32                 # outside, towards 10.10.10.0/24
LAN_IF=ens33                 # inside, 172.16.13.0/24
WAN_IP=10.10.10.113
WAN_PREFIX=24
WAN_GW=10.10.10.1            # ASSUMPTION - set your real gateway
UPSTREAM_DNS=10.10.10.1      # DNS server the router forwards to
LAN_IP=172.16.13.1           # ASSUMPTION - router's address on the LAN
SERVER_IP=172.16.13.100      # LX-SERVER (Apache), fixed by DHCP reservation
WIN_IP=172.16.13.254         # Windows PC (RDP), fixed by DHCP reservation
ADMIN_PC=10.10.10.23         # the only outside host allowed SSH + RDP
SERVER_MAC=""                # e.g. 00:0c:29:aa:bb:cc  (empty = no reservation yet)
WIN_MAC=""
###################################################################

# ---------- Network interfaces ----------
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto ${WAN_IF}
iface ${WAN_IF} inet static
    address ${WAN_IP}/${WAN_PREFIX}
    gateway ${WAN_GW}

auto ${LAN_IF}
iface ${LAN_IF} inet static
    address ${LAN_IP}/24
EOF

# ---------- IP forwarding ----------
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-router.conf

# ---------- Firewall (iptables-persistent) ----------
mkdir -p /etc/iptables
cat > /etc/iptables/rules.v4 <<EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -m comment --comment "Povoleni navazanych spojeni" -j ACCEPT
-A INPUT -p icmp -m icmp --icmp-type 8 -m comment --comment "Povoleni pingu" -j ACCEPT
-A INPUT -s ${ADMIN_PC}/32 -p tcp -m tcp --dport 22 -m comment --comment "Povoleni ssh z fyzickeho PC" -j ACCEPT
-A INPUT -i ${LAN_IF} -m comment --comment "Povoleni pristupu z vnitrni site" -j ACCEPT
-A INPUT -i lo -m comment --comment "Povoleni loopback" -j ACCEPT
-A FORWARD -i ${WAN_IF} -o ${LAN_IF} -m state --state RELATED,ESTABLISHED -m comment --comment "Povoleni navazanych spojeni" -j ACCEPT
-A FORWARD -s 172.16.13.128/25 -i ${LAN_IF} -o ${WAN_IF} -p tcp -m multiport --dports 80,443,53 -m comment --comment "Povoleni sluzeb z DHCP PCs" -j ACCEPT
-A FORWARD -s 172.16.13.128/25 -i ${LAN_IF} -o ${WAN_IF} -p udp -m udp --dport 53 -m comment --comment "Povoleni DNS z DHCP PCs" -j ACCEPT
-A FORWARD -s 172.16.13.0/25 -i ${LAN_IF} -o ${WAN_IF} -m comment --comment "Povoleni statickych PCs" -j ACCEPT
-A FORWARD -d ${SERVER_IP}/32 -i ${WAN_IF} -o ${LAN_IF} -p tcp -m tcp --dport 80 -m comment --comment "Povoleni www na LX-SERVER" -j ACCEPT
-A FORWARD -s ${ADMIN_PC}/32 -d ${WIN_IP}/32 -i ${WAN_IF} -o ${LAN_IF} -p tcp -m tcp --dport 3389 -m comment --comment "Povoleni RDP na WIN10" -j ACCEPT
-A FORWARD -s ${WIN_IP}/32 -i ${LAN_IF} -o ${WAN_IF} -p tcp -m tcp --sport 3389 -m comment --comment "Povoleni RDP odpovedi z WIN10" -j ACCEPT
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -i ${WAN_IF} -p tcp -m tcp --dport 80 -m comment --comment "Preklad pro LX-SERVER" -j DNAT --to-destination ${SERVER_IP}
-A PREROUTING -i ${WAN_IF} -p tcp -m tcp --dport 3389 -m comment --comment "Preklad pro WIN10" -j DNAT --to-destination ${WIN_IP}
-A POSTROUTING -o ${WAN_IF} -j SNAT --to-source ${WAN_IP}
COMMIT
EOF

# ---------- DHCP server ----------
cat > /etc/default/isc-dhcp-server <<EOF
INTERFACESv4="${LAN_IF}"
INTERFACESv6=""
EOF

cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
default-lease-time 600;
max-lease-time 7200;
option domain-name "lab.local";
option domain-name-servers ${LAN_IP};

subnet 172.16.13.0 netmask 255.255.255.0 {
    option routers ${LAN_IP};
    range 172.16.13.129 172.16.13.253;   # DHCP pool (upper /25, minus .254)
}
EOF

if [[ -n "$SERVER_MAC" ]]; then
cat >> /etc/dhcp/dhcpd.conf <<EOF

host lx-server {
    hardware ethernet ${SERVER_MAC};
    fixed-address ${SERVER_IP};
}
EOF
fi

if [[ -n "$WIN_MAC" ]]; then
cat >> /etc/dhcp/dhcpd.conf <<EOF

host win10 {
    hardware ethernet ${WIN_MAC};
    fixed-address ${WIN_IP};
}
EOF
fi

# ---------- DNS (BIND9 caching forwarder for the LAN) ----------
cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";
    listen-on { 127.0.0.1; ${LAN_IP}; };
    listen-on-v6 { none; };
    allow-query { 127.0.0.0/8; 172.16.13.0/24; };
    allow-recursion { 127.0.0.0/8; 172.16.13.0/24; };
    forwarders { ${UPSTREAM_DNS}; };
    dnssec-validation auto;
};
EOF

# ---------- SSH hardening ----------
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
MaxAuthTries 3
X11Forwarding no
EOF

# ---------- Enable services (they start on first boot) ----------
systemctl enable ssh isc-dhcp-server named netfilter-persistent

# ---------- Router uses its own DNS (written last) ----------
cat > /etc/resolv.conf <<EOF
search lab.local
nameserver 127.0.0.1
EOF

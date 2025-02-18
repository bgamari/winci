#!/bin/sh

set -eu

# think of the children!
set -m

# deps for debian:bookworm-slim
# apt install --no-install-recommends \
#	build-essential \
#	ca-certificates \
#	git \
#	libssl-dev \
#	libtalloc-dev \
#	qemu-system \
#	sshpass \
#	tcpdump \
#	wireshark-common

: ${ADDR:=127.0.0.1}
: ${PORT:=1812}
: ${SECRET:=testing123}

: ${FREERAD_GIT:=https://github.com/FreeRADIUS/freeradius-server.git}
: ${FREERAD_REF:=v3.2.x}

: ${HOSTAPD_GIT:=https://w1.fi/hostap.git}
: ${HOSTAPD_REF:=main}

JOBS=$(($(getconf _NPROCESSORS_ONLN) + 1))
IFACE=winci-dot1x
MON=qemu-monitor

: ${TEST:=eap-ttls/pap}

qemu_mon () {
	echo $@ >&9
}

cleanup () {
	[ ! -p "$MON" ] || {
		qemu_mon quit || true
		exec 9>&-
		rm -f spice.sock "$MON"
	}

	[ -z "${FREERAD:-}" ] || {
		./freeradius-server/scripts/bin/radmin -f radiusd.sock -e terminate >/dev/null 2>&1 || true
		while kill -0 $FREERAD 2>/dev/null; do sleep 0.5; done
		rm -f radiusd.sock
	}

	[ -z "${HOSTAPD:-}" ] || {
		kill -TERM $HOSTAPD || true
		while kill -0 $HOSTAPD 2>/dev/null; do sleep 0.5; done
		sudo rm -rf hostapd
		# FIXME something deletes this before I do...?
		#rm hostapd.conf
	}

	sudo ip link del $IFACE 2>/dev/null || true

	[ -z "${PCAP:-}" ] || {
		kill -TERM $PCAP || true
		while kill -0 $PCAP 2>/dev/null; do sleep 0.5; done
		if [ -f logs/radiusd/sslkey.log ]; then
			editcap --inject-secrets tls,logs/radiusd/sslkey.log logs/dump.pcap logs/dump.pcapng
			rm logs/radiusd/sslkey.log
		else
			editcap logs/dump.pcap logs/dump.pcapng
		fi
		rm logs/dump.pcap
	}
}
trap cleanup EXIT INT TERM

test -f "freeradius-server/.stamp_$FREERAD_REF" || {
	rm -rf freeradius-server
	git clone --no-tags --depth 1 --single-branch --branch "$FREERAD_REF" "$FREERAD_GIT"
	( cd freeradius-server && ./configure --enable-developer )
	make -C freeradius-server -j $JOBS
	make -C freeradius-server/raddb/certs
	sed -ie 's/^\(\s\+socket\) = .*/\1 = radiusd.sock/; s/^#\?\(\s\+mode\) = .*/\1 = rw/' freeradius-server/raddb/sites-available/control-socket
	ln -s -t freeradius-server/raddb/sites-enabled ../sites-available/control-socket
	sed -ie '/^#\?bob\s/ { s/^#//; n; s/^#//; n; s/^#// }' freeradius-server/raddb/mods-config/files/authorize
	touch "freeradius-server/.stamp_$FREERAD_REF"
}
test -f "hostap/.stamp_$HOSTAPD_REF" || {
	git clone --no-tags --depth 1 --single-branch --branch "$HOSTAPD_REF" "$HOSTAPD_GIT"
	# CONFIG_TESTING_OPTIONS enabled use of SSLKEYLOG
	sed -e 's/^#\?\(CONFIG_DRIVER_WIRED\)=.*/\1=y/; s/^#\?\(CONFIG_DRIVER_NL80211.*\)/#\1/; s/^#\?\(CONFIG_DRIVER_NONE\)=.*/\1=y/; s/^#\?\(CONFIG_EAP_TEAP\)=.*/\1=y/; s/^#\?\(CONFIG_TESTING_OPTIONS\)=.*/\1=y/' hostap/hostapd/defconfig > hostap/hostapd/.config
	make -C hostap/hostapd -j $JOBS
	touch "hostap/.stamp_$HOSTAPD_REF"
}

rm -rf logs
mkdir logs

sudo ip tuntap add $IFACE mode tap user $USER
sudo ip link set dev $IFACE up

mkdir logs/hostapd
m4 -DGROUP=$(id -g) -DIFACE=$IFACE -DADDR=$ADDR -DPORT=$PORT -DSECRET=$SECRET hostapd.conf.m4 > hostapd.conf
sudo ./hostap/hostapd/hostapd hostapd.conf > logs/hostapd/stdout &
HOSTAPD=$!

mkdir logs/radiusd
env SSLKEYLOGFILE=logs/radiusd/sslkey.log ./freeradius-server/scripts/bin/radiusd -X > logs/radiusd/stdout &
FREERAD=$!

mkfifo "$MON"
/bin/sh ../../vm.sh \
	-netdev tap,id=user.1,ifname=$IFACE,script=no,downscript=no \
	-device virtio-net-pci,netdev=user.1 \
	-usb -device usb-ccid -device ccid-card-emulated,backend=certificates,db=nssdb,cert1=cert1,cert2=cert2,cert3=cert3 \
	<"$MON" >/dev/null &
QEMU=$!
exec 9> "$MON"
# initially unplug NIC
qemu_mon set_link user.1 off

SSHARGS="-o ConnectTimeout=3 -o Port=2222 -o User=Administrator -o PasswordAuthentication=yes"
guest_ssh () {
	env SSHPASS=${PASSWORD:-password} sshpass -e ssh $SSHARGS localhost "$@"
}
guest_scp () {
	# large transfers fail without '-O'
	env SSHPASS=${PASSWORD:-password} sshpass -e scp $SSHARGS -O "$@"
}
# wait for the VM to be ready
while ! guest_ssh echo >/dev/null 2>&1; do sleep 1; done

# start dot1x
guest_ssh sc config dot3svc start=demand >/dev/null
guest_ssh sc start dot3svc >/dev/null

# install certificates
guest_scp freeradius-server/raddb/certs/ca.der freeradius-server/raddb/certs/client.p12 localhost:Desktop/
guest_ssh certutil.exe -addstore Root Desktop/ca.der > /dev/null
guest_ssh certutil.exe -p whatever -importpfx Desktop/client.p12 >/dev/null

# install profile
CAHASHSHA1=$(openssl dgst -sha1 -c freeradius-server/raddb/certs/ca.der | sed -e 's/.*= //; s/:/ /g')
CAHASHSHA256=$(openssl dgst -sha256 -c freeradius-server/raddb/certs/ca.der | sed -e 's/.*= //; s/:/ /g')
# for reference, this is ';' seperated which makes perfect sense in an XML document...right?
SERVERNAMES=$(openssl x509 -noout -subject -in freeradius-server/raddb/certs/server.pem | sed -e 's/.* CN = \([^,]\+\).*/\1/')
m4 -DCAHASH="$CAHASHSHA1" -DCAHASHSHA256="$CAHASHSHA256" -DSERVERNAMES="$SERVERNAMES" tests/$TEST/Ethernet.xml.m4 > Ethernet.xml
guest_scp Ethernet.xml tests/$TEST/Credentials.xml localhost:Desktop/
guest_ssh 'netsh lan add profile interface="Ethernet 2" filename="Desktop/Ethernet.xml"' >/dev/null
[ -f "tests/$TEST/allusers" ] && ALLUSERS=yes || ALLUSERS=no
guest_ssh "netsh lan set eapuserdata interface=\"Ethernet 2\" filename=\"Desktop/Credentials.xml\" allusers=$ALLUSERS" >/dev/null
rm Ethernet.xml

sudo tcpdump -q -n -p -Z $USER -i lo -U -w logs/dump.pcap udp and port 1812 >/dev/null &
PCAP=$!

[ -z "${NETTRACE:-}" ] || {
	# TEAP is seemingly the only method that logs to the net tracer
	guest_ssh netsh trace start wireless_dbg globalLevel=0xff capture=yes tracefile=Desktop/trace.etl >/dev/null
}

# turn on the NIC to kick off the authentication
qemu_mon set_link user.1 on

C=60
R=-1
while [ $C -gt 0 ]; do
	C=$((C - 1))
	S=$(guest_ssh netsh lan show interfaces | sed -ne '/^\s*Name\s*:\s*Ethernet 2\s*$/,/^\s*State\s*/ { s/^\s*State\s*: // p }')
	case "$S" in
	*succeeded*)
		R=0
		break
		;;
	*failed*)
		R=1
		break
		;;
	esac
	sleep 0.5
done

[ -z "${NETTRACE:-}" ] || {
	guest_ssh netsh trace stop >/dev/null
	guest_ssh netsh trace convert Desktop/trace.etl
	mkdir logs/win
	guest_scp 'localhost:Desktop/trace.*' logs/win/
}

sleep inf

qemu_mon set_link user.1 off

exit 0

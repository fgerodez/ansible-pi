#! /bin/bash
#
# This script is used to create / destroy the wireguard tunnel
#
#
# 2. UP:       Create the tunnel and retrieve a forwarded port
#   
# 3. DOWN:     Shutdown the tunnel and destroy the interface

PIA_COUNTRY="$2"

up ()
{
	serverlist_url='https://serverlist.piaservers.net/vpninfo/servers/v6'

	pia_user=$(awk 'NR==1' login.conf)
	pia_pass=$(awk 'NR==2' login.conf)

	pia_wg_ip=$(curl -s "$serverlist_url" | head -1 | jq -r ".regions[] | select(.id == \"$PIA_COUNTRY\") | .servers.wg[0].ip")
	pia_token=$(curl -ks -u "$pia_user:$pia_pass" --max-time 10 "https://privateinternetaccess.com/gtoken/generateToken")

	if [ "$(echo "$pia_token" | jq -r '.status')" != "OK" ]; then
		echo "Unable to retrieve the PIA token"
		exit 1
	fi
	
	token="$(echo "$pia_token" | jq -r '.token')"
	
	# Create ephemeral wireguard keys, that we don't need to save to disk.
	privKey="$(wg genkey)"
	pubKey="$(echo "$privKey" | wg pubkey)"
	
	echo Trying to connect to the PIA WireGuard API on $pia_wg_ip...
	wireguard_json="$(curl -skG \
  	--data-urlencode "pt=${token}" \
  	--data-urlencode "pubkey=$pubKey" \
  	"https://${pia_wg_ip}:1337/addKey")"

	echo "$wireguard_json"
	if [ "$(echo "$wireguard_json" | jq -r '.status')" != "OK" ]; then
		>&2 echo -e "Server did not return OK. Stopping now."
		exit 1
	fi

	echo -n "Trying to write /etc/wireguard/pia.conf..."

	mkdir -p /etc/wireguard

	echo "
	  [Interface]
  	  PrivateKey = $privKey
  	  [Peer]
  	  PersistentKeepalive = 25
  	  PublicKey = $(echo "$wireguard_json" | jq -r '.server_key')
  	  AllowedIPs = 0.0.0.0/0
  	  Endpoint = ${pia_wg_ip}:$(echo "$wireguard_json" | jq -r '.server_port')
  	  " > "/etc/wireguard/pia_${PIA_COUNTRY}.conf" || exit 1

	echo -e "OK!"

	pia_server_vip=$(echo "$wireguard_json" | jq -r '.server_vip')
	peer_ip=$(echo "$wireguard_json" | jq -r '.peer_ip')

	# Start the WireGuard interface.
	echo "Trying to create the wireguard interface..."

	ip link add {{ transmission_wg_interface }} type wireguard
	ip addr add "$peer_ip/32" dev {{ transmission_wg_interface }}

	wg setconf {{ transmission_wg_interface }} "/etc/wireguard/pia_${PIA_COUNTRY}.conf"

	ip link set {{ transmission_wg_interface }} up

	# Add default route to torrent routing table
	ip route add default dev {{ transmission_wg_interface }} metric 2 table torrent

	echo -e "The WireGuard interface got created."

	payload_and_signature=$(curl -ks -m 5 \
							   --interface {{ transmission_wg_interface }} \
							   --cacert ca.rsa.4096.crt \
							   -G --data-urlencode "token=${token}" \
							   "https://$pia_server_vip:19999/getSignature")

	if [ "$(echo "$payload_and_signature" | jq -r '.status')" != "OK" ]; then
		echo "The payload_and_signature variable does not contain an OK status."
		echo "Signature: $payload_and_signature"
		exit 1
	fi

	signature="$(echo "$payload_and_signature" | jq -r '.signature')"
	payload="$(echo "$payload_and_signature" | jq -r '.payload')"
	port="$(echo "$payload" | base64 -d | jq -r '.port')"

	echo "Received port ${port}"
	
	systemd-notify --ready

	# Now we have all required data to create a request to bind the port.
	# We will repeat this request every 15 minutes, in order to keep the port
	# alive. The servers have no mechanism to track your activity, so they
	# will just delete the port forwarding if you don't send keepalives.
	while true; do
		bind_port_response=$(curl -Gks --interface {{ transmission_wg_interface }} -m 5 \
								--cacert ca.rsa.4096.crt \
								--data-urlencode "payload=${payload}" \
								--data-urlencode "signature=${signature}" \
								"https://${pia_server_vip}:19999/bindPort")
		
		if [ "$(echo "$bind_port_response" | jq -r '.status')" != "OK" ]; then
			echo "The API did not return OK when trying to bind port. Exiting."
			down
			
			exit 1
		fi

		# Send the port to transmission
		docker exec {{ transmission_container_name }} /usr/bin/transmission-remote 127.0.0.1 --port "$port"
		
		sleep 900
	done
}

down()
{
	ip link set {{ transmission_wg_interface }} down
	ip link del {{ transmission_wg_interface }}

	rm "/etc/wireguard/pia_${PIA_COUNTRY}.conf"
}

case $1 in
  "UP") up;;
  "DOWN") down;;
  *) echo "UP OR DOWN"
esac

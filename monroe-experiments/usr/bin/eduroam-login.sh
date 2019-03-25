#!/bin/bash

EDUROAM_IDENTITY=$1
EDUROAM_HASH=$2

if [ ${#EDUROAM_IDENTITY} -ge 100 ]; then
  logger -t eduroam_login "input (identity) too long.";
  exit
fi
if [ ${#EDUROAM_HASH} -ge 100 ]; then
  logger -t eduroam_login "input (hash) too long.";
  exit
fi

cat > /etc/wpa_supplicant/wpa_supplicant.eduroam.conf << EOF
ap_scan=1
network={
        disabled=0
        auth_alg=OPEN
        ssid="eduroam"
        scan_ssid=1
        key_mgmt=WPA-EAP
        proto=WPA RSN
        pairwise=CCMP TKIP
        eap=PEAP
        phase1="peaplabel=0"
        phase2="auth=MSCHAPV2"
        identity="$EDUROAM_IDENTITY"
        password="$EDUROAM_HASH"
}
EOF

systemctl stop wpa_supplicant
pkill wpa_supplicant

ifconfig wlan0 up
/sbin/wpa_supplicant -Bc /etc/wpa_supplicant/wpa_supplicant.eduroam.conf -i wlan0

sleep 10
dhclient -r wlan0
dhclient wlan0


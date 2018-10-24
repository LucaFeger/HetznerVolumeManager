#!/bin/bash
command -v curl >/dev/null || { echo "Installing curl..."; sudo apt install -y curl; }
command -v jq >/dev/null || { echo "Installting jq..."; sudo apt install -y jq; }

# Get Hetzner Server ID
IP="$(dig +short myip.opendns.com @resolver1.opendns.com)"
IP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -H "Authorization: Bearer $1" https://api.hetzner.cloud/v1/servers)

SERVER_OBJECT=$(jq '.servers[]|select(.public_net.ipv4.ip=="'"$IP"$'")' <<< "$IP_RESPONSE" 2>/dev/null)
SERVER_ID=$(jq ".id" <<< "$SERVER_OBJECT" 2>/dev/null)

# POST Attach Volume to Hetzner
RESULT=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $1" -d '{"server": '$SERVER_ID$'}' https://api.hetzner.cloud/v1/volumes/$2/actions/detach)
HTTP_BODY=$(echo "$RESULT" | sed -e 's/HTTPSTATUS\:.*//g')
ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

if [ "$ERROR_CHECK" = "null" ]; then
	echo "Unmounting volume"
	
	MOUNT_TEMP="$3"
	MOUNT_PATH="/mnt/$MOUNT_TEMP"
	
	echo "Remove existing mounts"
        sudo umount -R "$MOUNT_PATH" &> /dev/null
        echo "removing old directory"
        sudo rm -rf "$MOUNT_PATH" &> /dev/null

        echo "The mount at $MOUNT_PATH was deleted!"

	if [ $4 == true ]; then
		sleep 5

		./helpers/deleteVolume.sh $1 $2
		echo "The volume was deleted!"
	fi	
else
	echo "An error occured: $ERROR_CHECK"
fi

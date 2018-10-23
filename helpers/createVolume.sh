#!/bin/bash
command -v curl >/dev/null 2>&1 || { echo "Installing curl..."; sudo apt install -y curl; }
command -v jq >/dev/null 2>&1 || { echo "Installing jq..."; sudo apt install -y curl; }

IP="$(dig +short myip.opendns.com @resolver1.opendns.com)"
SERVER_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -H "Authorization: Bearer $1" https://api.hetzner.cloud/v1/servers)

SERVER_OBJECT=$(jq '.servers[]|select(.public_net.ipv4.ip=="'"$IP"$'")' <<< "$SERVER_RESPONSE" 2>/dev/null)
SERVER_ID=$(jq ".id" <<< "$SERVER_OBJECT" 2>/dev/null)

HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $1" -d '{"size": '$2$', "name": "'"$3"$'", "server": '$SERVER_ID'}' https://api.hetzner.cloud/v1/volumes)

echo "Creating volume..."
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')
ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

if [ "$ERROR_CHECK" = "null" ]; then
	echo "Configuring volume..."

	LINUX_TEMP=$(jq '.volume.linux_device' <<< "$HTTP_BODY" 2>/dev/null)
	LINUX_DEVICE="${LINUX_TEMP//\"}"
	MOUNT_PATH="/mnt/$3"
	
	echo "Waiting for the container to create (7 seconds)"
	sleep 7

	echo "Remove existing mounts"
	umount -R "$MOUNT_PATH" &> /dev/null
	echo "removing old directory"
	rm -rf "$MOUNT_PATH" &> /dev/null

	echo "mounting to directory"

	sudo mkfs.ext4 -F "$LINUX_DEVICE" &>/dev/null
	mkdir "$MOUNT_PATH" &>/dev/null
	mount -o discard,defaults "$LINUX_DEVICE" "$MOUNT_PATH" &> /dev/null
	echo "The volume is now mounted to $MOUNT_PATH !"
else
	echo "An error occured: $ERROR_CHECK"
fi

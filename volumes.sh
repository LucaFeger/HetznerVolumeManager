#!/bin/bash
DIALOG=${DIALOG=dialog}

if [ -z $1 ]; then
    echo "Please provide your API-KEY"
    exit 1
fi

command -v dialog >/dev/null 2>&1 || { echo "installing dialog..."; sudo apt install -y dialog; }
command -v curl >/dev/null 2>&1 || { echo "installing curl..."; sudo apt install -y curl; }
command -v jq >/dev/null 2>&1 ||{ echo "installing jq..."; sudo apt install -y jq; }

ANSWER=$(dialog --title "Choose action" --default-item "1" \
       	--menu "Select:" 0 0 0 \
	1 "Create and mount volume" \
	2 "Mount volume" \
	3 "Unmount volume" \
	4 "Delete and unmount volume" 3>&1 1>&2 2>&3)
clear
case $ANSWER in
	1)
		# BEGINNING OF SECTION "CREATE AND MOUNT VOLUME"
		SIZE=

		until [[ $SIZE =~ ^[0-9]+$ && $SIZE -gt 9 ]]; do
			SIZE=$(dialog --title "Volume Setup" --inputbox "Enter the volume size in GB (min 10):" 8 40 3>&1 1>&2 2>&3 3>&-)
		done

		dialog --clear
		NAME=$(dialog --title "Volume Setup" --inputbox "Enter the volume name:" 8 40 3>&1 1>&2 2>&3 3>&-)
		clear

		./helpers/createVolume.sh "$1" "$SIZE" "$NAME";;
	2)
		# BEGINNING OF SECTION "MOUNT VOLUME"

		ALL_VOLUMES_HTTP=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -H "Authorization: Bearer $1" https://api.hetzner.cloud/v1/volumes)
		ALL_VOLUME_NAMES=$(echo $ALL_VOLUMES_HTTP | jq -r '.volumes[].name')

			
		VALUES=""
		for i in $ALL_VOLUME_NAMES; do
			if [ "$(jq -r '.volumes[]|select(.name=="'$i'")|.server' <<< "$ALL_VOLUMES_HTTP")" == "null" ]; then
				VALUES="$VALUES $(jq -r '.volumes[]|select(.name=="'$i'")|.id' <<< "$ALL_VOLUMES_HTTP") $i"
			fi
		done
		
		if [ -z $VALUES ]; then
			echo "There is no volume that isn't mounted. Aborting..."
			exit 1	
		else
			SELECTED_VOLUME_ID=$(dialog --title "Volume mount" --menu "Select: " 0 0 0 $VALUES 3>&1 1>&2 2>&3)
			clear
		fi

		./helpers/mountVolume.sh "$1" "$SELECTED_VOLUME_ID" "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.linux_device' <<< "$ALL_VOLUMES_HTTP") 2>/dev/null"  "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)"
		;;
	[3-4])
		# BEGINNING OF SECTION UNMOUNT VOLUME
		ALL_VOLUMES_HTTP=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -H "Authorization: Bearer $1" https://api.hetzner.cloud/v1/volumes)
		ALL_VOLUME_NAMES=$(echo $ALL_VOLUMES_HTTP | jq -r '.volumes[].name' 2>/dev/null)

		ALL_SERVERS_HTTP=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -H "Authorization: Bearer $1" https://api.hetzner.cloud/v1/servers)

		IP="$(dig +short myip.opendns.com @resolver1.opendns.com)"

                VALUES=""
                for i in $ALL_VOLUME_NAMES; do
			server_id=$(jq -r '.volumes[]|select(.name=="'$i'")|.server' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)
			server_ip=$(jq -r '.servers[]|select(.id=='$server_id')|.public_net.ipv4.ip' <<< "$ALL_SERVERS_HTTP" 2>/dev/null)

			echo "$IP"
			echo "$server_ip"

                        if [ "$server_id" != "null" ] && [ "$server_ip" == "$IP" ]; then
                                VALUES="$VALUES $(jq -r '.volumes[]|select(.name=="'$i'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
                        fi
                done
		
		if [ -z $VALUES ]; then
			echo "There are no mounted volumes. Aborting..."
			exit 1
		else
			SELECTED_VOLUME_ID=$(dialog --title "Unmount volume" --menu "Select: " 0 0 0 $VALUES 3>&1 1>&2 2>&3)
			clear
		fi
		
		if [ $ANSWER == 4 ]; then
			./helpers/unmountVolume.sh "$1" "$SELECTED_VOLUME_ID"  "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" true
		else
			./helpers/unmountVolume.sh "$1" "$SELECTED_VOLUME_ID"  "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" false
		fi
		;;	
esac	

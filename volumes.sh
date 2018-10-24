#!/bin/bash
DIALOG=${DIALOG=dialog}

if [ -z $1 ]; then
    echo "Please provide your API-KEY"
    exit 1
fi

API_KEY="$1"

command -v dialog >/dev/null 2>&1 || { echo "installing dialog..."; sudo apt install -y dialog; }
command -v curl >/dev/null 2>&1 || { echo "installing curl..."; sudo apt install -y curl; }
command -v jq >/dev/null 2>&1 ||{ echo "installing jq..."; sudo apt install -y jq; }

IP=
ALL_VOLUMES_HTTP=
ALL_SERVERS_HTTP=
SERVER_ID=
ALL_VOLUME_NAMES=

#Startup Routine:
function startup {
    IP="$(dig +short myip.opendns.com @resolver1.opendns.com)"
    ALL_VOLUMES_HTTP=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes)
    ALL_SERVERS_HTTP=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/servers)

    SERVER_ID=$(jq '.servers[]|select(.public_net.ipv4.ip=="'"$IP"$'")|.id' <<< "$ALL_SERVERS_HTTP" 2>/dev/null)

    ALL_VOLUME_NAMES=$(echo $ALL_VOLUMES_HTTP | jq -r '.volumes[].name' 2>/dev/null)
}

startup

function createVolume {
    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"size": '$1$', "name": "'"$2"$'", "server": '$SERVER_ID'}' https://api.hetzner.cloud/v1/volumes)

    echo "Creating volume..."
    HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')
    ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

    if [ "$ERROR_CHECK" = "null" ]; then
        echo "Configuring volume..."

        LINUX_TEMP=$(jq '.volume.linux_device' <<< "$HTTP_BODY" 2>/dev/null)
        VOLUME_ID=$(jq '.volume.id' <<< "$HTTP_BODY" 2>/dev/null)
        LINUX_DEVICE="${LINUX_TEMP//\"}"
        MOUNT_PATH="/mnt/$2"

        echo "Waiting for the container to create"

        SUCCESS=false
        until [[ $SUCCESS = true ]]; do
            temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$VOLUME_ID/actions)"
            status=$(jq -r ".actions[]|select(.command==\"attach_volume\")|.status" <<< $temp_result 2>/dev/null)
            if [ "$status" = "success" ]; then
                SUCCESS=true
            fi
        done

        echo "Remove existing mounts"
        sudo umount -R "$MOUNT_PATH" &> /dev/null
        echo "removing old directory"
        sudo rm -rf "$MOUNT_PATH" &> /dev/null

        echo "mounting to directory"
        sudo mkfs.ext4 -F "$LINUX_DEVICE" &>/dev/null
        sudo mkdir -p "$MOUNT_PATH" &>/dev/null
        mount -o discard,defaults "$LINUX_DEVICE" "$MOUNT_PATH" &> /dev/null
        echo "The volume is now mounted to $MOUNT_PATH !"
    else
        echo "An error occured: $ERROR_CHECK"
    fi
}

function deleteVolume {
    curl --silent -X DELETE -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1
    echo "The volume was deleted!"
}


function unmountVolume {
    RESULT=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"server": '$SERVER_ID$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/detach)
    HTTP_BODY=$(echo "$RESULT" | sed -e 's/HTTPSTATUS\:.*//g')
    ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

    if [ "$ERROR_CHECK" = "null" ]; then
        echo "Unmounting volume"

        MOUNT_PATH="/mnt/$2"

        echo "Remove existing mounts"
            sudo umount -R "$MOUNT_PATH" &> /dev/null
            echo "removing old directory"
            sudo rm -rf "$MOUNT_PATH" &> /dev/null

            echo "The mount at $MOUNT_PATH was deleted!"

        if [ $3 == true ]; then
            SUCCESS=false
            until [[ $SUCCESS = true ]]; do
                temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1/actions)"
                status=$(jq -r "[.actions[]|select(.command==\"detach_volume\")|.status][-1]" <<< $temp_result 2>/dev/null)
                if [ "$status" = "success" ]; then
                    SUCCESS=true
                fi
            done

            deleteVolume $1
        fi
    else
        echo "An error occured: $ERROR_CHECK"
    fi
}

function mountVolume {
    RESULT=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"server": '$SERVER_ID$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/attach)
    HTTP_BODY=$(echo "$RESULT" | sed -e 's/HTTPSTATUS\:.*//g')
    ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

    if [ "$ERROR_CHECK" = "null" ]; then
        echo "Mounting volume..."
        LINUX_TEMP="$2"
        MOUNT_TEMP="$3"

        LINUX_DEVICE="${LINUX_TEMP//\"}"
        MOUNT_PATH="/mnt/$MOUNT_TEMP"

        SUCCESS=false
        until [[ $SUCCESS = true ]]; do
            temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1/actions)"
            status=$(jq -r "[.actions[]|select(.command==\"attach_volume\")|.status][-1]" <<< $temp_result 2>/dev/null)
            if [ "$status" = "success" ]; then
                SUCCESS=true
            fi
        done

        echo "Remove existing mounts"
        sudo umount -R "$MOUNT_PATH" # &> /dev/null
        echo "removing old directory"
        sudo rm -rf "$MOUNT_PATH" # &> /dev/null

        echo "mounting to directory"
        sudo mkdir "$MOUNT_PATH" # &>/dev/null
        mount -o discard,defaults "$LINUX_DEVICE" "$MOUNT_PATH" # &> /dev/null
        echo "The volume is now mounted to $MOUNT_PATH !"
    else
        echo "An error occured: $ERROR_CHECK"
    fi
}

ANSWER=$(dialog --title "Choose action" --default-item "1" \
       	--menu "Select:" 0 0 0 \
	1 "Create and mount volume" \
	2 "Mount volume" \
	3 "Unmount volume" \
	4 "Delete and unmount volume" 3>&1 1>&2 2>&3)
# clear
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

		createVolume "$SIZE" "$NAME";;
	2)
		# BEGINNING OF SECTION "MOUNT VOLUME"
			
		VALUES=""
		for i in $ALL_VOLUME_NAMES; do
			if [ "$(jq -r '.volumes[]|select(.name=="'$i'")|.server' <<< "$ALL_VOLUMES_HTTP")" == "null" ]; then
				VALUES="$VALUES $(jq -r '.volumes[]|select(.name=="'$i'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
			fi
		done
		
		if [ -z $VALUES ]; then
			echo "There is no volume that isn't mounted. Aborting..."
			exit 1	
		else
			SELECTED_VOLUME_ID=$(dialog --title "Volume mount" --menu "Select: " 0 0 0 $VALUES 3>&1 1>&2 2>&3)
			clear
		fi

		mountVolume "$SELECTED_VOLUME_ID" "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.linux_device' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)"  "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)"
		;;
	[3-4])
		# BEGINNING OF SECTION UNMOUNT VOLUME

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
			unmountVolume "$SELECTED_VOLUME_ID"  "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" true
		else
			unmountVolume "$SELECTED_VOLUME_ID"  "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" false
		fi
		;;	
esac	

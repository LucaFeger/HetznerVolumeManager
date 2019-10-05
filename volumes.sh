#!/bin/bash
DIALOG=${DIALOG=dialog}

if [ -z "$1" ]; then
    echo "Please provide your API-KEY"
    exit 1
fi

API_KEY="$1"

if [[ -z "$(command -v sudo)" ]]; then
	echo "sudo is not installed. Please install sudo as root"
fi

command -v dialog >/dev/null 2>&1 || { echo "installing dialog..."; sudo apt install -y dialog; }
command -v curl >/dev/null 2>&1 || { echo "installing curl..."; sudo apt install -y curl; }
command -v jq >/dev/null 2>&1 || { echo "installing jq..."; sudo apt install -y jq; }

IP="$(curl --silent ipecho.net/plain)"
ALL_VOLUMES_HTTP=
ALL_SERVERS_HTTP=
SERVER_ID=
ALL_VOLUME_NAMES=

#Startup Routine:
function startup {
    ALL_VOLUMES_HTTP=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes)
    ALL_SERVERS_HTTP=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/servers)

    SERVER_ID=$(jq '.servers[]|select(.public_net.ipv4.ip=="'"$IP"$'")|.id' <<< "$ALL_SERVERS_HTTP" 2>/dev/null)

    ALL_VOLUME_NAMES=$(echo "$ALL_VOLUMES_HTTP" | jq -r '.volumes[].name' 2>/dev/null)

    CLOSE=false
}

function createVolume {
    http_response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"size": '"$1"$', "name": "'"$2"$'", "server": '"$SERVER_ID"'}' https://api.hetzner.cloud/v1/volumes)

    dialog --aspect 100 --infobox "Creating volume..." 0 0
    sleep 0.5
    http_body=$(echo "$http_response" | sed -e 's/HTTPSTATUS\:.*//g')
    error_check=$(jq '.error.message' <<< "$http_body" 2>/dev/null)

    if [ "$error_check" = "null" ]; then
        dialog --aspect 100 --infobox "Configuring volume..." 0 0
        sleep 0.5

        linux_temp=$(jq '.volume.linux_device' <<< "$http_body" 2>/dev/null)
        volume_id=$(jq '.volume.id' <<< "$http_body" 2>/dev/null)
        linux_device="${linux_temp//\"}"
        mount_path="/mnt/$2"

        dialog --aspect 100 --infobox "Waiting for the container to create (this may take a few seconds)" 0 0

        success=false
        until [[ $success = true ]]; do
            temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$volume_id/actions)"
            status=$(jq -r ".actions[]|select(.command==\"attach_volume\")|.status" <<< "$temp_result" 2>/dev/null)
            if [ "$status" = "success" ]; then
                success=true
            fi
        done

        dialog --aspect 100 --infobox "Removing existing mounts" 0 0
        sleep 0.5
        sudo umount -R "$mount_path" &> /dev/null
        dialog --aspect 100 --infobox "Removing old directory" 0 0
        sleep 0.5
        sudo rm -rf "$mount_path" &> /dev/null

        dialog --aspect 100 --infobox "mounting to directory" 0 0
        sleep 0.5
        sudo mkfs.ext4 -F "$linux_device" &>/dev/null
        sudo mkdir -p "$mount_path" &>/dev/null
        mount -o discard,defaults "$linux_device" "$mount_path" &> /dev/null
        dialog --aspect 100 --msgbox "The volume is now mounted to $mount_path !" 0 0
    else
        dialog --aspect 100 --aspect 100 --msgbox "An error occured: $error_check" 0 0
    fi
}

function addVolume {
    http_response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"size": '$1$', "name": "'"$2"$'", "server": '$SERVER_ID'}' https://api.hetzner.cloud/v1/volumes)

    dialog --aspect 100 --infobox "Creating volume..." 0 0
    sleep 0.5
    http_body=$(echo "$http_response" | sed -e 's/HTTPSTATUS\:.*//g')
    error_check=$(jq '.error.message' <<< "$http_body" 2>/dev/null)

    volume_id=$(jq '.volume.id' <<< "$http_body" 2>/dev/null)

    success=false
    until [[ $success = true ]]; do
        temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$volume_id)"
        status=$(jq -r ".volume.status" <<< $temp_result 2>/dev/null)
        if [ "$status" = "available" ]; then
            success=true
        fi
    done

    dialog --aspect 100 --msgbox "Created Volume $2 successfully" 0 0
}

function deleteVolume {
    if [ "$(jq -r '.volumes[]|select(.id=='$1')|.protection.delete' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" = false ]; then
        curl --silent -X DELETE -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1
        dialog --aspect 100 --msgbox "The volume is now deleted" 0 0
    else
        dialog --aspect 100 --msgbox "Couldn't delete the volume, because it's locked" 0 0
    fi
}


function unmountVolume {
    result=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"server": '$SERVER_ID$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/detach)
    http_body=$(echo "$result" | sed -e 's/HTTPSTATUS\:.*//g')
    error_check=$(jq '.error.message' <<< "$http_body" 2>/dev/null)

    if [ "$error_check" = "null" ]; then
        dialog --aspect 100 --infobox "Unmounting volume" 0 0
        sleep 0.5

        mount_path="/mnt/$2"

        dialog --aspect 100 --infobox "Removing existing mounts" 0 0
        sleep 0.5
        sudo umount -R "$mount_path" &> /dev/null
        dialog --aspect 100 --infobox "Removing old directory" 0 0
        sleep 0.5
        sudo rm -rf "$mount_path" &> /dev/null
        dialog --aspect 100 --msgbox "The mount at $mount_path was deleted!" 0 0

        if [ -d $3 ]; then
            success=false
            until [[ $success = true ]]; do
                temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1/actions)"
                status=$(jq -r "[.actions[]|select(.command==\"detach_volume\")|.status][-1]" <<< $temp_result 2>/dev/null)
                if [ "$status" = "success" ]; then
                    success=true
                fi
            done

            deleteVolume "$1"
        fi
    else
        dialog --aspect 100 --msgbox "An error occured: $error_check" 0 0
    fi
}

function mountVolume {
    result=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"server": '$SERVER_ID$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/attach)
    http_body=$(echo "$result" | sed -e 's/HTTPSTATUS\:.*//g')
    error_check=$(jq '.error.message' <<< "$http_body" 2>/dev/null)

    if [ "$error_check" = "null" ]; then
        dialog --aspect 100 --infobox "Mounting volume..." 0 0
        sleep 0.5
        linux_temp="$2"
        mount_temp="$3"

        linux_device="${linux_temp//\"}"
        mount_path="/mnt/$mount_temp"

        success=false
        until [[ $success = true ]]; do
            temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1/actions)"
            status=$(jq -r "[.actions[]|select(.command==\"attach_volume\")|.status][-1]" <<< $temp_result 2>/dev/null)
            if [ "$status" = "success" ]; then
                success=true
            fi
        done

        dialog --aspect 100 --infobox "Remove existing mounts" 0 0
        sleep 0.5
        sudo umount -R "$mount_path" # &> /dev/null
        dialog --aspect 100 --infobox "Removing old directory" 0 0
        sleep 0.5
        sudo rm -rf "$mount_path" # &> /dev/null

        dialog --aspect 100 --infobox "Mounting to directory" 0 0
        sleep 0.5
        sudo mkdir "$mount_path" # &>/dev/null
        mount -o discard,defaults "$linux_device" "$mount_path" # &> /dev/null
        dialog --aspect 100 --msgbox "The volume is now mounted to $mount_path !" 0 0
    else
        dialog --aspect 100 --msgbox "An error occured: $error_check" 0 0
    fi
}

function resizeVolume {
    result=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"size": '$2$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/resize)
    http_body=$(echo "$result" | sed -e 's/HTTPSTATUS\:.*//g')
    error_check=$(jq '.error.message' <<< "$http_body" 2>/dev/null)

    if [ "$error_check" = "null" ]; then
        dialog --aspect 100 --infobox "Resizing volume..." 0 0

        success=false
        until [[ $success = true ]]; do
            temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1/actions)"
            status=$(jq -r "[.actions[]|select(.command==\"resize_volume\")|.status][-1]" <<< $temp_result 2>/dev/null)
            if [ "$status" = "success" ]; then
                success=true
            fi
        done

        mount_point="$3"
        file_system="$(lsblk | grep "$mount_point" | awk '{print $1;}')"
        dialog --aspect 100 --infobox "Resizing local partition..." 0 0
        sleep 0.5
        resize2fs /dev/$file_system >/dev/null

        dialog --aspect 100 --msgbox "The volume mounted at $mount_point has now a size of $2GB" 0 0
    else
        dialog --aspect 100 --msgbox "An error occured: $error_check" 0 0
    fi

}

function changeProtection {
    delete=
    if [ "$2" = true ]; then
        delete=false
    else
        delete=true
    fi

    result=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"delete": '$delete$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/change_protection)
    http_body=$(echo "$result" | sed -e 's/HTTPSTATUS\:.*//g')
    error_check=$(jq '.error.message' <<< "$http_body" 2>/dev/null)

    success=false
    until [[ $success = true ]]; do
        temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1/actions)"
        status=$(jq -r "[.actions[]|select(.command==\"change_protection\")|.status][-1]" <<< $temp_result 2>/dev/null)
        if [ "$status" = "success" ]; then
            success=true
        fi
    done

    if [ $delete = false ]; then
        dialog --aspect 100 --msgbox "The volume $3 is no longer protected" 0 0
    else
        dialog --aspect 100 --msgbox "The volume $3 is now protected" 0 0
    fi
}

function openMenu {
    answer=$(dialog --title "Choose action" --default-item "1" \
            --menu "Select:" 0 0 0 \
        1 "Create and mount volume" \
        2 "Mount volume" \
        3 "Unmount volume" \
        4 "Delete and unmount volume" \
        5 "Resize volume" \
        6 "Change protection" \
        7 "Delete volume" \
        8 "Add volume" 3>&1 1>&2 2>&3)
    # clear
    case $answer in
        1)
            # BEGINNING OF SECTION "CREATE AND MOUNT VOLUME"
            size=0

            until [[ $size =~ ^[0-9]+$ && $size -gt 9 ]] || [ -z $size ]; do
                size=$(dialog --title "Volume Setup" --inputbox "Enter the volume size in GB (min 10):" 8 40 3>&1 1>&2 2>&3 3>&-)
            done

            dialog --clear

            if [[ -n $size ]]; then
                NAME=$(dialog --title "Volume Setup" --inputbox "Enter the volume name:" 8 40 3>&1 1>&2 2>&3 3>&-)
                if [[ -n $NAME ]]; then
                    createVolume "$size" "$NAME"
                fi
            fi
            ;;
        2)
            # BEGINNING OF SECTION "MOUNT VOLUME"

            values=""
            for i in $ALL_VOLUME_NAMES; do
                if [ "$(jq -r '.volumes[]|select(.name=="'"$i"'")|.server' <<< "$ALL_VOLUMES_HTTP")" == "null" ]; then
                    values="$values $(jq -r '.volumes[]|select(.name=="'"$i"'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
                fi
            done

            if [ -z "$values" ]; then
                dialog --aspect 100 --infobox "There is no volume that isn't mounted." 0 0
                sleep 1
            else
                selected_volume_id=$(dialog --title "Volume mount" --menu "Select: " 0 0 0 "$values" 3>&1 1>&2 2>&3)
                clear
            fi

            mountVolume "$selected_volume_id" "$(jq -r '.volumes[]|select(.id=='"$selected_volume_id"')|.linux_device' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)"  "$(jq -r '.volumes[]|select(.id=='"$selected_volume_id"')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)"
            ;;
        [3-4])
            # BEGINNING OF SECTION UNMOUNT VOLUME

            values=""
            for i in $ALL_VOLUME_NAMES; do
                server_id=$(jq -r '.volumes[]|select(.name=="'"$i"'")|.server' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)
                server_ip=$(jq -r '.servers[]|select(.id=='"$server_id"')|.public_net.ipv4.ip' <<< "$ALL_SERVERS_HTTP" 2>/dev/null)

                if [ "$server_id" != "null" ] && [ "$server_ip" == "$IP" ]; then
                    values="$values $(jq -r '.volumes[]|select(.name=="'"$i"'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
                fi
            done

            execute=true
            if [ -z "$values" ]; then
                dialog --aspect 100 --infobox "There are no mounted volumes." 0 0
                execute=false
                sleep 1
            else
                selected_volume_id=$(dialog --title "Unmount volume" --menu "Select: " 0 0 0 "$values" 3>&1 1>&2 2>&3)
                clear
            fi


            if [ $execute = true ]; then
                if [ "$answer" -eq 4 ]; then
                    if [ "$(jq -r '.volumes[]|select(.id=='"$selected_volume_id"')|.protection.delete' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" = false ]; then
                        unmountVolume "$selected_volume_id"  "$(jq -r '.volumes[]|select(.id=='"$selected_volume_id"')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" true
                    else
                        dialog --aspect 100 --msgbox "Couldn't delete and unmount the volume, because it's locked. \nPlease use \"Unmount volume\"" 0 0
                    fi
                else
                    unmountVolume "$selected_volume_id"  "$(jq -r '.volumes[]|select(.id=='"$selected_volume_id"')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" false
                fi
            fi
            ;;
        5)
            values=""
            for i in $ALL_VOLUME_NAMES; do
                if [ "$(jq -r '.volumes[]|select(.name=="'"$i"'")|.server' <<< "$ALL_VOLUMES_HTTP")" == "$SERVER_ID" ]; then
                    values="$values $(jq -r '.volumes[]|select(.name=="'"$i"'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
                fi
            done

            execute=true
            if [ -z "$values" ]; then
                dialog --aspect 100 --infobox "There are no mounted volumes." 0 0
                execute=false
                sleep 1
            else
                selected_volume_id=$(dialog --title "Resize volume" --menu "Select: " 0 0 0 "$values" 3>&1 1>&2 2>&3)
                clear
            fi

            if [ $execute = true ]; then
                size=0
                until [[ $size =~ ^[0-9]+$ && $size -gt $(jq -r '.volumes[]|select(.id=='"$selected_volume_id"')|.size' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) ]] || [ -z $size ]; do
                    size=$(dialog --title "Resize volume" --inputbox "Enter the new (larger) volume size in GB:" 8 40 3>&1 1>&2 2>&3 3>&-)
                done

                if [[ -n $size ]]; then
                    resizeVolume "$selected_volume_id" "$size" "/mnt/$(jq -r '.volumes[]|select(.id=='"$selected_volume_id"')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)"
                fi
            fi
            ;;
        6)
            values=""
            NAME=
            for i in $ALL_VOLUME_NAMES; do
                VOLUME=$(jq -r '.volumes[]|select(.name=="'"$i"'")' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)
                if [ "$(jq -r '.protection.delete' <<< \""$VOLUME"\")" = true ]; then
                    NAME="$i(protected)"
                else
                    NAME="$i"
                fi
                values="$values $(jq -r '.id' <<< "$VOLUME" 2>/dev/null) $NAME"
            done
	    if [ -z "$values" ]; then
                dialog --aspect 100 --infobox "There are no existing volumes." 0 0
                sleep 1
            else
                selected_volume_id=$(dialog --title "Change protection:" --menu "Select: " 0 0 0 "$values" 3>&1 1>&2 2>&3)
                clear
            fi

            execute=true
            if [ -z "$selected_volume_id" ]; then
                execute=false
            fi

            if [ $execute = true ]; then
                VOLUME=$(jq -r '.volumes[]|select(.id=='"$selected_volume_id"')' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)

		changeProtection "$selected_volume_id" "$(jq -r '.protection.delete' <<< "$VOLUME")" "$(jq -r '.name' <<< "$VOLUME")"
            fi
            ;;
        7)
            values=""
            for i in $ALL_VOLUME_NAMES; do
                if [ "$(jq -r '.volumes[]|select(.name=="'"$i"'")|.server' <<< "$ALL_VOLUMES_HTTP")" == "null" ]; then
                    values="$values $(jq -r '.volumes[]|select(.name=="'"$i"'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
                fi
            done

            execute=true
             if [ -z "$values" ]; then
                dialog --aspect 100 --infobox "There is no volume that isn't mounted." 0 0
                sleep 0.2
                execute=false
            else
                selected_volume_id=$(dialog --title "Volume delete" --menu "Select: " 0 0 0 "$values" 3>&1 1>&2 2>&3)
                clear
            fi

            if [ $execute = true ]; then
                deleteVolume "$selected_volume_id"
            fi
            ;;
        8)
            size=0
            until [[ $size =~ ^[0-9]+$ && $size -gt 9 ]] || [ -z $size ]; do
                size=$(dialog --title "Volume Setup" --inputbox "Enter the volume size in GB (min 10):" 8 40 3>&1 1>&2 2>&3 3>&-)
            done

            dialog --clear
            if [[ -n $size ]]; then
                NAME=$(dialog --title "Volume Setup" --inputbox "Enter the volume name:" 8 40 3>&1 1>&2 2>&3 3>&-)
                if [[ -n $NAME ]]; then
                    addVolume "$size" "$NAME"
                fi
            fi
            ;;
    esac

    if [[ -z $answer ]]; then
        CLOSE=true
    fi
}

### Message Call
until [[ $CLOSE = true ]]; do
    startup
    openMenu
done
clear

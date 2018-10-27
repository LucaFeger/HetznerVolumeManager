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

    ALL_VOLUME_NAMES=$(echo $ALL_VOLUMES_HTTP | jq -r '.volumes[].name' 2>/dev/null)

    CLOSE=false
}

function createVolume {
    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"size": '$1$', "name": "'"$2"$'", "server": '$SERVER_ID'}' https://api.hetzner.cloud/v1/volumes)

    dialog --aspect 100 --infobox "Creating volume..." 0 0
    sleep 0.5
    HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')
    ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

    if [ "$ERROR_CHECK" = "null" ]; then
        dialog --aspect 100 --infobox "Configuring volume..." 0 0
        sleep 0.5

        LINUX_TEMP=$(jq '.volume.linux_device' <<< "$HTTP_BODY" 2>/dev/null)
        VOLUME_ID=$(jq '.volume.id' <<< "$HTTP_BODY" 2>/dev/null)
        LINUX_DEVICE="${LINUX_TEMP//\"}"
        MOUNT_PATH="/mnt/$2"

        dialog --aspect 100 --infobox "Waiting for the container to create (this may take a few seconds)" 0 0

        SUCCESS=false
        until [[ $SUCCESS = true ]]; do
            temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$VOLUME_ID/actions)"
            status=$(jq -r ".actions[]|select(.command==\"attach_volume\")|.status" <<< $temp_result 2>/dev/null)
            if [ "$status" = "success" ]; then
                SUCCESS=true
            fi
        done

        dialog --aspect 100 --infobox "Removing existing mounts" 0 0
        sleep 0.5
        sudo umount -R "$MOUNT_PATH" &> /dev/null
        dialog --aspect 100 --infobox "Removing old directory" 0 0
        sleep 0.5
        sudo rm -rf "$MOUNT_PATH" &> /dev/null

        dialog --aspect 100 --infobox "mounting to directory" 0 0
        sleep 0.5
        sudo mkfs.ext4 -F "$LINUX_DEVICE" &>/dev/null
        sudo mkdir -p "$MOUNT_PATH" &>/dev/null
        mount -o discard,defaults "$LINUX_DEVICE" "$MOUNT_PATH" &> /dev/null
        dialog --aspect 100 --msgbox "The volume is now mounted to $MOUNT_PATH !" 0 0
    else
        dialog --aspect 100 --aspect 100 --msgbox "An error occured: $ERROR_CHECK" 0 0
    fi
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
    RESULT=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"server": '$SERVER_ID$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/detach)
    HTTP_BODY=$(echo "$RESULT" | sed -e 's/HTTPSTATUS\:.*//g')
    ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

    if [ "$ERROR_CHECK" = "null" ]; then
        dialog --aspect 100 --infobox "Unmounting volume" 0 0
        sleep 0.5

        MOUNT_PATH="/mnt/$2"

        dialog --aspect 100 --infobox "Removing existing mounts" 0 0
        sleep 0.5
        sudo umount -R "$MOUNT_PATH" &> /dev/null
        dialog --aspect 100 --infobox "Removing old directory" 0 0
        sleep 0.5
        sudo rm -rf "$MOUNT_PATH" &> /dev/null
        dialog --aspect 100 --msgbox "The mount at $MOUNT_PATH was deleted!" 0 0

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
        dialog --aspect 100 --msgbox "An error occured: $ERROR_CHECK" 0 0
    fi
}

function mountVolume {
    RESULT=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"server": '$SERVER_ID$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/attach)
    HTTP_BODY=$(echo "$RESULT" | sed -e 's/HTTPSTATUS\:.*//g')
    ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

    if [ "$ERROR_CHECK" = "null" ]; then
        dialog --aspect 100 --infobox "Mounting volume..." 0 0
        sleep 0.5
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

        dialog --aspect 100 --infobox "Remove existing mounts" 0 0
        sleep 0.5
        sudo umount -R "$MOUNT_PATH" # &> /dev/null
        dialog --aspect 100 --infobox "Removing old directory" 0 0
        sleep 0.5
        sudo rm -rf "$MOUNT_PATH" # &> /dev/null

        dialog --aspect 100 --infobox "Mounting to directory" 0 0
        sleep 0.5
        sudo mkdir "$MOUNT_PATH" # &>/dev/null
        mount -o discard,defaults "$LINUX_DEVICE" "$MOUNT_PATH" # &> /dev/null
        dialog --aspect 100 --msgbox "The volume is now mounted to $MOUNT_PATH !" 0 0
    else
        dialog --aspect 100 --msgbox "An error occured: $ERROR_CHECK" 0 0
    fi
}

function resizeVolume {
    RESULT=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"size": '$2$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/resize)
    HTTP_BODY=$(echo "$RESULT" | sed -e 's/HTTPSTATUS\:.*//g')
    ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

    if [ "$ERROR_CHECK" = "null" ]; then
        dialog --aspect 100 --infobox "Resizing volume..." 0 0

        SUCCESS=false
        until [[ $SUCCESS = true ]]; do
            temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1/actions)"
            status=$(jq -r "[.actions[]|select(.command==\"resize_volume\")|.status][-1]" <<< $temp_result 2>/dev/null)
            if [ "$status" = "success" ]; then
                SUCCESS=true
            fi
        done

        MOUNT_POINT=$3
        FILE_SYSTEM=$(lsblk | grep "$MOUNT_POINT" | awk '{print $1;}')
        dialog --aspect 100 --infobox "Resizing local partition..." 0 0
        sleep 0.5
        resize2fs /dev/$FILE_SYSTEM >/dev/null

        dialog --aspect 100 --msgbox "The volume mounted at $MOUNT_POINT has now a size of $2GB" 0 0
    else
        dialog --aspect 100 --msgbox "An error occured: $ERROR_CHECK" 0 0
    fi

}

function changeProtection {
    DELETE=
    if [ "$2" = true ]; then
        DELETE=false
    else
        DELETE=true
    fi

    RESULT=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d '{"delete": '$DELETE$'}' https://api.hetzner.cloud/v1/volumes/$1/actions/change_protection)
    HTTP_BODY=$(echo "$RESULT" | sed -e 's/HTTPSTATUS\:.*//g')
    ERROR_CHECK=$(jq '.error.message' <<< "$HTTP_BODY" 2>/dev/null)

    SUCCESS=false
    until [[ $SUCCESS = true ]]; do
        temp_result="$(curl --silent -H "Authorization: Bearer $API_KEY" https://api.hetzner.cloud/v1/volumes/$1/actions)"
        status=$(jq -r "[.actions[]|select(.command==\"change_protection\")|.status][-1]" <<< $temp_result 2>/dev/null)
        if [ "$status" = "success" ]; then
            SUCCESS=true
        fi
    done

    if [ $DELETE = false ]; then
        dialog --aspect 100 --msgbox "The volume $3 is no longer protected" 0 0
    else
        dialog --aspect 100 --msgbox "The volume $3 is now protected" 0 0
    fi
}

function openMenu {
    ANSWER=$(dialog --title "Choose action" --default-item "1" \
            --menu "Select:" 0 0 0 \
        1 "Create and mount volume" \
        2 "Mount volume" \
        3 "Unmount volume" \
        4 "Delete and unmount volume" \
        5 "Resize volume" \
        6 "Change protection" \
        7 "Delete volume" 3>&1 1>&2 2>&3)
    # clear
    case $ANSWER in
        1)
            # BEGINNING OF SECTION "CREATE AND MOUNT VOLUME"
            SIZE=0

            until [[ $SIZE =~ ^[0-9]+$ && $SIZE -gt 9 ]] || [ -z $SIZE ]; do
                SIZE=$(dialog --title "Volume Setup" --inputbox "Enter the volume size in GB (min 10):" 8 40 3>&1 1>&2 2>&3 3>&-)
            done

            dialog --clear

            if ! [[ -z $SIZE ]]; then
                NAME=$(dialog --title "Volume Setup" --inputbox "Enter the volume name:" 8 40 3>&1 1>&2 2>&3 3>&-)
                if ! [[ -z $NAME ]]; then
                    createVolume "$SIZE" "$NAME"
                fi
            fi
            ;;
        2)
            # BEGINNING OF SECTION "MOUNT VOLUME"

            VALUES=""
            for i in $ALL_VOLUME_NAMES; do
                if [ "$(jq -r '.volumes[]|select(.name=="'$i'")|.server' <<< "$ALL_VOLUMES_HTTP")" == "null" ]; then
                    VALUES="$VALUES $(jq -r '.volumes[]|select(.name=="'$i'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
                fi
            done

            if [ -z $VALUES ]; then
                dialog --aspect 100 --infobox "There is no volume that isn't mounted." 0 0
                sleep 1
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

                if [ "$server_id" != "null" ] && [ "$server_ip" == "$IP" ]; then
                    VALUES="$VALUES $(jq -r '.volumes[]|select(.name=="'$i'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
                fi
            done

            EXECUTE=true
            if [ -z "$VALUES" ]; then
                dialog --aspect 100 --infobox "There are no mounted volumes." 0 0
                EXECUTE=false
                sleep 1
            else
                SELECTED_VOLUME_ID=$(dialog --title "Unmount volume" --menu "Select: " 0 0 0 $VALUES 3>&1 1>&2 2>&3)
                clear
            fi


            if [ $EXECUTE = true ]; then
                if [ $ANSWER == 4 ]; then
                    if [ "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.protection.delete' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" = false ]; then
                        unmountVolume "$SELECTED_VOLUME_ID"  "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" true
                    else
                        dialog --aspect 100 --msgbox "Couldn't delete and unmount the volume, because it's locked. \nPlease use \"Unmount volume\"" 0 0
                    fi
                else
                    unmountVolume "$SELECTED_VOLUME_ID"  "$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)" false
                fi
            fi
            ;;
        5)
            VALUES=""
            for i in $ALL_VOLUME_NAMES; do
                if [ "$(jq -r '.volumes[]|select(.name=="'$i'")|.server' <<< "$ALL_VOLUMES_HTTP")" == "$SERVER_ID" ]; then
                    VALUES="$VALUES $(jq -r '.volumes[]|select(.name=="'$i'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
                fi
            done

            EXECUTE=true
            if [ -z $VALUES ]; then
                dialog --aspect 100 --infobox "There are no mounted volumes." 0 0
                EXECUTE=false
                sleep 1
            else
                SELECTED_VOLUME_ID=$(dialog --title "Resize volume" --menu "Select: " 0 0 0 $VALUES 3>&1 1>&2 2>&3)
                clear
            fi

            if [ $EXECUTE = true ]; then
                SIZE=0
                until [[ $SIZE =~ ^[0-9]+$ && $SIZE -gt $(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.size' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) ]] || [ -z $SIZE ]; do
                    SIZE=$(dialog --title "Resize volume" --inputbox "Enter the new (larger) volume size in GB:" 8 40 3>&1 1>&2 2>&3 3>&-)
                done

                if ! [[ -z $SIZE ]]; then
                    resizeVolume $SELECTED_VOLUME_ID $SIZE "/mnt/$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')|.name' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)"
                fi
            fi
            ;;
        6)
            VALUES=""
            NAME=
            for i in $ALL_VOLUME_NAMES; do
                VOLUME=$(jq -r '.volumes[]|select(.name=="'$i'")' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)
                if [ $(jq -r '.protection.delete' <<< "$VOLUME") = true ]; then
                    NAME="$i(protected)"
                else
                    NAME="$i"
                fi
                VALUES="$VALUES $(jq -r '.id' <<< "$VOLUME" 2>/dev/null) $NAME"
            done

            if [ -z $VALUES ]; then
                dialog --aspect 100 --infobox "There are no existing volumes." 0 0
                sleep 1
            else
                SELECTED_VOLUME_ID=$(dialog --title "Change protection:" --menu "Select: " 0 0 0 $VALUES 3>&1 1>&2 2>&3)
                clear
            fi

            EXECUTE=true
            if [ -z $SELECTED_VOLUME_ID ]; then
                EXECUTE=false
            fi

            if [ $EXECUTE = true ]; then
                VOLUME=$(jq -r '.volumes[]|select(.id=='$SELECTED_VOLUME_ID')' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null)

                changeProtection "$SELECTED_VOLUME_ID" "$(jq -r '.protection.delete' <<< $VOLUME)" "$(jq -r '.name' <<< $VOLUME)"
            fi
            ;;
        7)
            VALUES=""
            for i in $ALL_VOLUME_NAMES; do
                if [ "$(jq -r '.volumes[]|select(.name=="'$i'")|.server' <<< "$ALL_VOLUMES_HTTP")" == "null" ]; then
                    VALUES="$VALUES $(jq -r '.volumes[]|select(.name=="'$i'")|.id' <<< "$ALL_VOLUMES_HTTP" 2>/dev/null) $i"
                fi
            done

            EXECUTE=true
             if [ -z $VALUES ]; then
                dialog --aspect 100 --infobox "There is no volume that isn't mounted." 0 0
                sleep 0.2
                EXECUTE=false
            else
                SELECTED_VOLUME_ID=$(dialog --title "Volume delete" --menu "Select: " 0 0 0 $VALUES 3>&1 1>&2 2>&3)
                clear
            fi

            if [ $EXECUTE = true ]; then
                deleteVolume $SELECTED_VOLUME_ID
            fi
            ;;
    esac

    if [[ -z $ANSWER ]]; then
        CLOSE=true
    fi
}

### Message Call
until [[ $CLOSE = true ]]; do
    startup
    openMenu
done
clear
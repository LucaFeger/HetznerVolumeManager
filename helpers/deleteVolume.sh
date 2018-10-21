#!/bin/bash
command -v curl >/dev/null || { echo "Installing curl..."; sudo apt install -y curl; }
command -v jq >/dev/null || { echo "Installting jq..."; sudo aput install -y jq; }

curl --silent -X DELETE -H "Authorization: Bearer $1" https://api.hetzner.cloud/v1/volumes/$2

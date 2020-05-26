#!/bin/bash

set -e # abort on error
set -u # abort on undefined variable

./scripts/check_prerequisites.sh
source ./scripts/variables.sh

pip3 install --quiet --upgrade git+https://github.com/hpe-container-platform-community/hpecp-client@master

# use the project's HPECP CLI config file
export HPECP_CONFIG_FILE="./generated/hpecp.conf"

echo "Deleting and creating lock"
hpecp lock delete-all
hpecp lock create "Install Gateway"

set -x

EXISTING_GATEWAY_IDS=$(hpecp gateway list --columns "['id']" --output text)
for GW in ${EXISTING_GATEWAY_IDS}; do
   hpecp gateway delete ${GW}
   hpecp gateway wait-for-state ${GW} --states "[]" --timeout-secs 1200
done

echo "Configuring the Gateway"
GATEWAY_ID=$(hpecp gateway create-with-ssh-key $GATW_PRV_IP $GATW_PRV_DNS --ssh-key-file generated/controller.prv_key)

echo "Waiting for gateway to have state 'installed'"
hpecp gateway wait-for-state ${GATEWAY_ID} --states "['installed']" --timeout-secs 1200
hpecp gateway list
hpecp lock delete-all

echo "Configuring AD authentication"
JSON_FILE=$(mktemp)
trap "{ rm -f $JSON_FILE; }" EXIT
cat >$JSON_FILE<<-EOF
{ 
    "external_identity_server":  {
        "bind_pwd":"5ambaPwd@",
        "user_attribute":"sAMAccountName",
        "bind_type":"search_bind",
        "bind_dn":"cn=Administrator,CN=Users,DC=samdom,DC=example,DC=com",
        "host":"${AD_PRV_IP}",
        "security_protocol":"ldaps",
        "base_dn":"CN=Users,DC=samdom,DC=example,DC=com",
        "verify_peer": false,
        "type":"Active Directory",
        "port":636 
    }
}
EOF
hpecp httpclient post /api/v2/config/auth --json-file ${JSON_FILE}

echo "Adding workers"
WRKR_IDS=()
for WRKR in ${WRKR_PRV_IPS[@]}; do
    echo "   worker $WRKR"
    WRKR_IDS+=($(hpecp k8sworker create-with-ssh-key --ip ${WRKR} --ssh-key-file generated/controller.prv_key))
done

# TODO fix: k8sworker wait-for-state
sleep 1200

echo "Setting worker storage"
for WRKR in "${WRKR_IDS[@]}" 
do
    echo "   worker $WRKR"
    hpecp k8sworker set-storage --k8sworker_id ${WRKR} --persistent-disks=/dev/nvme2n1 --ephemeral-disks=/dev/nvme2n2
done


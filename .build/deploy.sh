#!/bin/bash
#
# Deploys the mlab-node Debian package to the autonode-deb test VM. Expects
# the .deb built by the preceding Cloud Build step in dist/ (see
# cloudbuild.yaml).
#
# NOTE: no set -x, deploy-side or remote: the API key would end up in the
# Cloud Build logs.
set -euo pipefail

USAGE="$0 <project> <api-key> <probability>"
PROJECT=${1:?Please provide the GCP project (e.g., mlab-sandbox): ${USAGE}}
API_KEY=${2:?Please provide the API key: ${USAGE}}
PROBABILITY=${3:?Please provide the probability: ${USAGE}}

# The test VM is always in us-central1, which is OMA. Its zone within the
# region follows GCP capacity (set in terraform-support), so look it up.
IATA="oma"
VM_NAME="autonode-deb"
INTERFACE_NAME="ens4"
INTERFACE_MAXRATE="150000000"
UPLINK="7g"
TYPE="virtual"
VM_ZONE=$(gcloud --project "${PROJECT}" compute instances list \
  --filter="name=${VM_NAME}" --format='value(zone.basename())')
[ -n "${VM_ZONE}" ] || { echo "VM ${VM_NAME} not found in ${PROJECT}" >&2; exit 1; }

LOCATE_URL="locate-dot-${PROJECT}.appspot.com"
AUTH_URL="auth.${PROJECT}.measurementlab.net"
if [ "${PROJECT}" = "mlab-autojoin" ]; then
  LOCATE_URL="locate.measurementlab.net"
  AUTH_URL="auth.mlab-oti.measurementlab.net"
fi

DEB_PATH=$(ls dist/mlab-node_*_amd64.deb)
echo "Deploying ${DEB_PATH} to ${VM_NAME} in ${PROJECT} (${VM_ZONE})"

# Copy the package to the VM.
gcloud --project "${PROJECT}" compute scp --zone "${VM_ZONE}" \
  --tunnel-through-iap "${DEB_PATH}" "autonode@${VM_NAME}:~/mlab-node.deb"

# Install the package, write the configuration and (re)start the stack.
# Unescaped variables expand here; escaped (\$) ones expand on the VM.
gcloud --project "${PROJECT}" compute ssh --zone "${VM_ZONE}" \
  --tunnel-through-iap "autonode@${VM_NAME}" <<EOF
    set -euo pipefail

    # Install/upgrade the package. --allow-downgrades because Cloud Build
    # version stamps are unique but not monotonic. Noninteractive: the
    # package asks its configuration through debconf, and without a
    # terminal debconf would otherwise fall back to reading answers from
    # stdin, i.e. from the rest of this script. The defaults it takes are
    # overwritten below.
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --allow-downgrades ~/mlab-node.deb

    # Find the external v4 and v6 addresses for this machine. IPV6 is
    # optional, so do not fail if there is no v6 connectivity.
    IPV4=\$(curl -s ipinfo.io/ip)
    IPV6=\$(curl -s -6 v6.ipinfo.io/ip || true)

    # Write the node configuration. PROJECT/LOCATE_URL/AUTH_URL override the
    # package defaults in /usr/share/mlab-node/static.env, which point at production.
    # NOTE: -upload-schema stays false (the package default): schema uploads
    # are manual and intentional, never part of an automated deployment.
    sudo tee /etc/mlab-node/node.env >/dev/null <<EOC
IATA=${IATA}
PROBABILITY=${PROBABILITY}
INTERFACE_NAME=${INTERFACE_NAME}
UPLINK=${UPLINK}
INTERFACE_MAXRATE=${INTERFACE_MAXRATE}
IPV4=\$IPV4
IPV6=\$IPV6
TYPE=${TYPE}
PROJECT=${PROJECT}
LOCATE_URL=${LOCATE_URL}
AUTH_URL=${AUTH_URL}
EOC

    sudo tee /etc/mlab-node/api-key.env >/dev/null <<EOC
API_KEY=${API_KEY}
EOC
    sudo chown root:root /etc/mlab-node/api-key.env
    sudo chmod 0600 /etc/mlab-node/api-key.env

    # Every service is PartOf= the target, so this cycles the whole stack.
    sudo systemctl daemon-reload
    sudo systemctl restart mlab-node.target
EOF

echo "Deployed to ${VM_NAME} in ${PROJECT}."

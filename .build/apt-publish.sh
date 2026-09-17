#!/bin/bash
#
# Uploads .debs to a project's mlab-node Artifact Registry APT repository.
# Artifact Registry rejects a version that already exists; that is treated as
# success so re-running a failed publish job is harmless.
set -euo pipefail

USAGE="$0 <project> <deb>..."
PROJECT=${1:?Please provide the GCP project (e.g., mlab-sandbox): ${USAGE}}
shift
[ $# -gt 0 ] || { echo "Please provide at least one .deb: ${USAGE}" >&2; exit 1; }

for deb in "$@"; do
  echo "Uploading ${deb} to ${PROJECT}/mlab-node"
  if out=$(gcloud artifacts apt upload mlab-node --project="${PROJECT}" \
      --location=us-central1 --source="${deb}" 2>&1); then
    continue
  fi
  if grep -qi 'already exists' <<<"${out}"; then
    echo "Already present, skipping."
  else
    echo "${out}" >&2
    exit 1
  fi
done

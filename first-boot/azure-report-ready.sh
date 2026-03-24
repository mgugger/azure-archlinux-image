#!/bin/bash
# azure-report-ready.sh — Report VM ready status to Azure wireserver
# This replaces cloud-init's provisioning report when cloud-init is masked
# (e.g. squashfs recovery/provisioning boot).
set -euo pipefail

WIRESERVER="168.63.129.16"
GOAL_STATE_URL="http://${WIRESERVER}/machine/?comp=goalstate"
HEALTH_URL="http://${WIRESERVER}/machine/?comp=health"

log() { echo "[azure-report-ready] $*"; }

# Fetch the current goal state to get the container and instance IDs
goal_state=$(curl -sf -H "x-ms-agent-name: arch-report-ready" \
    -H "x-ms-version: 2012-11-30" \
    --connect-timeout 5 --max-time 10 \
    "${GOAL_STATE_URL}") || { log "Cannot reach wireserver; not on Azure?"; exit 0; }

container_id=$(echo "${goal_state}" | sed -n 's/.*<ContainerId>\(.*\)<\/ContainerId>.*/\1/p' | head -1)
instance_id=$(echo "${goal_state}" | sed -n 's/.*<InstanceId>\(.*\)<\/InstanceId>.*/\1/p' | head -1)

if [[ -z "${container_id}" || -z "${instance_id}" ]]; then
    log "Could not parse ContainerId/InstanceId from goal state"
    exit 1
fi

# Send the health report
health_report="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<Health>
  <GoalStateIncarnation>1</GoalStateIncarnation>
  <Container>
    <ContainerId>${container_id}</ContainerId>
    <RoleInstanceList>
      <Role>
        <InstanceId>${instance_id}</InstanceId>
        <Health>
          <State>Ready</State>
        </Health>
      </Role>
    </RoleInstanceList>
  </Container>
</Health>"

curl -sf -X POST \
    -H "x-ms-agent-name: arch-report-ready" \
    -H "x-ms-version: 2012-11-30" \
    -H "Content-Type: text/xml;charset=utf-8" \
    --connect-timeout 5 --max-time 10 \
    -d "${health_report}" \
    "${HEALTH_URL}" || { log "Failed to post health report"; exit 1; }

log "Reported Ready to Azure (container=${container_id}, instance=${instance_id})"

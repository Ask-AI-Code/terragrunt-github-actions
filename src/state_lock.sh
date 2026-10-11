#!/bin/bash

# Fields of each "Lock Info:" block in Terraform's "Error acquiring the state lock" output, one
# "id|path|operation|created" line per distinct lock. Terragrunt prints the same error more than once.
function parseStateLocks {
  stripColors "${1}" | awk '
    /Lock Info:/ { inLock = 1; id = path = op = created = ""; next }
    !inLock { next }
    match($0, /ID: +[^ ]+/)        { id = substr($0, RSTART, RLENGTH); sub(/ID: +/, "", id) }
    match($0, /Path: +[^ ]+/)      { path = substr($0, RSTART, RLENGTH); sub(/Path: +/, "", path) }
    match($0, /Operation: +[^ ]+/) { op = substr($0, RSTART, RLENGTH); sub(/Operation: +/, "", op) }
    match($0, /Created: +.+/)      { created = substr($0, RSTART, RLENGTH); sub(/Created: +/, "", created) }
    /Info:/ && !/Lock Info:/ {
      inLock = 0
      if (id != "" && !(id in seen)) { seen[id] = 1; print id "|" path "|" op "|" created }
    }
  '
}

function lockAgeText {
  local createdEpoch
  createdEpoch=$(date -u -d "${1:0:19}" +%s 2>/dev/null) || return 0
  local minutes=$(( ($(date -u +%s) - createdEpoch) / 60 ))
  if [ ${minutes} -ge 1440 ]; then
    echo " ($((minutes / 1440))d $((minutes % 1440 / 60))h ago)"
  else
    echo " ($((minutes / 60))h $((minutes % 60))m ago)"
  fi
}

# Explains a lock error without ever unlocking: the engineer decides whether the lock is stale.
function explainStateLockError {
  grep -q "Error acquiring the state lock" <<< "${1}" || return 0
  local id path op created
  while IFS='|' read -r id path op created; do
    [ -z "${id}" ] && continue
    echo "state-lock: ${path} is locked by ${op}, created ${created}$(lockAgeText "${created}"), lock ID ${id}."
    echo "state-lock: Unlock only if no workflow run or local terraform is still using this module."
    echo "state-lock: If the lock is from an apply or destroy, it may have stopped halfway: after unlocking, run a plan and review it before the next apply."
    if [[ "${path}" == gs://* ]]; then
      echo "state-lock: To remove only this lock: gsutil -h x-goog-if-generation-match:${id} rm ${path}"
    else
      echo "state-lock: To remove only this lock: terragrunt force-unlock ${id} (from the module directory)"
    fi
  done <<< "$(parseStateLocks "${1}")"
}

#!/bin/bash

# Terragrunt's built-in auto-retry re-runs the command before any hook or this action can react,
# so after a failed GCS state save it retries against stale state (409s, forked state). Commands
# run through runWithStateRecovery disable it and get the same default retry here, but push
# errored.tfstate first.

# Terragrunt v0.69.0 options.DefaultRetryableErrors, as (substring-regex AND substring-regex) pairs.
retryablePatterns=(
  "Failed to load state|tcp.*timeout"
  "Failed to load backend|TLS handshake timeout"
  "Creating metric alarm failed|request to update this alarm is in progress"
  "Error installing provider|TLS handshake timeout"
  "Error configuring the backend|TLS handshake timeout"
  "Error installing provider|tcp.*timeout"
  "Error installing provider|tcp.*connection reset by peer"
  "NoSuchBucket: The specified bucket does not exist|"
  "Error creating SSM parameter: TooManyUpdates:|"
  "app.terraform.io.*: 429 Too Many Requests|"
  "ssh_exchange_identification|Connection closed by remote host"
  "Client\.Timeout exceeded while awaiting headers|"
  "Could not download module|The requested URL returned error: 429"
  "net/http: TLS.*handshake timeout|"
)
genericRetryMaxAttempts=3
genericRetrySleepSeconds=5
statePushMaxAttempts=5

function isRetryableOutput {
  local output="${1}" pattern first second
  for pattern in "${retryablePatterns[@]}"; do
    first="${pattern%%|*}"
    second="${pattern#*|}"
    if grep -qE -- "${first}" <<< "${output}" && { [ -z "${second}" ] || grep -qE -- "${second}" <<< "${output}"; }; then
      return 0
    fi
  done
  return 1
}

function isStateSaveFailure {
  grep -qE "Failed to (save|persist) state" <<< "${1}"
}

function listErroredStateFiles {
  find . -path '*/.terragrunt-cache/*' -type f -name errored.tfstate -exec sh -c \
    'for f; do echo "$f $(stat -c %Y "$f") $(sha256sum < "$f" | cut -d" " -f1)"; done' _ {} + | sort
}

# Paths of errored.tfstate files that are new or changed compared to the step-start snapshot.
# A snapshot (not `find -newer`) because BusyBox compares whole seconds and would miss fast failures.
function findErroredStateFilesSince {
  comm -13 "${1}" <(listErroredStateFiles) | cut -d' ' -f1
}

function pushErroredState {
  local erroredFile="${1}" dir attempt
  dir=$(dirname "${erroredFile}")
  for ((attempt = 1; attempt <= statePushMaxAttempts; attempt++)); do
    echo "state-recovery: pushing ${erroredFile} (attempt ${attempt}/${statePushMaxAttempts})"
    if (cd "${dir}" && terraform state push errored.tfstate); then
      mv "${erroredFile}" "${erroredFile}.pushed-$(date +%s)"
      echo "state-recovery: pushed ${erroredFile}"
      return 0
    fi
    sleep $((2 ** attempt))
  done
  echo "state-recovery: error: could not push ${erroredFile}; it was rejected or the backend is unreachable. Not retrying the command."
  return 1
}

# Runs the given command, printing the output of every attempt. On failure:
#   1. errored.tfstate written during this step -> push each (plain push, never forced), then re-run once.
#   2. state-save failure without a pushable file -> fail, never re-run blindly.
#   3. Terragrunt's default transient errors -> re-run, same as Terragrunt's built-in retry.
function runWithStateRecovery {
  local stepSnapshot output exitCode attempt erroredFiles erroredFile recovered=0
  stepSnapshot=$(mktemp)
  listErroredStateFiles > "${stepSnapshot}"

  for ((attempt = 1; ; attempt++)); do
    output=$(env TERRAGRUNT_AUTO_RETRY=false TERRAGRUNT_NO_AUTO_RETRY=true "${@}" 2>&1)
    exitCode=${?}
    echo "${output}"
    [ ${exitCode} -eq 0 ] && break

    erroredFiles=$(findErroredStateFilesSince "${stepSnapshot}")
    if [ -n "${erroredFiles}" ]; then
      if [ ${recovered} -eq 1 ]; then
        echo "state-recovery: error: state save failed again after recovery; giving up."
        break
      fi
      while IFS= read -r erroredFile; do
        pushErroredState "${erroredFile}" || break 2
      done <<< "${erroredFiles}"
      recovered=1
      echo "state-recovery: all unsaved state pushed; re-running the command once."
      continue
    fi

    if isStateSaveFailure "${output}"; then
      echo "state-recovery: error: state save failed but no errored.tfstate from this step was found; not re-running."
      break
    fi

    if [ ${attempt} -lt ${genericRetryMaxAttempts} ] && isRetryableOutput "${output}"; then
      echo "state-recovery: transient error; sleeping ${genericRetrySleepSeconds}s before retrying."
      sleep ${genericRetrySleepSeconds}
      continue
    fi
    break
  done

  rm -f "${stepSnapshot}"
  return ${exitCode}
}

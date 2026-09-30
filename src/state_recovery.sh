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
retryablePatterns+=(
  "Build failed with status: INTERNAL_ERROR|"
  "Could not get operation details for operation|"
  "There were concurrent policy changes|"
)
moduleFetchRetryablePatterns=(
  "error downloading 'ssh://git@github\.com/|Permission denied \(publickey\)"
  "error downloading 'ssh://git@github\.com/|ssh: connect to host github\.com"
  "error downloading 'ssh://git@github\.com/|Connection closed by"
  "error downloading 'ssh://git@github\.com/|Could not resolve hostname github\.com"
  "error downloading 'ssh://git@github\.com/|Connection reset by peer"
)
genericRetryMaxAttempts=3
genericRetrySleepSeconds=5
moduleFetchRetrySleepSeconds=30
statePushMaxAttempts=5

function matchesAnyPattern {
  local output="${1}" pattern first second
  shift
  for pattern in "${@}"; do
    first="${pattern%%|*}"
    second="${pattern#*|}"
    if grep -qE -- "${first}" <<< "${output}" && { [ -z "${second}" ] || grep -qE -- "${second}" <<< "${output}"; }; then
      return 0
    fi
  done
  return 1
}

function isModuleFetchFailure {
  matchesAnyPattern "${1}" "${moduleFetchRetryablePatterns[@]}"
}

function isRetryableOutput {
  matchesAnyPattern "${1}" "${retryablePatterns[@]}" || isModuleFetchFailure "${1}"
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
#   3. Terragrunt's default transient errors, plus the module-fetch and GCP ones above -> re-run.
function runWithStateRecovery {
  local stepSnapshot output exitCode attempt erroredFiles erroredFile recovered=0 okExitCode=0 sleepSeconds
  if [ "${1}" == "--ok-exit-code" ]; then
    okExitCode=${2}
    shift 2
  fi
  stepSnapshot=$(mktemp)
  listErroredStateFiles > "${stepSnapshot}"

  for ((attempt = 1; ; attempt++)); do
    # 0.36.5 reads TERRAGRUNT_AUTO_RETRY, 0.69.0 TERRAGRUNT_NO_AUTO_RETRY, 0.91.0 TG_NO_AUTO_RETRY.
    output=$(env TERRAGRUNT_AUTO_RETRY=false TERRAGRUNT_NO_AUTO_RETRY=true TG_NO_AUTO_RETRY=true "${@}" 2>&1)
    exitCode=${?}
    echo "${output}"
    if [ ${exitCode} -eq 0 ] || [ ${exitCode} -eq ${okExitCode} ]; then
      break
    fi

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
      sleepSeconds=${genericRetrySleepSeconds}
      if isModuleFetchFailure "${output}"; then
        sleepSeconds=$((moduleFetchRetrySleepSeconds * attempt))
      fi
      echo "state-recovery: transient error; sleeping ${sleepSeconds}s before retrying."
      sleep ${sleepSeconds}
      continue
    fi
    break
  done

  rm -f "${stepSnapshot}"
  return ${exitCode}
}

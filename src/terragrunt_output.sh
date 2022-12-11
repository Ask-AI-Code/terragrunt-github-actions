#!/bin/bash

function terragruntOutput {
  # Gather the output of `terragrunt output`.
  echo "output: info: gathering all the outputs for the Terragrunt configuration in ${tfWorkingDir}"
  outputOutput=$(${tfBinary} output -json ${*} 2>&1)
  outputExitCode=${?}

  # Exit code of 0 indicates success. Print the output and exit.
  if [ ${outputExitCode} -eq 0 ]; then
    echo "output: info: successfully gathered all the outputs for the Terragrunt configuration in ${tfWorkingDir}"
    echo "${outputOutput}"
    echo

    echo "tf_actions_output<<EOF" >> $GITHUB_OUTPUT
    echo "${outputOutput}" >> $GITHUB_OUTPUT
    echo "EOF" >> $GITHUB_OUTPUT
    exit ${outputExitCode}
  fi

  # Exit code of !0 indicates failure.
  echo "output: error: failed to gather all the outputs for the Terragrunt configuration in ${tfWorkingDir}"
  echo "${outputOutput}"
  echo
  exit ${outputExitCode}
}

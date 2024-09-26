#!/bin/bash

function terragruntInitUpgrade {
  # Gather the output of `terragrunt init -upgrade`.
  echo "init-upgrade: info: initializing Terragrunt configuration in ${tfWorkingDir} with -upgrade"
  initOutput=$(${tfBinary} init -input=false -upgrade ${*} 2>&1)
  initExitCode=${?}

  # Exit code of 0 indicates success. Print the output and exit.
  if [ ${initExitCode} -eq 0 ]; then
    echo "init-upgrade: info: successfully initialized Terragrunt configuration in ${tfWorkingDir} with -upgrade"
    echo "${initOutput}"
    echo
    exit ${initExitCode}
  fi

  # Exit code of !0 indicates failure.
  echo "init-upgrade: error: failed to initialize Terragrunt configuration in ${tfWorkingDir} with -upgrade"
  echo "${initOutput}"
  echo

  # Comment on the pull request if necessary.
  if [ "$GITHUB_EVENT_NAME" == "pull_request" ] && [ "${tfComment}" == "1" ]; then
    initCommentWrapper="#### \`${tfBinary} init -upgrade\` Failed

\`\`\`
${initOutput}
\`\`\`

*Workflow: \`${GITHUB_WORKFLOW}\`, Action: \`${GITHUB_ACTION}\`, Working Directory: \`${tfWorkingDir}\`, Workspace: \`${tfWorkspace}\`*"

    initCommentWrapper=$(stripColors "${initCommentWrapper}")
    echo "init-upgrade: info: creating JSON"
    initPayload=$(echo "${initCommentWrapper}" | jq -R --slurp '{body: .}')
    initCommentsURL=$(cat ${GITHUB_EVENT_PATH} | jq -r .pull_request.comments_url)
    echo "init-upgrade: info: commenting on the pull request"
    echo "${initPayload}" | curl -s -S -H "Authorization: token ${GITHUB_TOKEN}" --header "Content-Type: application/json" --data @- "${initCommentsURL}" > /dev/null
  fi

  exit ${initExitCode}
}

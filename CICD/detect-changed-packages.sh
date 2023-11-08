#!/usr/bin/env bash

##########################################################
# detect-changed-packages.sh
#
# This script is based on https://github.com/labs42io/circleci-monorepo/blob/master/.circleci/circle_trigger.sh
# and uses an adapted version of  https://gist.github.com/joechrysler/6073741a
#
# I was given permission to keep this redacted version of the script by one of my previous employers in order to
# share some of the professional scripts I have worked on.
# The following was used in a monolithic repo connected to a CircleCI pipeline.
# The purpose is to check for changes in routes, functions, terraform, and libraries
# With this it allows us to run UNIT and Integraiton tests against only the packages with actual changes
# rather than running against all of them.
# 
##################################################################################################

set -e

# The root directory of packages.
WORKSPACES=$(jq '.workspaces' ~/REDACTED/package.json)
TFCONFIGS=$(ls -d ./REDACTED/infrastructure/terraform/configurations/)


for i in "${WORKSPACES[*]}"; do
  i=$(echo "$i" |tr -d []| tr -d '""'|tr -d ' '| tr -d ','|tr -d '*'|sed '/^[[:space:]]*$/d'|sed -e 's#^#./#')
  ROOT+="$i"$'\n'
done
for p in "${TFCONFIGS[*]}"; do
  p=$(echo "$p"| tr -d '""' | sed '/^[[:space:]]*$/d')
  ROOT+="$p "
done

echo -e "$ROOT"

# The main branch.
MAIN_BRANCH="master"
REPOSITORY_TYPE="github"
CIRCLE_API="https://circleci.com/api"

# Pull out a token based on user name
# This however will fail if a user name contains special chars like `-`, '.' etc.
# We manage personal tokens in a context in circleci called CIRCLE_TOKENS
# To grant a user access, have them generate an api token with their user name and
# then add an context to CIRCLE_TOKENS of the following format:
# CIRCLE_TOKEN_yourusername
TOKEN_NAME=CIRCLE_TOKEN_${CIRCLE_USERNAME} 
CIRCLE_TOKEN=${!TOKEN_NAME}

############################################
# 1. Identify commit SHA of last CI build
#
# * Pulls the last completed build of the current branch from CI,
# * Builds a tree of the branch hierarchy on origin,
# * Find a matching branch on origin,
# * Check CI for the commit SHA of that build for step 2.
# 
############################################
LAST_COMPLETED_BUILD_URL="${CIRCLE_API}/v1.1/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/tree/${CIRCLE_BRANCH}?filter=completed&limit=100&shallow=true"

# Get the commit SHA of the last build where all workflows succeeded
# 
# Specifically, the jq breaks down as:
# 1. filter out all main-ci workflows
# 2. group them by commit SHA
# 3. filter out all builds where at least one workflow failed
# 4. sort by queued_at latest-first
# 5. take the commit SHA of the first workflow in the first build
LAST_COMPLETED_BUILD_SHA=$(curl -Ss -u "${CIRCLE_TOKEN}:" "${LAST_COMPLETED_BUILD_URL}" | jq -r 'map(select(.workflows.workflow_name != "main-ci")) | group_by(.vcs_revision) | map(select(all(.status == "success"))) | sort_by(.[0]["queued_at"]) | reverse | .[0][0]["vcs_revision"]')

echo -e "LAST COMPLETED BUILD URL: [${LAST_COMPLETED_BUILD_URL}] ..."
echo -e "LAST COMPLETED BUILD SHA: [${LAST_COMPLETED_BUILD_SHA}] ..."

# Check the git log to see if the commit SHA of the last completed build is still on the branch.
# If there has been a rebase, the commit log will have been rebuilt and the SHA will not be found.
# Following a rebase, we would want to trigger a full build.
if ! git log | grep -q "${LAST_COMPLETED_BUILD_SHA}";
then
  echo "The commit SHA of the last completed build is not on the branch (likely due to a rebase). Triggering a full build."
  LAST_COMPLETED_BUILD_SHA="null"
fi

# If there is no successful previous build on this branch, iterate through parent branches
if [[ ${LAST_COMPLETED_BUILD_SHA} == "null" ]]; then
  echo -e "There are no completed CI builds in branch ${CIRCLE_BRANCH}."
  
  # Adapted from https://gist.github.com/joechrysler/6073741a
  # Builds a reverse tree of all destination branches
  TREE=$(git show-branch -a \
    | grep '\*' \
    | grep -v $(git rev-parse --abbrev-ref HEAD) \
    | sed 's/.*\[\(.*\)\].*/\1/' \
    | sed 's/[\^~].*//' \
    | uniq)

  REMOTE_BRANCHES=$(git branch -r | sed 's/\s*origin\///' | tr '\n' ' ')
  PARENT_BRANCH=$MAIN_BRANCH
  for BRANCH in ${TREE[@]}
  do
    BRANCH=${BRANCH#"origin/"}
    # Search through the tree of parent branches on the origin until finding a matching branch.
    if [[ " ${REMOTE_BRANCHES[@]} " == *" ${BRANCH} "* ]]; then
        # HEAD is an alias for the "$MAIN_BRANCH", so make the substitution.
        if [[ "$BRANCH" == 'HEAD' ]]; then
          echo "Branch is 'HEAD', setting to '${MAIN_BRANCH}'"
          BRANCH=$MAIN_BRANCH
        fi
        echo "Found the parent branch: ${CIRCLE_BRANCH}..${BRANCH}"
        PARENT_BRANCH=$BRANCH
        break
    fi
  done

  # Attempt to find a build in CI based on the PARENT_BRANCH.
  echo "Searching for CI builds in branch '${PARENT_BRANCH}' ..."
  LAST_COMPLETED_BUILD_URL="${CIRCLE_API}/v1.1/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/tree/${PARENT_BRANCH}?filter=failed&limit=100&shallow=true"
  LAST_COMPLETED_BUILD_SHA=$(curl -Ss -u "${CIRCLE_TOKEN}:" "${LAST_COMPLETED_BUILD_URL}" \
    | jq -r "map(\
      select(.status == \"success\") | select(.workflows.workflow_name != \"ci\") | select(.build_num < ${CIRCLE_BUILD_NUM})) \
    | .[0][\"vcs_revision\"]")
fi

# If there is no successful builds on any of the parent branches, compare against MAIN_BRANCH.
if [[ ${LAST_COMPLETED_BUILD_SHA} == "null" ]]; then
  echo -e "No CI builds for branch ${PARENT_BRANCH}. Using ${MAIN_BRANCH}."
  LAST_COMPLETED_BUILD_URL="${CIRCLE_API}/v1.1/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/tree/${MAIN_BRANCH}?filter=completed&limit=100&shallow=true"
  LAST_COMPLETED_BUILD_SHA=$(curl -Ss -u "${CIRCLE_TOKEN}:" "${LAST_COMPLETED_BUILD_URL}" \
    | jq -r "map(\
      select(.status == \"success\") | select(.workflows.workflow_name != \"ci\") | select(.build_num < ${CIRCLE_BUILD_NUM})) \
    | .[0][\"vcs_revision\"]")
fi

##################################################################
# 2. Changed packages
# 
# Uses `find` to detect all packages within $ROOT,
# then compares this with the files in the last completed build
# and flags any packages that have changed.
#
# This list is used to tell CI which workflows to run.
#
##################################################################

# Find all packages in $ROOT. A package is any folder with a package.json file that is not in a node_modules folder
PACKAGES=$(find $ROOT -type f \( -name 'package.json' -o -name '*.tfvars' \) ! -path '*/node_modules/*' | sed 's:[^/]*$::' | sed -e 's./$..g' | sed 's/^..//')
echo "Searching for changes since commit [${LAST_COMPLETED_BUILD_SHA:0:7}] ..."

# The CircleCI API parameters JSON object
PARAMETERS='"trigger":false'
COUNT=0
for PACKAGE in ${PACKAGES[@]}
do
  
  # This will only happen on first build. In this case, run all packages through CI.
  if [[ ${LAST_COMPLETED_BUILD_SHA} == "null" ]]; then
    PACKAGE_NAME=$(echo "$PACKAGE" | sed -e 's/.*\///')
    PARAMETERS+=", \"$PACKAGE_NAME\":true"
    COUNT=$((COUNT + 1))
    echo -e "\e[34m  [+] ${PACKAGE_NAME} \e[21m (first build)"
  else
    # Use git log to diff changes between the current build and the last build on the given path
    LATEST_COMMIT_SINCE_LAST_BUILD=$(git log -1 "$CIRCLE_SHA1" ^"$LAST_COMPLETED_BUILD_SHA" --format=format:%H --full-diff "${PACKAGE#/}")

    echo -e "Latest commit [$LATEST_COMMIT_SINCE_LAST_BUILD]"

    if [[ -z "$LATEST_COMMIT_SINCE_LAST_BUILD" ]]; then
      
      # Always run if the last successful build was on the MAIN_BRANCH.
      if [[ "$LAST_COMPLETED_BUILD_SHA" == "$MAIN_BRANCH" ]]; then
        echo -e "\e[36m  first build for [-] $PACKAGE "
        PACKAGE_NAME=$(echo "$PACKAGE" | sed -e 's/.*\///')
        PARAMETERS+=", \"$PACKAGE_NAME\":true"
        COUNT=$((COUNT + 1))
      else
        echo -e "\e[90m  [-] $PACKAGE"
      fi
    else

      # If anything has diverged since the last build, it needs to be run through CI again.
      # Add the package name to the parameters object.
      PACKAGE_NAME=$(echo "$PACKAGE" | sed -e 's/.*\///')
      PARAMETERS+=", \"$PACKAGE_NAME\":true"
      COUNT=$((COUNT + 1))
      echo -e "\e[36m  [+] ${PACKAGE_NAME} \e[21m (changed in [${LATEST_COMMIT_SINCE_LAST_BUILD:0:7}])"
      
      # Check that there is actually a workflow to match the the package name.
      if [[ $(find /home/circleci/REDACTED/.circleci/src/workflows/ -name "${PACKAGE_NAME}*.yml" | wc -l) -gt 0 ]]; then 
        echo -e "\e[32m      ${PACKAGE_NAME} has a valid workflow."
        # Check if package is a library
        if [ "library/${PACKAGE_NAME}" == "${PACKAGE}" ]; then
          #Find all packages dependent on the library and change their parameters to true.
          AFFECTED=$(grep --include="\package.json" -rw './appengine-routes' './cloud-functions' './library' './tooling' -e "@REDACTED-${PACKAGE}" | awk '{print $1}' | cut -d '/' -f 2,3)
          for AFFECTED_PACKAGE in ${AFFECTED[@]}
          do
            AFFECTED_PACKAGE_WORKFLOW_NAME=$(echo "${AFFECTED_PACKAGE}"| cut -d '/' -f 2)
            #make sure that the package is not "package.json"
            if [ "${AFFECTED_PACKAGE_WORKFLOW_NAME}" != "package.json:" ]; then
              # Check if there is a work flow for the affected package
              if [[ $(find /home/circleci/microservices/.circleci/src/workflows/ -name "${AFFECTED_PACKAGE_WORKFLOW_NAME}*.yml" | wc -l) -gt 0 ]]; then 
                PARAMETERS+=", \"$AFFECTED_PACKAGE\":true"
                echo -e "\e[36m      [+] [+] ${AFFECTED_PACKAGE} \e[21m (references changed library $PACKAGE_NAME)"
              else
                echo -e "\e[31m      Failure: Workflow for ${AFFECTED_PACKAGE} does not exist. Please refer to REDACTED on how to create a workflow."
                exit 1             
              fi
            fi
          done
        fi
      else
        echo -e "\e[31m      Failure: Workflow for ${PACKAGE_NAME} does not exist. Please refer to REDACTED on how to create a workflow."
        exit 1
      fi
    fi
  fi
done

if [[ $COUNT -eq 0 ]]; then
  echo -e "No changes detected in packages. Skip triggering workflows."
  exit 0
fi

echo "Changes detected in ${COUNT} package(s)."
############################################
# 3. CircleCI REST API call
############################################
DATA="{ \"branch\": \"$CIRCLE_BRANCH\", \"parameters\": { $PARAMETERS } }"
echo "Triggering pipeline with data:"
echo -e "  $DATA"

URL="${CIRCLE_API}/v2/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline"
HTTP_RESPONSE=$(curl -s -u "${CIRCLE_TOKEN}": -o response.txt -w "%{http_code}" -X POST --header "Content-Type: application/json" -d "$DATA" "$URL")

if [ "$HTTP_RESPONSE" -ge "200" ] && [ "$HTTP_RESPONSE" -lt "300" ]; then
    echo "API call succeeded."
    echo "Response:"
    cat response.txt
else
    echo -e "Received status code: ${HTTP_RESPONSE}"
    echo "Response:"
    cat response.txt
    exit 1
fi

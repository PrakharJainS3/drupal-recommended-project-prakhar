#!/bin/bash
set -e
# This is a script to deploy NodeJs artifact
# Note: This script doesn't handle the token expiry or any API exceptions/errors.

# A function to end script unsuccessfuly
err() {
  echo "Failed to deploy the artifact, check task log for more details at $PIPELINE_JOB_URL"
  exit 1
}

if [[ -z "${TARGET_ENV_NAME}" ]]
then
  echo "Target environment name is not defined, make sure that TARGET_ENV_NAME environment variable is set"
  err
fi

if [[ -z "${PIPELINE_ARTIFACT_START_LOG}" ]]
then
  echo "Pipeline artifact start log is not defined, make sure that PIPELINE_ARTIFACT_START_LOG environment variable is set"
  err
fi

# Get Cloud Authentication token. For more details: https://docs.acquia.com/acquia-cloud/develop/api/auth/
max_retries=3
attempt=1
delay=5
TOKEN=""

while [ $attempt -le $max_retries ]; do
  echo "Attempt $attempt: Contacting endpoint for token generation:"
  response=$(curl -sS -w "\n%{http_code}" -X POST -u "${CLOUD_API_KEY}:${CLOUD_API_SECRET}" -d "grant_type=client_credentials" https://accounts.acquia.com/api/auth/oauth/token)
  
  http_code=$(echo "$response" | tail -n1)
  echo "HTTP code: $http_code"

  response_body=$(echo "$response" | sed '$d')

  if [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
    echo "Retrieving token:"
    TOKEN=$(echo "$response_body" | python3 -c "import sys, json; print(json.load(sys.stdin)['access_token'])")
    echo "Token retrieved from response"
    break
  else
    echo "Request failed with HTTP $http_code. Response body: $response_body"
    echo "Retrying in $delay seconds..."
    sleep $delay
    ((attempt++))
  fi
done

if [[ -z "$TOKEN" ]]; then
  echo "Failed to obtain token after $attempt attempts."
  exit 1
fi

# Get target environment Id.
attempt=1
TARGET_ENV_ID=""

while [ $attempt -le $max_retries ]; do
  echo "Attempt $attempt: Contacting endpoint for TARGET_ENV_ID:"
  response=$(curl -sS -w "\n%{http_code}" -X GET "https://cloud.acquia.com/api/applications/$PIPELINE_APPLICATION_ID/environments" -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}")

  http_code=$(echo "$response" | tail -n1)
  echo "HTTP code: $http_code"

  response_body=$(echo "$response" | sed '$d')

  if [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
    echo "Retrieving TARGET_ENV_ID:"
    TARGET_ENV_ID=$(echo "$response_body" | python3 -c "import sys, json; envs=json.load(sys.stdin)['_embedded']['items']; print([x for x in envs if x['name'] == '$TARGET_ENV_NAME'][0]['id'])")
    echo "TARGET_ENV_ID is $TARGET_ENV_ID"
    break
  else
    echo "Request failed with HTTP $http_code. Response body: $response_body"
    echo "Retrying in $delay seconds..."
    sleep $delay
    ((attempt++))
  fi
done

if [[ -z "$TARGET_ENV_ID" ]]; then
  echo "Failed to obtain TARGET_ENV_ID after $attempt attempts."
  exit 1
fi

# Get artifact id from pipeline-artifact start log.
ARTIFACT_ID=$(grep artifactId $PIPELINE_ARTIFACT_START_LOG | cut -d ' ' -f3)
echo ARTIFACT_ID is $ARTIFACT_ID

# Put artifact id into pipeline metadata, so you can get it later if necessary.
pipelines_metadata artifact_id $ARTIFACT_ID

# Deploy artifact to target envronment. Use the notification url returned to get the tasks's status.
# For more details: http://cloudapi-docs.acquia.com/#/Environments/postDeployArtifact
attempt=1
NOTIFICATION_LINK=""

while [ $attempt -le $max_retries ]; do
  echo "Attempt $attempt: Contacting endpoint for NOTIFICATION_LINK:"
  response=$(curl -sS -w "\n%{http_code}" -X POST -d "{\"artifact_id\":\"$ARTIFACT_ID\"}" "https://cloud.acquia.com/api/environments/$TARGET_ENV_ID/artifacts/actions/switch" -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}")

  http_code=$(echo "$response" | tail -n1)
  echo "HTTP code: $http_code"

  response_body=$(echo "$response" | sed '$d')

  if [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
    echo "Retrieving NOTIFICATION_LINK:"
    NOTIFICATION_LINK=$(echo "$response_body" | python3 -c "import sys, json; print(json.load(sys.stdin)['_links']['notification']['href'])")
    echo "NOTIFICATION_LINK is $NOTIFICATION_LINK"
    break
  else
    echo "Request failed with HTTP $http_code. Response body: $response_body"
    echo "Retrying in $delay seconds..."
    sleep $delay
    ((attempt++))
  fi
done

if [[ -z "$NOTIFICATION_LINK" ]]; then
  echo "Failed to obtain NOTIFICATION_LINK after $max_retries attempts."
  exit 1
fi

# Poll NOTIFICATION_LINK to know the task status, the status will be 'in-progress' until the task is finished. For more details: https://cloudapi-docs.acquia.com/#/Notifications/getNotificationByUuid
#DEPLOY_STATUS='in-progress'
attempt=1
DEPLOY_STATUS=""

while [ $attempt -le $max_retries ]; do
  echo "Attempt $attempt: Checking deployment status from NOTIFICATION_LINK:"
  response=$(curl -sS -w "\n%{http_code}" -X GET "$NOTIFICATION_LINK" -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}")
  
  http_code=$(echo "$response" | tail -n1)
  response_body=$(echo "$response" | sed '$d')

  if [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
    DEPLOY_STATUS=$(echo "$response_body" | python3 -c "import sys, json; print(json.load(sys.stdin)['status'])")
    echo "Current deployment status: $DEPLOY_STATUS"
    
    # Exit the loop if the deployment status is fetched successfully
    break
  else
    echo "Request failed with HTTP $http_code. Response body: $response_body"
    echo "Retrying in $delay seconds..."
    sleep $delay
    ((attempt++))
  fi
done

if [[ -z "$DEPLOY_STATUS" ]]; then
  echo "Failed to retrieve DEPLOY_STATUS after $max_retries attempts."
  exit 1
fi

echo "Waiting for the deployment to be finished, current status: $DEPLOY_STATUS."

# Tracking deployment status

while [ "$DEPLOY_STATUS" = 'in-progress' ]; do
  sleep 60
  echo "Tracking DEPLOY_STATUS ..."
  attempt=1
  TOKEN=""
  while [ $attempt -le $max_retries ]; do
    echo "Attempt $attempt: Contacting endpoint for token re-generation:"
    response=$(curl -sS -w "\n%{http_code}" -X POST -u "${CLOUD_API_KEY}:${CLOUD_API_SECRET}" -d "grant_type=client_credentials" https://accounts.acquia.com/api/auth/oauth/token)
    
    http_code=$(echo "$response" | tail -n1)
    echo "HTTP code: $http_code"

    response_body=$(echo "$response" | sed '$d')

    if [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
      echo "Retrieving token:"
      TOKEN=$(echo "$response_body" | python3 -c "import sys, json; print(json.load(sys.stdin)['access_token'])")
      echo "Token retrieved from response"
      echo "New TOKEN generated";
      break
    else
      echo "Request failed with HTTP $http_code. Response body: $response_body"
      echo "Retrying in $delay seconds..."
      sleep $delay
      ((attempt++))
    fi
  done

  if [[ -z "$TOKEN" ]]; then
    echo "Failed to obtain token after $attempt attempts."
    exit 1
  fi

  # Poll NOTIFICATION_LINK to know the task status
  attempt=1
  DEPLOY_STATUS=""

  while [ $attempt -le $max_retries ]; do
    echo "Attempt $attempt: Checking deployment status from NOTIFICATION_LINK:"
    response=$(curl -sS -w "\n%{http_code}" -X GET "$NOTIFICATION_LINK" -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}")
    
    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    if [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
      DEPLOY_STATUS=$(echo "$response_body" | python3 -c "import sys, json; print(json.load(sys.stdin)['status'])")
      echo "Current deployment status: $DEPLOY_STATUS"
      
      # Exit the loop if the deployment status is fetched successfully
      break
    else
      echo "Request failed with HTTP $http_code. Response body: $response_body"
      echo "Retrying in $delay seconds..."
      sleep $delay
      ((attempt++))
    fi
  done

  if [[ -z "$DEPLOY_STATUS" ]]; then
    echo "Failed to retrieve DEPLOY_STATUS after $max_retries attempts."
    exit 1
  fi

  echo "Waiting for the deployment to be finished, current status: $DEPLOY_STATUS."
done

echo $DEPLOY_STATUS

# Exit with 1 if the final status is 'failed'. Do nothing if the final status is 'completed' which mean the deployment is successful.
if [ "$DEPLOY_STATUS" = 'failed' ]
then
  err
fi

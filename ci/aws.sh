#!/bin/bash

#
# Test osbuild-composer 'upload to aws' functionality. To do so, create and
# push a blueprint with composer cli. Then, create an instance in aws
# from the uploaded image. Finally, verify that the instance is running and
# cloud init ran.
#

set -euo pipefail

source ci/set-env-variables.sh
source ci/shared_lib.sh


# Container image used for cloud provider CLI tools
CONTAINER_IMAGE_CLOUD_TOOLS="quay.io/osbuild/cloud-tools:latest"

# Provision the software under test.
ci/provision.sh none

# Check available container runtime
if which podman 2>/dev/null >&2; then
    CONTAINER_RUNTIME=podman
elif which docker 2>/dev/null >&2; then
    CONTAINER_RUNTIME=docker
else
    echo No container runtime found, install podman or docker.
    exit 2
fi

TEMPDIR=$(mktemp -d)
function cleanup() {
    greenprint "== Script execution stopped or finished - Cleaning up =="
    sudo rm -rf "$TEMPDIR"
}
trap cleanup EXIT

# Generate a string, which can be used as a predictable resource name,
# especially when running the test in CI where we may need to clean up
# resources in case the test unexpectedly fails or is canceled
CI="${CI:-false}"
if [[ "$CI" == true ]]; then
  # in CI, imitate GenerateCIArtifactName() from internal/test/helpers.go
  TEST_ID="$DISTRO_CODE-$ARCH-$CI_COMMIT_BRANCH-$CI_JOB_ID"
else
  # if not running in Jenkins, generate ID not relying on specific env variables
  TEST_ID=$(uuidgen);
fi

ARTIFACTS="${ARTIFACTS:-/tmp/artifacts}"

# Set up temporary files.
AWS_CONFIG=${TEMPDIR}/aws.toml
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
COMPOSE_START=${TEMPDIR}/compose-start-${TEST_ID}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${TEST_ID}.json
AMI_DATA=${TEMPDIR}/ami-data-${TEST_ID}.json

# We need awscli to talk to AWS.
if ! hash aws; then
    echo "Using 'awscli' from a container"
    sudo "${CONTAINER_RUNTIME}" pull ${CONTAINER_IMAGE_CLOUD_TOOLS}

    AWS_CMD="sudo ${CONTAINER_RUNTIME} run --rm \
        -e AWS_ACCESS_KEY_ID=${V2_AWS_ACCESS_KEY_ID} \
        -e AWS_SECRET_ACCESS_KEY=${V2_AWS_SECRET_ACCESS_KEY} \
        -v ${TEMPDIR}:${TEMPDIR}:Z \
        ${CONTAINER_IMAGE_CLOUD_TOOLS} aws --region $AWS_REGION --output json --color on"
else
    echo "Using pre-installed 'aws' from the system"
    AWS_CMD="aws --region $AWS_REGION --output json --color on"
fi
$AWS_CMD --version

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=${ARTIFACTS}/osbuild-${ID}-${VERSION_ID}-aws.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=${ARTIFACTS}/osbuild-${ID}-${VERSION_ID}-aws.json

    # Download the metadata.
    sudo composer-cli compose metadata "$COMPOSE_ID" > /dev/null

    # Find the tarball and extract it.
    TARBALL=$(basename "$(find . -maxdepth 1 -type f -name "*-metadata.tar")")
    sudo tar -xf "$TARBALL"
    sudo rm -f "$TARBALL"

    # Move the JSON file into place.
    sudo cat "${COMPOSE_ID}".json | jq -M '.' | tee "$METADATA_FILE" > /dev/null
}

# Write an AWS TOML file
tee "$AWS_CONFIG" > /dev/null << EOF
provider = "aws"

[settings]
accessKeyID = "${V2_AWS_ACCESS_KEY_ID}"
secretAccessKey = "${V2_AWS_SECRET_ACCESS_KEY}"
bucket = "${AWS_BUCKET}"
region = "${AWS_REGION}"
key = "${TEST_ID}"
EOF

# Write a basic blueprint for our image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "bash"
description = "A base system"
version = "0.0.1"
EOF

# Append any packages that we want to install
if ! [ -z "$CLOUDX_PKG_TESTING" ]; then
    if ! [ -z "$CUSTOM_PACKAGES" ]; then
        # shellcheck disable=SC2068
        for pkg in ${CUSTOM_PACKAGES[@]}; do
            pkg_name="${pkg%:*}"
            pkg_version="${pkg##*:}"

            if [[ "$pkg_version" == "$pkg_name" ]]; then
                pkg_version='*'
            fi

            echo "[[packages]]
    name = \"$pkg_name\"
    version = \"$pkg_version\"

    " >> "$BLUEPRINT_FILE"
        done
    fi
fi

# Prepare the blueprint for the compose.
greenprint "📋 Preparing blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve bash

# Get worker unit file so we can watch the journal.
WORKER_UNIT=$(sudo systemctl list-units | grep -o -E "osbuild.*worker.*\.service")
sudo journalctl -af -n 1 -u "${WORKER_UNIT}" &
WORKER_JOURNAL_PID=$!
# Stop watching the worker journal when exiting.
trap 'sudo pkill -P ${WORKER_JOURNAL_PID}' EXIT

# Start the compose and upload to AWS.
greenprint "🚀 Starting compose"
sudo composer-cli --json compose start bash ami "$TEST_ID" "$AWS_CONFIG" | tee "$COMPOSE_START"
COMPOSE_ID=$(get_build_info ".build_id" "$COMPOSE_START")

# Wait for the compose to finish.
greenprint "⏱ Waiting for compose to finish: ${COMPOSE_ID}"
while true; do
    sudo composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null
    COMPOSE_STATUS=$(get_build_info ".queue_status" "$COMPOSE_INFO")

    # Is the compose finished?
    if [[ $COMPOSE_STATUS != RUNNING ]] && [[ $COMPOSE_STATUS != WAITING ]]; then
        break
    fi

    # Wait 30 seconds and try again.
    sleep 30
done

# Capture the compose logs from osbuild.
greenprint "💬 Getting compose log and metadata"
get_compose_log "$COMPOSE_ID"
get_compose_metadata "$COMPOSE_ID"

# Kill the journal monitor immediately and remove the trap
sudo pkill -P ${WORKER_JOURNAL_PID}
trap - EXIT

# Did the compose finish with success?
if [[ $COMPOSE_STATUS != FINISHED ]]; then
    redprint "Something went wrong with the compose. 😢"
    exit 1
fi

# Find the image that we made in AWS.
greenprint "🔍 Search for created AMI"
$AWS_CMD ec2 describe-images \
    --owners self \
    --filters Name=name,Values="${TEST_ID}" \
    | tee "$AMI_DATA" > /dev/null

AMI_IMAGE_ID=$(jq -r '.Images[].ImageId' "$AMI_DATA")
SNAPSHOT_ID=$(jq -r '.Images[].BlockDeviceMappings[].Ebs.SnapshotId' "$AMI_DATA")

# Share the created AMI with the CloudX account
$AWS_CMD ec2 modify-image-attribute \
    --image-id "${AMI_IMAGE_ID}" \
    --launch-permission "Add=[{UserId=${CLOUDX_AWS_ACCOUNT_ID}}]"

# Tag image and snapshot with "gitlab-ci-test" tag
$AWS_CMD ec2 create-tags \
    --resources "${SNAPSHOT_ID}" "${AMI_IMAGE_ID}" \
    --tags Key=gitlab-ci-test,Value=true

# Verify that the image has the correct boot mode set
AMI_BOOT_MODE=$(jq -r '.Images[].BootMode // empty' "$AMI_DATA")
if nvrGreaterOrEqual "osbuild-composer" "83"; then
    case "$ARCH" in
        aarch64)
            # aarch64 image supports only uefi boot mode
            if [[ "$AMI_BOOT_MODE" != "uefi" ]]; then
                redprint "AMI boot mode is not \"uefi\", but \"$AMI_BOOT_MODE\""
                exit 1
            fi
            ;;
        x86_64)
            # x86_64 image supports hybrid boot mode with preference for uefi
            if [[ "$AMI_BOOT_MODE" != "uefi-preferred" ]]; then
                redprint "AMI boot mode is not \"uefi-preferred\", but \"$AMI_BOOT_MODE\""
                exit 1
            fi
            ;;
        *)
            redprint "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
fi

if [[ "$ID" == "fedora" ]]; then
  # fedora uses fedora
  SSH_USER="fedora"
else
  # RHEL and centos use ec2-user
  SSH_USER="ec2-user"
fi

greenprint "Pulling cloud-image-val container"

if [[ "$CI_PROJECT_NAME" =~ "cloud-image-val" ]]; then
  # If running on CIV, get dev container
  TAG=${CI_COMMIT_REF_SLUG}
else
  # If not, get prod container
  TAG="prod"
fi

CONTAINER_CLOUD_IMAGE_VAL="quay.io/cloudexperience/cloud-image-val:$TAG"

sudo "${CONTAINER_RUNTIME}" pull "${CONTAINER_CLOUD_IMAGE_VAL}"

greenprint "Running cloud-image-val on generated image"

# Default instance type for x86_64
instance_type="t3.medium"
if [ "$ARCH" == "aarch64" ]; then
    instance_type="m6g.large"
fi

tee "${TEMPDIR}/resource-file.json" <<EOF
{
    "provider": "aws",
    "instances": [
        {
            "ami": "$AMI_IMAGE_ID",
            "region": "us-east-1",
            "instance_type": "$instance_type",
            "username": "$SSH_USER",
            "name": "civ-pkg-testing-image",
            "custom_vpc_name": "$CLOUDX_AWS_INTERNAL_VPC_NAME",
            "custom_subnet_name": "$CLOUDX_AWS_INTERNAL_SUBNET_NAME",
            "custom_security_group_name": "$CLOUDX_AWS_INTERNAL_SECURITY_GROUP_NAME"
        }
    ]
}
EOF

if [ -z "$CIV_CONFIG_FILE" ]; then
    redprint "ERROR: please provide the variable CIV_CONFIG_FILE"
    exit 1
fi

cp "${CIV_CONFIG_FILE}" "${TEMPDIR}/civ_config.yml"

sudo "${CONTAINER_RUNTIME}" run \
    -a stdout -a stderr \
    -e AWS_ACCESS_KEY_ID="${CLOUDX_AWS_ACCESS_KEY_ID}" \
    -e AWS_SECRET_ACCESS_KEY="${CLOUDX_AWS_SECRET_ACCESS_KEY}" \
    -e AWS_REGION="${AWS_REGION}" \
    -e JIRA_PAT="${JIRA_PAT}" \
    -v "${TEMPDIR}":/tmp:Z \
    "${CONTAINER_CLOUD_IMAGE_VAL}" \
    python cloud-image-val.py \
    -c /tmp/civ_config.yml

CIV_EXIT_CODE=$?

mv "${TEMPDIR}"/report.html "${ARTIFACTS}"

# Clean up our mess.
if [[ -z $KEEP_GENERATED_AMI ]]; then
    greenprint "🧼 Cleaning up"
    $AWS_CMD ec2 deregister-image --image-id "${AMI_IMAGE_ID}"
    $AWS_CMD ec2 delete-snapshot --snapshot-id "${SNAPSHOT_ID}"
fi

# Also delete the compose so we don't run out of disk space
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null

# Use the return code of the smoke test to determine if we passed or failed.
# On rhel continue with the cloudapi test
case $CIV_EXIT_CODE in
    0)
        greenprint "💚 Success"
        exit 0
        ;;
    5)
        echo "❗ No tests were run"
        exit 0
        ;;
    100)
        redprint "❌ Failed (cloud deployment/destroy issues)"
        exit 1
        ;;
    *)
        redprint "❌ Failed (exit code: ${CIV_EXIT_CODE})"
        exit 1
        ;;
esac

exit 0

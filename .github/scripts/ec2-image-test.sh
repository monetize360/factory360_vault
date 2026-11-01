#!/usr/bin/env bash
# Smoke test a Vault container image from ECR on a throwaway EC2 instance.
#
# Launches a t2.medium (Amazon Linux 2023) with no SSH key and no inbound
# access, runs the checks below on it through SSM Run Command, prints the
# output, and always terminates the instance. Exits non-zero if any check fails.
#
# Required environment:
#   IMAGE                    Full image reference to test, e.g. <registry>/tokenengine/vault:<sha>
#   EXPECTED_VERSION         Version string `vault version` must report, e.g. 2.3.0-beta1
#   AWS_REGION               Region to launch the instance in
#   EC2_INSTANCE_PROFILE     Instance profile with SSM core + ECR pull permissions
#   EC2_SECURITY_GROUP_ID    Security group for the instance (no inbound rules needed)
#   EC2_SUBNET_ID            Subnet with outbound internet access
# Optional:
#   EC2_INSTANCE_TYPE        Defaults to t2.medium

set -euo pipefail

: "${IMAGE:?}" "${EXPECTED_VERSION:?}" "${AWS_REGION:?}"
: "${EC2_INSTANCE_PROFILE:?}" "${EC2_SECURITY_GROUP_ID:?}" "${EC2_SUBNET_ID:?}"
EC2_INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-t2.medium}"
AMI_PARAM=/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
TAG_PURPOSE=vault-image-test

export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

log() { echo "==> $*" >&2; }

instance_id=""
cleanup() {
  if [ -n "$instance_id" ]; then
    log "Terminating $instance_id"
    aws ec2 terminate-instances --instance-ids "$instance_id" > /dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM # e.g. the workflow run is cancelled; still runs cleanup

# The tests that run on the instance. Arguments: <image> <expected version>.
read -r -d '' remote_script << 'REMOTE' || true
set -euo pipefail
image="$1"
expected_version="$2"
token=smoke-test-root-token
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; docker logs vault 2>&1 | tail -50 || true; exit 1; }
v() { docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$token" vault vault "$@"; }

dnf install -y -q docker jq > /dev/null
systemctl start docker

registry="${image%%/*}" # <account>.dkr.ecr.<region>.amazonaws.com
aws ecr get-login-password --region "$(cut -d. -f4 <<< "$registry")" |
  docker login --username AWS --password-stdin "$registry" > /dev/null
docker pull -q "$image" || fail "pull $image"
pass "pulled $image"

docker run -d --name vault --cap-add=IPC_LOCK -p 8200:8200 \
  -e VAULT_DEV_ROOT_TOKEN_ID="$token" -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  "$image" > /dev/null || fail "start container"

for _ in $(seq 60); do
  curl -sf http://127.0.0.1:8200/v1/sys/health > /tmp/health.json && break
  sleep 1
done
[ "$(jq -r '.initialized and (.sealed | not)' /tmp/health.json 2>/dev/null)" = true ] || fail "health endpoint (initialized and unsealed)"
pass "health endpoint: initialized and unsealed"

v status > /dev/null || fail "vault status"
pass "vault status"

actual_version=$(v version)
grep -qF "$expected_version" <<< "$actual_version" || fail "version: want $expected_version, got: $actual_version"
pass "version: $actual_version"

[ "$(docker exec vault id -un)" = vault ] || fail "container runs as non-root user vault"
pass "container runs as user vault"

v kv put -mount=secret smoke-test value=hello-from-ci > /dev/null || fail "kv put"
[ "$(v kv get -mount=secret -field=value smoke-test)" = hello-from-ci ] || fail "kv read-back"
pass "kv v2 write and read"

v secrets enable transit > /dev/null || fail "enable transit"
v write -f transit/keys/smoke-test > /dev/null || fail "create transit key"
plaintext=$(printf 'transit round trip' | base64)
ciphertext=$(v write -field=ciphertext transit/encrypt/smoke-test plaintext="$plaintext") || fail "transit encrypt"
[ "$(v write -field=plaintext transit/decrypt/smoke-test ciphertext="$ciphertext")" = "$plaintext" ] || fail "transit decrypt"
pass "transit encrypt and decrypt"

ui_status=$(curl -s -o /tmp/ui.html -w '%{http_code}' http://127.0.0.1:8200/ui/) || fail "web UI request failed (curl exit $?)"
[ "$ui_status" = 200 ] || fail "web UI: HTTP $ui_status"
grep -q '</html>' /tmp/ui.html || fail "web UI page incomplete"
grep -q 'name="csp-nonce"' /tmp/ui.html || fail "web UI page missing CSP nonce"
pass "web UI page served complete ($(wc -c < /tmp/ui.html) bytes)"

ui_asset=$(grep -oE 'src="/ui/assets/[^"]+\.js"' /tmp/ui.html | head -1 | cut -d'"' -f2)
[ -n "$ui_asset" ] || fail "web UI page references no JavaScript assets"
curl -sf -o /dev/null "http://127.0.0.1:8200$ui_asset" || fail "web UI asset $ui_asset"
pass "web UI asset served ($ui_asset)"

echo "ALL CHECKS PASSED"
REMOTE

log "Launching $EC2_INSTANCE_TYPE in $EC2_SUBNET_ID"
instance_id=$(aws ec2 run-instances \
  --image-id "resolve:ssm:$AMI_PARAM" \
  --instance-type "$EC2_INSTANCE_TYPE" \
  --iam-instance-profile "Name=$EC2_INSTANCE_PROFILE" \
  --network-interfaces "DeviceIndex=0,SubnetId=$EC2_SUBNET_ID,Groups=$EC2_SECURITY_GROUP_ID,AssociatePublicIpAddress=true" \
  --metadata-options HttpTokens=required \
  --instance-initiated-shutdown-behavior terminate \
  --user-data '#!/bin/bash
shutdown -h +60' \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_PURPOSE},{Key=Purpose,Value=$TAG_PURPOSE},{Key=GitHubRun,Value=${GITHUB_RUN_ID:-local}}]" \
    "ResourceType=volume,Tags=[{Key=Purpose,Value=$TAG_PURPOSE}]" \
    "ResourceType=network-interface,Tags=[{Key=Purpose,Value=$TAG_PURPOSE}]" \
  --query 'Instances[0].InstanceId' --output text)
log "Launched $instance_id (self-terminates after 60 minutes as a safety net)"

aws ec2 wait instance-running --instance-ids "$instance_id"
log "Instance running; waiting for SSM agent"
for _ in $(seq 60); do
  ping=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text)
  [ "$ping" = Online ] && break
  sleep 10
done
[ "$ping" = Online ] || { log "SSM agent never came online"; exit 1; }

log "Running image tests"
encoded=$(base64 <<< "$remote_script" | tr -d '\n')
command_id=$(aws ssm send-command \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "vault image test ${GITHUB_RUN_ID:-local}" \
  --parameters "$(jq -cn --arg cmd "echo $encoded | base64 -d > /tmp/image-test.sh && bash /tmp/image-test.sh '$IMAGE' '$EXPECTED_VERSION'" \
    '{commands: [$cmd], executionTimeout: ["900"]}')" \
  --query Command.CommandId --output text)

status=Pending
while [[ $status =~ ^(Pending|InProgress|Delayed)$ ]]; do
  sleep 10
  status=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query Status --output text 2> /dev/null || echo Pending)
done

aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text

log "Image tests finished: $status"
[ "$status" = Success ]

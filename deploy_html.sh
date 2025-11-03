#!/usr/bin/env bash
set -euo pipefail

# =========================
# HTML.ZIP-ONLY DEPLOYMENT
# =========================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*"; }

# ---- static config ----
GITHUB_URL="https://github.com/Mathpix/PDF_Accessibility.git"  # source repository
PROJECT_NAME="pdf2html-zip-$(date +%Y%m%d%H%M%S)"
ROLE_NAME="${PROJECT_NAME}-codebuild-role"
POLICY_NAME="${PROJECT_NAME}-codebuild-policy"
BUILD_IMAGE="aws/codebuild/amazonlinux2-x86_64-standard:5.0"
COMPUTE_TYPE="BUILD_GENERAL1_LARGE"
PRIVILEGED_MODE=true
BUILDSPEC_FILE="buildspec-unified.yml"  # we use the existing buildspec
SOURCE_VERSION="feature/html-mathpix"

# ---- aws identity/region ----
info "Checking AWS identity/region..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_DEFAULT_REGION:-$(aws configure get region || true)}"
if [[ -z "${REGION:-}" ]]; then
  err "Region is not set. Do: export AWS_DEFAULT_REGION=us-west-2"
  exit 1
fi
ok "Account: $ACCOUNT_ID, Region: $REGION"

# ---- bucket (single) ----
BUCKET_NAME="pdf2html-bucket-${ACCOUNT_ID}-${REGION}"
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  ok "Bucket exists: s3://$BUCKET_NAME"
else
  info "Creating bucket s3://$BUCKET_NAME ..."
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME"
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --create-bucket-configuration LocationConstraint="$REGION"
  fi
  ok "Bucket created."
fi

# ---- IAM role for CodeBuild ----
info "Ensuring IAM role: $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  ok "Role exists."
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
else
  TRUST_POLICY='{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }'
  ROLE_ARN=$(aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query Role.Arn --output text)
  ok "Role created: $ROLE_ARN"
fi

# ---- IAM policy (minimal for html.zip pipeline) ----
# - s3:* (uploads/output/remediated buckets)
# - logs:* (CodeBuild logs)
# - lambda:* (if the build/CFN deploys Lambda)
# - cloudformation:* (if the build runs CFN)
# - iam PassRole/GetRole/AttachRolePolicy (minimum for builds/CFNs)
# - sts:GetCallerIdentity
# - ssm:Get*/PutParameter (if the build reads/writes parameters)
# - bedrock runtime (OPTIONAL) for alt text generation: Converse/InvokeModel
POLICY_DOC=$(cat <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "S3FullAccess", "Effect": "Allow", "Action": ["s3:*"], "Resource": "*" },
    { "Sid": "CloudWatchLogsFullAccess", "Effect": "Allow", "Action": ["logs:*"], "Resource": "*" },
    { "Sid": "LambdaFullAccess", "Effect": "Allow", "Action": ["lambda:*"], "Resource": "*" },
    { "Sid": "CloudFormationFullAccess", "Effect": "Allow", "Action": ["cloudformation:*"], "Resource": "*" },
    { "Sid": "IAMFullAccess", "Effect": "Allow", "Action": ["iam:*"], "Resource": "*" },
    { "Sid": "STSAccess", "Effect": "Allow", "Action": ["sts:GetCallerIdentity", "sts:AssumeRole"], "Resource": "*" },
    { "Sid": "SSMParameterAccess", "Effect": "Allow", "Action": ["ssm:GetParameter","ssm:GetParameters","ssm:PutParameter"], "Resource": "*" },
    { "Sid": "BedrockFullAccess", "Effect": "Allow",
      "Action": ["bedrock:*", "bedrock-data-automation:*", "bedrock-data-automation-runtime:*"],
      "Resource": "*"
    },
    { "Sid": "ECRFullAccess", "Effect": "Allow", "Action": ["ecr:*"], "Resource": "*" }
  ]
}
JSON
)

info "Ensuring IAM policy: $POLICY_NAME"
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOC" >/dev/null
  ok "Policy created."
else
  warn "Policy exists; leaving as-is."
fi

# attach policy to role
if aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
   --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN']" --output text | grep -q "$POLICY_ARN"; then
  ok "Policy already attached."
else
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
  ok "Policy attached."
fi

info "Waiting 10s for IAM propagation..."
sleep 10

# ---- CodeBuild project (env with PIPELINE_MODE=mathpix_html_zip) ----
info "Creating/Updating CodeBuild project: $PROJECT_NAME"

ENV_VARS=$(jq -n \
  --arg DEPLOYMENT_TYPE "pdf2html" \
  --arg ACCOUNT_ID "$ACCOUNT_ID" \
  --arg REGION "$REGION" \
  --arg BUCKET_NAME "$BUCKET_NAME" \
  --arg PIPELINE_MODE "mathpix_html_zip" \
  '[
     {"name":"DEPLOYMENT_TYPE","value":$DEPLOYMENT_TYPE},
     {"name":"ACCOUNT_ID","value":$ACCOUNT_ID},
     {"name":"REGION","value":$REGION},
     {"name":"BUCKET_NAME","value":$BUCKET_NAME},
     {"name":"PIPELINE_MODE","value":$PIPELINE_MODE}
   ]')

ENV_JSON=$(jq -n \
  --arg image "$BUILD_IMAGE" \
  --arg compute "$COMPUTE_TYPE" \
  --argjson priv $PRIVILEGED_MODE \
  --argjson env "$ENV_VARS" \
  '{type:"LINUX_CONTAINER", image:$image, computeType:$compute, privilegedMode:$priv, environmentVariables:$env}')

SOURCE_JSON=$(jq -n \
  --arg url "$GITHUB_URL" \
  --arg buildspec "$BUILDSPEC_FILE" \
  '{type:"GITHUB", location:$url, buildspec:$buildspec}')

if aws codebuild batch-get-projects --names "$PROJECT_NAME" --query 'projects[0].name' --output text 2>/dev/null | grep -q "$PROJECT_NAME"; then
  aws codebuild update-project \
    --name "$PROJECT_NAME" \
    --source "$SOURCE_JSON" \
    --artifacts '{"type":"NO_ARTIFACTS"}' \
    --environment "$ENV_JSON" \
    --service-role "$ROLE_ARN" >/dev/null
  ok "CodeBuild project updated."
else
  aws codebuild create-project \
    --name "$PROJECT_NAME" \
    --source "$SOURCE_JSON" \
    --source-version "$SOURCE_VERSION" \
    --artifacts '{"type":"NO_ARTIFACTS"}' \
    --environment "$ENV_JSON" \
    --service-role "$ROLE_ARN" >/dev/null
  ok "CodeBuild project created."
fi

# ---- start build ----
info "Starting build..."
BUILD_ID=$(aws codebuild start-build --project-name "$PROJECT_NAME" --source-version "$SOURCE_VERSION" --query 'build.id' --output text)
ok "Build started: $BUILD_ID"

# ---- basic wait loop ----
info "Streaming status (Ctrl-C to stop watching):"
LAST=""
while true; do
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --query 'builds[0].buildStatus' --output text 2>/dev/null || echo "UNKNOWN")
  [[ "$STATUS" != "$LAST" ]] && { echo -e "  -> ${CYAN}${STATUS}${NC}"; LAST="$STATUS"; }
  case "$STATUS" in
    SUCCEEDED) ok "Deployment finished."; break ;;
    FAILED|FAULT|STOPPED|TIMED_OUT) err "Deployment failed: $STATUS"; exit 1 ;;
    *) sleep 5 ;;
  esac
done

echo
ok "Summary:"
echo "  • Pipeline mode : mathpix_html_zip"
echo "  • Bucket        : s3://$BUCKET_NAME"
echo "  • CodeBuild     : $PROJECT_NAME"
echo
info "Upload your Mathpix html.zip to s3://$BUCKET_NAME/uploads/ (e.g. mydoc.html.zip)"
info "The Lambda (deployed by the repo’s CFN/templates) should pick *.html.zip, extract → audit → remediate →"
info "Outputs in:"
echo "  • s3://$BUCKET_NAME/output/<name>.html and <name>.zip"
echo "  • s3://$BUCKET_NAME/remediated/final_<name>.zip"

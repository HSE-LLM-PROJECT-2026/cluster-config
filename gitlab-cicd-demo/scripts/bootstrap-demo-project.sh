#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="gitlab-demo"
PROJECT_NAME="llmops-platform-smoke"
PROJECT_PATH="llmops-platform-smoke"
BRANCH="main"
PAT_NAME="llmops-bootstrap"
PORT_FORWARD_PORT="38080"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found"
  exit 1
fi

PAT_VALUE="${GITLAB_BOOTSTRAP_PAT:-$(openssl rand -hex 24)}"
export PAT_VALUE

echo "[1/8] Ensuring GitLab + runner are ready"
kubectl -n "$NAMESPACE" rollout status statefulset/gitlab --timeout=45m
kubectl -n "$NAMESPACE" rollout status deploy/gitlab-runner --timeout=10m

echo "[2/8] Creating/refreshing root PAT inside GitLab"
kubectl -n "$NAMESPACE" exec statefulset/gitlab -- bash -lc "BOOTSTRAP_PAT='$PAT_VALUE' gitlab-rails runner \"
user = User.find_by_username('root')
token = user.personal_access_tokens.where(name: '$PAT_NAME').first
if token.nil?
  token = user.personal_access_tokens.build(name: '$PAT_NAME', scopes: [:api], expires_at: 365.days.from_now)
end
token.set_token(ENV['BOOTSTRAP_PAT'])
token.save!
puts token.token
\"" >/tmp/gitlab-pat.out

ACTUAL_PAT=$(tail -n1 /tmp/gitlab-pat.out | tr -d '\r')
if [[ -z "$ACTUAL_PAT" ]]; then
  echo "Failed to create PAT"
  exit 1
fi

echo "[3/8] Starting temporary port-forward to GitLab"
kubectl -n "$NAMESPACE" port-forward svc/gitlab "$PORT_FORWARD_PORT":80 >/tmp/gitlab-portforward.log 2>&1 &
PF_PID=$!
cleanup() {
  if ps -p "$PF_PID" >/dev/null 2>&1; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$PORT_FORWARD_PORT/-/health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

GITLAB_API="http://127.0.0.1:$PORT_FORWARD_PORT/api/v4"

echo "[4/8] Creating project if missing"
EXISTING=$(curl -sS --header "PRIVATE-TOKEN: $ACTUAL_PAT" "$GITLAB_API/projects?search=$PROJECT_PATH" | jq -r '.[] | select(.path=="'"$PROJECT_PATH"'") | .id' | head -n1)

if [[ -n "$EXISTING" ]]; then
  PROJECT_ID="$EXISTING"
  echo "Project already exists: id=$PROJECT_ID"
else
  CREATE_RESP=$(curl -sS --request POST --header "PRIVATE-TOKEN: $ACTUAL_PAT" \
    --header "Content-Type: application/json" \
    --data "$(jq -n --arg name "$PROJECT_NAME" --arg path "$PROJECT_PATH" --arg branch "$BRANCH" '{name:$name, path:$path, initialize_with_readme:true, default_branch:$branch, visibility:"private"}')" \
    "$GITLAB_API/projects")
  PROJECT_ID=$(echo "$CREATE_RESP" | jq -r '.id // empty')
  if [[ -z "$PROJECT_ID" ]]; then
    echo "Failed to create project"
    echo "$CREATE_RESP"
    exit 1
  fi
  echo "Project created: id=$PROJECT_ID"
fi

CI_FILE_CONTENT=$(cat "$ROOT_DIR/ci-demo-project/.gitlab-ci.yml")
README_CONTENT=$(cat <<'TXT'
# LLMOps platform smoke

This repository is created automatically by `gitlab-cicd-demo` bootstrap.
It contains a CI pipeline that checks live health/list endpoints of the deployed LLMOps platform services.
TXT
)

upsert_file() {
  local project_id="$1"
  local file_path="$2"
  local content="$3"
  local message="$4"
  local encoded
  encoded=$(printf '%s' "$file_path" | jq -sRr @uri)

  local status
  status=$(curl -s -o /tmp/gitlab-file-check.json -w "%{http_code}" \
    --header "PRIVATE-TOKEN: $ACTUAL_PAT" \
    "$GITLAB_API/projects/$project_id/repository/files/$encoded?ref=$BRANCH")

  if [[ "$status" == "200" ]]; then
    curl -sS --request PUT \
      --header "PRIVATE-TOKEN: $ACTUAL_PAT" \
      --header "Content-Type: application/json" \
      --data "$(jq -n --arg branch "$BRANCH" --arg content "$content" --arg cm "$message" '{branch:$branch, content:$content, commit_message:$cm}')" \
      "$GITLAB_API/projects/$project_id/repository/files/$encoded" >/tmp/gitlab-file-upsert.json
  else
    curl -sS --request POST \
      --header "PRIVATE-TOKEN: $ACTUAL_PAT" \
      --header "Content-Type: application/json" \
      --data "$(jq -n --arg branch "$BRANCH" --arg content "$content" --arg cm "$message" '{branch:$branch, content:$content, commit_message:$cm}')" \
      "$GITLAB_API/projects/$project_id/repository/files/$encoded" >/tmp/gitlab-file-upsert.json
  fi
}

echo "[5/8] Writing .gitlab-ci.yml"
upsert_file "$PROJECT_ID" ".gitlab-ci.yml" "$CI_FILE_CONTENT" "ci: update smoke pipeline"

echo "[6/8] Writing README.md"
upsert_file "$PROJECT_ID" "README.md" "$README_CONTENT" "docs: update readme"

echo "[7/8] Triggering pipeline"
PIPELINE_RESP=$(curl -sS --request POST \
  --header "PRIVATE-TOKEN: $ACTUAL_PAT" \
  --header "Content-Type: application/json" \
  --data "$(jq -n --arg ref "$BRANCH" '{ref:$ref}')" \
  "$GITLAB_API/projects/$PROJECT_ID/pipeline")

PIPELINE_ID=$(echo "$PIPELINE_RESP" | jq -r '.id // empty')
if [[ -z "$PIPELINE_ID" ]]; then
  echo "Failed to trigger pipeline"
  echo "$PIPELINE_RESP"
  exit 1
fi

echo "[8/8] Done"
echo "Project ID: $PROJECT_ID"
echo "Pipeline ID: $PIPELINE_ID"
echo "GitLab URL: http://127.0.0.1:$PORT_FORWARD_PORT/root/$PROJECT_PATH/-/pipelines/$PIPELINE_ID"

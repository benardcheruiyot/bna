#!/usr/bin/env bash
set -euo pipefail

# Automates GitHub Actions environment setup for production and staging deploys.
# Requires:
#   - gh CLI installed and authenticated (gh auth login)
#   - local backend/frontend env files
#
# Example:
# ./scripts/setup_github_environments.sh \
#   --vps-host 153.75.247.188 \
#   --vps-user root \
#   --ssh-key-file ~/.ssh/id_ed25519 \
#   --certbot-email admin@talamkopo.mkopaji.com \
#   --prod-domain talamkopo.mkopaji.com \
#   --staging-domain staging.talamkopo.mkopaji.com

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing command: $cmd"
    exit 1
  fi
}

upsert_line() {
  local key="$1"
  local value="$2"
  local file="$3"
  local escaped

  escaped="$(printf '%s' "$value" | sed 's/[&|]/\\&/g')"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

HOST=""
USER_NAME=""
SSH_KEY_FILE=""
CERTBOT_EMAIL=""
PROD_DOMAIN=""
STAGING_DOMAIN=""
REPO=""
DEPLOY_REPO=""
PROD_PATH="/var/www/your-app-slug"
STAGING_PATH="/var/www/your-app-slug-staging"
PROD_BRANCH="main"
STAGING_BRANCH="staging"
PROD_BACKEND_PORT=""
STAGING_BACKEND_PORT=""
PROD_PM2_NAME=""
STAGING_PM2_NAME=""
BACKEND_ENV_FILE="backend/.env"
FRONTEND_ENV_FILE="frontend/.env"
BACKEND_STAGING_ENV_FILE="backend/.env.staging"
FRONTEND_STAGING_ENV_FILE="frontend/.env.staging"

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

derive_port() {
  local value="$1"
  local slug checksum
  slug="$(slugify "$value")"
  checksum="$(printf '%s' "$slug" | cksum | awk '{print $1 % 1000}')"
  printf '%s' "$((5100 + checksum))"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vps-host)
      HOST="$2"
      shift 2
      ;;
    --vps-user)
      USER_NAME="$2"
      shift 2
      ;;
    --ssh-key-file)
      SSH_KEY_FILE="$2"
      shift 2
      ;;
    --certbot-email)
      CERTBOT_EMAIL="$2"
      shift 2
      ;;
    --prod-domain)
      PROD_DOMAIN="$2"
      shift 2
      ;;
    --staging-domain)
      STAGING_DOMAIN="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --deploy-repo)
      DEPLOY_REPO="$2"
      shift 2
      ;;
    --prod-path)
      PROD_PATH="$2"
      shift 2
      ;;
    --staging-path)
      STAGING_PATH="$2"
      shift 2
      ;;
    --prod-branch)
      PROD_BRANCH="$2"
      shift 2
      ;;
    --staging-branch)
      STAGING_BRANCH="$2"
      shift 2
      ;;
    --prod-backend-port)
      PROD_BACKEND_PORT="$2"
      shift 2
      ;;
    --staging-backend-port)
      STAGING_BACKEND_PORT="$2"
      shift 2
      ;;
    --prod-pm2-name)
      PROD_PM2_NAME="$2"
      shift 2
      ;;
    --staging-pm2-name)
      STAGING_PM2_NAME="$2"
      shift 2
      ;;
    --backend-env-file)
      BACKEND_ENV_FILE="$2"
      shift 2
      ;;
    --frontend-env-file)
      FRONTEND_ENV_FILE="$2"
      shift 2
      ;;
    --backend-staging-env-file)
      BACKEND_STAGING_ENV_FILE="$2"
      shift 2
      ;;
    --frontend-staging-env-file)
      FRONTEND_STAGING_ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,120p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

require_cmd gh
require_cmd git

if [[ -z "$HOST" || -z "$USER_NAME" || -z "$SSH_KEY_FILE" || -z "$CERTBOT_EMAIL" || -z "$PROD_DOMAIN" || -z "$STAGING_DOMAIN" ]]; then
  echo "Missing required arguments. Run with --help to see usage."
  exit 1
fi

if [[ ! -f "$SSH_KEY_FILE" ]]; then
  echo "SSH key file not found: $SSH_KEY_FILE"
  exit 1
fi

if [[ ! -f "$BACKEND_ENV_FILE" || ! -f "$FRONTEND_ENV_FILE" ]]; then
  echo "Missing production env files. Expected: $BACKEND_ENV_FILE and $FRONTEND_ENV_FILE"
  exit 1
fi

if [[ -z "$REPO" ]]; then
  # Convert remote URL into owner/repo format when possible.
  ORIGIN_URL="$(git config --get remote.origin.url || true)"
  if [[ "$ORIGIN_URL" =~ github.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
    REPO="${BASH_REMATCH[1]}"
  fi
fi

if [[ -z "$REPO" ]]; then
  echo "Could not determine GitHub repo. Provide --repo owner/repo"
  exit 1
fi

if [[ -z "$DEPLOY_REPO" ]]; then
  DEPLOY_REPO="$(git config --get remote.origin.url || true)"
fi

if [[ -z "$PROD_BACKEND_PORT" ]]; then
  PROD_BACKEND_PORT="$(derive_port "$PROD_DOMAIN")"
fi

if [[ -z "$STAGING_BACKEND_PORT" ]]; then
  STAGING_BACKEND_PORT="$(derive_port "$STAGING_DOMAIN")"
fi

if [[ -z "$PROD_PM2_NAME" ]]; then
  PROD_PM2_NAME="$(slugify "$PROD_DOMAIN")-backend"
fi

if [[ -z "$STAGING_PM2_NAME" ]]; then
  STAGING_PM2_NAME="$(slugify "$STAGING_DOMAIN")-backend"
fi

PROD_BACKEND_CONTENT="$(cat "$BACKEND_ENV_FILE")"
PROD_FRONTEND_CONTENT="$(cat "$FRONTEND_ENV_FILE")"
SSH_KEY_CONTENT="$(cat "$SSH_KEY_FILE")"

# Build staging env files from explicit staging files when present, otherwise from production templates.
TMP_BACKEND_STAGING="$(mktemp)"
TMP_FRONTEND_STAGING="$(mktemp)"
trap 'rm -f "$TMP_BACKEND_STAGING" "$TMP_FRONTEND_STAGING"' EXIT

if [[ -f "$BACKEND_STAGING_ENV_FILE" ]]; then
  cat "$BACKEND_STAGING_ENV_FILE" > "$TMP_BACKEND_STAGING"
else
  printf '%s\n' "$PROD_BACKEND_CONTENT" > "$TMP_BACKEND_STAGING"
fi

if [[ -f "$FRONTEND_STAGING_ENV_FILE" ]]; then
  cat "$FRONTEND_STAGING_ENV_FILE" > "$TMP_FRONTEND_STAGING"
else
  printf '%s\n' "$PROD_FRONTEND_CONTENT" > "$TMP_FRONTEND_STAGING"
fi

upsert_line "NODE_ENV" "production" "$TMP_BACKEND_STAGING"
upsert_line "PORT" "$STAGING_BACKEND_PORT" "$TMP_BACKEND_STAGING"
upsert_line "ALLOWED_ORIGINS" "https://${STAGING_DOMAIN},https://www.${STAGING_DOMAIN}" "$TMP_BACKEND_STAGING"
upsert_line "ALLOWED_BASE_DOMAIN" "${STAGING_DOMAIN}" "$TMP_BACKEND_STAGING"
upsert_line "APP_PUBLIC_URL" "https://${STAGING_DOMAIN}" "$TMP_BACKEND_STAGING"
upsert_line "MPESA_CALLBACK_URL" "https://${STAGING_DOMAIN}/api/mpesa/callback" "$TMP_BACKEND_STAGING"
upsert_line "REACT_APP_API_URL" "https://${STAGING_DOMAIN}/api" "$TMP_FRONTEND_STAGING"

STAGING_BACKEND_CONTENT="$(cat "$TMP_BACKEND_STAGING")"
STAGING_FRONTEND_CONTENT="$(cat "$TMP_FRONTEND_STAGING")"

# Create environments if they do not exist. Ignored if already present.
gh api -X PUT "repos/${REPO}/environments/production" >/dev/null
gh api -X PUT "repos/${REPO}/environments/staging" >/dev/null

# Production environment secrets
echo "$HOST" | gh secret set VPS_HOST --env production --repo "$REPO"
echo "$USER_NAME" | gh secret set VPS_USER --env production --repo "$REPO"
echo "$SSH_KEY_CONTENT" | gh secret set VPS_SSH_KEY --env production --repo "$REPO"
echo "$PROD_BACKEND_CONTENT" | gh secret set BACKEND_ENV_FILE --env production --repo "$REPO"
echo "$PROD_FRONTEND_CONTENT" | gh secret set FRONTEND_ENV_FILE --env production --repo "$REPO"

# Staging environment secrets
echo "$HOST" | gh secret set VPS_HOST --env staging --repo "$REPO"
echo "$USER_NAME" | gh secret set VPS_USER --env staging --repo "$REPO"
echo "$SSH_KEY_CONTENT" | gh secret set VPS_SSH_KEY --env staging --repo "$REPO"
echo "$STAGING_BACKEND_CONTENT" | gh secret set BACKEND_ENV_FILE --env staging --repo "$REPO"
echo "$STAGING_FRONTEND_CONTENT" | gh secret set FRONTEND_ENV_FILE --env staging --repo "$REPO"

# Production variables
echo "$PROD_DOMAIN" | gh variable set APP_DOMAIN --env production --repo "$REPO"
echo "$CERTBOT_EMAIL" | gh variable set CERTBOT_EMAIL --env production --repo "$REPO"
echo "$PROD_PATH" | gh variable set DEPLOY_PATH --env production --repo "$REPO"
echo "$PROD_BRANCH" | gh variable set DEPLOY_BRANCH --env production --repo "$REPO"
echo "$PROD_BACKEND_PORT" | gh variable set BACKEND_PORT --env production --repo "$REPO"
echo "$PROD_PM2_NAME" | gh variable set PM2_APP_NAME --env production --repo "$REPO"
if [[ -n "$DEPLOY_REPO" ]]; then
  echo "$DEPLOY_REPO" | gh variable set DEPLOY_REPO --env production --repo "$REPO"
fi

# Staging variables
echo "$STAGING_DOMAIN" | gh variable set APP_DOMAIN --env staging --repo "$REPO"
echo "$CERTBOT_EMAIL" | gh variable set CERTBOT_EMAIL --env staging --repo "$REPO"
echo "$STAGING_PATH" | gh variable set DEPLOY_PATH --env staging --repo "$REPO"
echo "$STAGING_BRANCH" | gh variable set DEPLOY_BRANCH --env staging --repo "$REPO"
echo "$STAGING_BACKEND_PORT" | gh variable set BACKEND_PORT --env staging --repo "$REPO"
echo "$STAGING_PM2_NAME" | gh variable set PM2_APP_NAME --env staging --repo "$REPO"
if [[ -n "$DEPLOY_REPO" ]]; then
  echo "$DEPLOY_REPO" | gh variable set DEPLOY_REPO --env staging --repo "$REPO"
fi

echo "GitHub environments configured successfully for repo: $REPO"
echo "Production deploy: push to main or run Deploy Production workflow"
echo "Staging deploy: push to staging or run Deploy Staging workflow"

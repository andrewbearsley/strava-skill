#!/usr/bin/env bash
#
# strava-auth.sh - OAuth2 setup and token management for the Strava API
#
# Usage:
#   ./strava-auth.sh setup    One-time OAuth2 authorization flow
#   ./strava-auth.sh refresh  Refresh the access token
#   ./strava-auth.sh token    Output a valid access token (auto-refreshes if expired)
#
# Requires: curl, jq, openssl (setup only)
# Environment: STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET

set -euo pipefail

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' not found. Install it and try again." >&2
    exit 1
  fi
done

# --- Configuration ---

AUTH_URL="https://www.strava.com/oauth/authorize"
TOKEN_URL="https://www.strava.com/api/v3/oauth/token"

STRAVA_CLIENT_ID="${STRAVA_CLIENT_ID:?Error: STRAVA_CLIENT_ID environment variable is not set}"
STRAVA_CLIENT_SECRET="${STRAVA_CLIENT_SECRET:?Error: STRAVA_CLIENT_SECRET environment variable is not set}"
STRAVA_TOKEN_FILE="${STRAVA_TOKEN_FILE:-$HOME/.strava-tokens}"
STRAVA_REDIRECT_URI="${STRAVA_REDIRECT_URI:-http://localhost:9876/callback}"

save_tokens() {
  local access_token="$1" refresh_token="$2" expires_at="$3" athlete_id="$4"

  if [ "$access_token" = "null" ] || [ -z "$access_token" ]; then
    echo "Error: API response missing access_token" >&2
    return 1
  fi
  if [ "$refresh_token" = "null" ] || [ -z "$refresh_token" ]; then
    echo "Error: API response missing refresh_token" >&2
    return 1
  fi

  (
    umask 077
    local tmp="${STRAVA_TOKEN_FILE}.tmp.$$"
    jq -n \
      --arg at "$access_token" \
      --arg rt "$refresh_token" \
      --arg ea "$expires_at" \
      --arg aid "$athlete_id" \
      '{access_token: $at, refresh_token: $rt, expires_at: ($ea | tonumber), athlete_id: $aid}' \
      > "$tmp"
    mv "$tmp" "$STRAVA_TOKEN_FILE"
  )
}

load_tokens() {
  if [ ! -f "$STRAVA_TOKEN_FILE" ]; then
    echo "Error: Token file not found at $STRAVA_TOKEN_FILE" >&2
    echo "Run '$0 setup' to authorize with Strava first." >&2
    return 1
  fi

  local perms
  if [[ "$OSTYPE" == "darwin"* ]]; then
    perms=$(stat -f '%Lp' "$STRAVA_TOKEN_FILE")
  else
    perms=$(stat -c '%a' "$STRAVA_TOKEN_FILE")
  fi
  if [ "$perms" != "600" ]; then
    echo "Warning: Token file has insecure permissions ($perms), fixing to 600." >&2
    chmod 600 "$STRAVA_TOKEN_FILE"
  fi

  local tokens
  tokens=$(cat "$STRAVA_TOKEN_FILE")
  if ! echo "$tokens" | jq -e '.access_token and .refresh_token and .expires_at' >/dev/null 2>&1; then
    echo "Error: Token file is corrupted or incomplete. Re-run '$0 setup'." >&2
    return 1
  fi

  echo "$tokens"
}

is_token_expired() {
  local tokens="$1"
  local expires_at now
  expires_at=$(echo "$tokens" | jq -r '.expires_at')
  now=$(date +%s)
  [ "$now" -ge "$((expires_at - 300))" ]
}

check_api_response() {
  local response="$1" context="$2"

  if ! echo "$response" | jq empty 2>/dev/null; then
    echo "Error: Invalid response from Strava API during $context" >&2
    return 1
  fi

  local msg
  msg=$(echo "$response" | jq -r '.message // empty' | head -c 200)
  if [ -n "$msg" ]; then
    echo "Error: Strava API error during $context: $msg" >&2
    return 1
  fi
}

# --- Commands ---

do_setup() {
  if ! command -v openssl &>/dev/null; then
    echo "Error: Required command 'openssl' not found. Install it and try again." >&2
    return 1
  fi

  local state
  state=$(openssl rand -hex 16)

  echo "Strava OAuth2 Setup" >&2
  echo "===================" >&2
  echo "" >&2
  echo "1. Open the following URL in your browser:" >&2
  echo "" >&2
  echo "   ${AUTH_URL}?client_id=${STRAVA_CLIENT_ID}&redirect_uri=${STRAVA_REDIRECT_URI}&response_type=code&approval_prompt=auto&scope=read,activity:read_all,profile:read_all&state=${state}" >&2
  echo "" >&2
  echo "2. Log in and authorize the application." >&2
  echo "3. You'll be redirected to a URL like:" >&2
  echo "   ${STRAVA_REDIRECT_URI}?state=...&code=XXXXX&scope=..." >&2
  echo "" >&2
  echo "   (The page won't load, that's expected. Copy the URL from your browser's address bar.)" >&2
  echo "" >&2
  read -rp "Paste the full redirect URL here: " redirect_url

  local returned_state
  returned_state=$(echo "$redirect_url" | sed -n 's/.*[?&]state=\([^&#]*\).*/\1/p')
  if [ "$returned_state" != "$state" ]; then
    echo "Error: State parameter mismatch. This could indicate a CSRF attack or a stale URL. Try again." >&2
    return 1
  fi

  local code
  code=$(echo "$redirect_url" | sed -n 's/.*[?&]code=\([^&#]*\).*/\1/p')

  if [ -z "$code" ]; then
    echo "Error: Could not extract authorization code from URL." >&2
    echo "Make sure you pasted the full URL including the ?code= parameter." >&2
    return 1
  fi

  if ! [[ "$code" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Authorization code contains unexpected characters." >&2
    return 1
  fi

  echo "" >&2
  echo "Exchanging authorization code for tokens..." >&2

  local response http_code
  response=$(curl -s -w '\n%{http_code}' -X POST "$TOKEN_URL" \
    -d "client_id=${STRAVA_CLIENT_ID}" \
    -d "client_secret=${STRAVA_CLIENT_SECRET}" \
    -d "code=${code}" \
    -d "grant_type=authorization_code" \
    --max-time 30)

  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"

  if [ "$http_code" -ge 400 ] 2>/dev/null; then
    local msg
    msg=$(echo "$response" | jq -r '.message // empty' 2>/dev/null | head -c 200)
    echo "Error: HTTP $http_code from Strava during token exchange${msg:+: $msg}" >&2
    return 1
  fi

  check_api_response "$response" "token exchange" || return 1

  local access_token refresh_token expires_at athlete_id
  access_token=$(echo "$response" | jq -r '.access_token')
  refresh_token=$(echo "$response" | jq -r '.refresh_token')
  expires_at=$(echo "$response" | jq -r '.expires_at')
  athlete_id=$(echo "$response" | jq -r '.athlete.id')

  save_tokens "$access_token" "$refresh_token" "$expires_at" "$athlete_id" || return 1

  local now
  now=$(date +%s)
  local expires_in=$((expires_at - now))

  echo "Success! Tokens saved to $STRAVA_TOKEN_FILE" >&2
  echo "  Athlete ID: $athlete_id" >&2
  echo "  Expires in: ${expires_in}s (~$((expires_in / 3600))h)" >&2
}

do_refresh() {
  local tokens
  tokens=$(load_tokens) || return 1

  local refresh_token
  refresh_token=$(echo "$tokens" | jq -r '.refresh_token')

  local response http_code
  response=$(curl -s -w '\n%{http_code}' -X POST "$TOKEN_URL" \
    -d "client_id=${STRAVA_CLIENT_ID}" \
    -d "client_secret=${STRAVA_CLIENT_SECRET}" \
    -d "refresh_token=${refresh_token}" \
    -d "grant_type=refresh_token" \
    --max-time 30)

  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"

  if [ "$http_code" -ge 400 ] 2>/dev/null; then
    local msg
    msg=$(echo "$response" | jq -r '.message // empty' 2>/dev/null | head -c 200)
    echo "Error: HTTP $http_code from Strava during token refresh${msg:+: $msg}" >&2
    return 1
  fi

  check_api_response "$response" "token refresh" || return 1

  local access_token new_refresh_token expires_at athlete_id
  access_token=$(echo "$response" | jq -r '.access_token')
  new_refresh_token=$(echo "$response" | jq -r '.refresh_token')
  expires_at=$(echo "$response" | jq -r '.expires_at')
  # Strava refresh response doesn't include athlete, preserve from saved tokens
  athlete_id=$(echo "$tokens" | jq -r '.athlete_id')

  save_tokens "$access_token" "$new_refresh_token" "$expires_at" "$athlete_id" || return 1

  local now
  now=$(date +%s)
  local expires_in=$((expires_at - now))

  echo "Token refreshed successfully." >&2
  echo "  Expires in: ${expires_in}s (~$((expires_in / 3600))h)" >&2
}

do_token() {
  local tokens
  tokens=$(load_tokens) || return 1

  if is_token_expired "$tokens"; then
    echo "Access token expired, refreshing..." >&2
    do_refresh || return 1
    tokens=$(load_tokens) || return 1
  fi

  echo "$tokens" | jq -r '.access_token'
}

# --- Main ---

case "${1:-}" in
  setup)   do_setup ;;
  refresh) do_refresh ;;
  token)   do_token ;;
  --help|-h)
    echo "Usage: $0 {setup|refresh|token}"
    echo ""
    echo "  setup    One-time OAuth2 authorization flow"
    echo "  refresh  Refresh the access token"
    echo "  token    Output a valid access token (auto-refreshes if expired)"
    echo ""
    echo "Environment:"
    echo "  STRAVA_CLIENT_ID      Strava app client ID"
    echo "  STRAVA_CLIENT_SECRET  Strava app client secret"
    echo "  STRAVA_TOKEN_FILE     Path to token file (default: ~/.strava-tokens)"
    echo "  STRAVA_REDIRECT_URI   OAuth redirect URI (default: http://localhost:9876/callback)"
    exit 0
    ;;
  *)
    echo "Usage: $0 {setup|refresh|token}" >&2
    echo "Run '$0 --help' for details." >&2
    exit 1
    ;;
esac

# Shared by the asana-* scripts: token lookup, API calls and JSON errors.
# Source it; it defines functions and variables only.
#
# Failures print {"error":{"kind":...,"message":...}} on the caller's real
# stdout and exit non-zero: 2 no-token, 3 auth, 4 network, 5 api.
#
# Task names, workspace names and API messages never go into a command's
# arguments, which every local user can read in the process list. They travel
# through stdin, files in a private temp dir, or the environment (readable
# only by you).

API="https://app.asana.com/api/1.0"
TOKEN_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/asana/token"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-asana"
CACHE_FILE="$CACHE_DIR/tasks.json"

# fd 3 is the real stdout, so errors raised inside $(...) still reach the
# caller instead of being captured as data.
exec 3>&1

fail() {
  printf '%s' "$2" | jq -cRs --arg kind "$1" '{error: {kind: $kind, message: .}}' >&3
  case "$1" in
    no-token) exit 2 ;;
    auth) exit 3 ;;
    network) exit 4 ;;
    *) exit 5 ;;
  esac
}

# Token from $ASANA_TOKEN, the GNOME keyring, or the fallback file.
read_token() {
  if [[ -n ${ASANA_TOKEN:-} ]]; then
    printf '%s' "$ASANA_TOKEN"
  elif command -v secret-tool >/dev/null && secret-tool lookup service omarchy-asana 2>/dev/null; then
    :
  elif [[ -r $TOKEN_FILE ]]; then
    tr -d '[:space:]' <"$TOKEN_FILE"
  fi
}

require_token() {
  TOKEN=$(read_token)
  [[ -n $TOKEN ]] || fail no-token "No Asana token found. Run asana-login to store your personal access token."
}

# api METHOD PATH [JSON_BODY] — print the response body of a request to a
# path relative to the API root, using $TOKEN. The token goes to curl through
# a file descriptor so it never shows up in the process list; the body goes
# through stdin.
api() {
  local method=$1 path=$2 body=${3-} response status
  local data=()
  [[ -n $body ]] && data=(--data-binary @- -H "Content-Type: application/json")
  response=$(printf '%s' "$body" | curl -sS --max-time 20 -X "$method" -w '\n%{http_code}' "${data[@]}" \
    -H @<(printf 'Authorization: Bearer %s\nAccept: application/json\n' "$TOKEN") \
    "$API$path" 2>/dev/null) || fail network "Could not reach Asana."
  status=${response##*$'\n'}
  body=${response%$'\n'*}

  case "$status" in
    2??) printf '%s' "$body" ;;
    401) fail auth "Asana rejected the token (HTTP 401). Run asana-login again." ;;
    429) fail api "Asana rate limit hit; try again in a minute." ;;
    *)
      local message
      message=$(jq -r '.errors[0].message // empty' <<<"$body" 2>/dev/null)
      fail api "Asana API error (HTTP $status)${message:+: $message}"
      ;;
  esac
}

# Like api, but a failure prints nothing and returns non-zero instead of
# ending the script, for data the caller can do without.
api_optional() {
  (api "$@" 3>/dev/null)
}

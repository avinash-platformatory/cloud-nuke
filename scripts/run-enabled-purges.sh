#!/bin/bash
set -euo pipefail

# run-enabled-purges.sh
#
# Purge all accounts listed in config/enabled-accounts.yaml using credentials
# from a JSON file. Continues on per-account failure; exits non-zero if any failed.
#
# Usage:
#   ./scripts/run-enabled-purges.sh --credentials-file /path/to/creds.json
#   ./scripts/run-enabled-purges.sh --credentials-file creds.json --account sub1 --dry-run
#   ./scripts/run-enabled-purges.sh --credentials-file creds.json --yes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="${REPO_ROOT}/config/enabled-accounts.yaml"
CREDENTIALS_FILE="${CLOUD_ACCOUNTS_CREDENTIALS_FILE:-}"
TARGET_ACCOUNT=""
TARGET_REGION=""
DRY_RUN=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)             CONFIG_FILE="$2";        shift 2 ;;
    --credentials-file)   CREDENTIALS_FILE="$2";   shift 2 ;;
    --account)            TARGET_ACCOUNT="$2";     shift 2 ;;
    --region)             TARGET_REGION="$2";      shift 2 ;;
    --dry-run)            DRY_RUN=true;             shift   ;;
    --yes)                AUTO_YES=true;            shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$CREDENTIALS_FILE" ]] && { echo "Error: --credentials-file is required" >&2; exit 1; }
[[ ! -f "$CREDENTIALS_FILE" ]] && { echo "Error: credentials file not found: $CREDENTIALS_FILE" >&2; exit 1; }
[[ ! -f "$CONFIG_FILE" ]] && { echo "Error: config file not found: $CONFIG_FILE" >&2; exit 1; }

parse_enabled_accounts() {
  python3 -c "
import json, sys

path = sys.argv[1]
accounts = []
in_accounts = False
with open(path) as f:
    for line in f:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if stripped == 'accounts:':
            in_accounts = True
            continue
        if in_accounts and stripped.startswith('- '):
            accounts.append(stripped[2:].strip())

print(json.dumps(accounts))
" "$CONFIG_FILE"
}

validate_account_in_credentials() {
  local account="$1"
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if sys.argv[2] not in data.get('accounts', {}):
    print(f\"Error: account '{sys.argv[2]}' is enabled but missing from credentials file\", file=sys.stderr)
    sys.exit(1)
" "$CREDENTIALS_FILE" "$account"
}

if [[ -n "$TARGET_ACCOUNT" ]]; then
  ENABLED_ACCOUNTS=$(python3 -c "import json; print(json.dumps(['$TARGET_ACCOUNT']))")
  # Verify target is in enabled list unless we're being explicit
  if ! parse_enabled_accounts | python3 -c "import json,sys; enabled=set(json.load(sys.stdin)); sys.exit(0 if '$TARGET_ACCOUNT' in enabled else 1)"; then
    echo "Error: account '$TARGET_ACCOUNT' is not in $CONFIG_FILE" >&2
    exit 1
  fi
else
  ENABLED_ACCOUNTS=$(parse_enabled_accounts)
fi

ACCOUNT_COUNT=$(echo "$ENABLED_ACCOUNTS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
if [[ "$ACCOUNT_COUNT" -eq 0 ]]; then
  echo "No enabled accounts found in $CONFIG_FILE"
  exit 0
fi

echo "Enabled accounts to purge: $(echo "$ENABLED_ACCOUNTS" | python3 -c "import json,sys; print(', '.join(json.load(sys.stdin)))")"

FAILED=0
while IFS= read -r account; do
  [[ -z "$account" ]] && continue
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  Processing account: $account"
  echo "══════════════════════════════════════════════════════════════"

  if ! validate_account_in_credentials "$account"; then
    FAILED=$((FAILED + 1))
    continue
  fi

  ARGS=(--account "$account" --credentials-file "$CREDENTIALS_FILE")
  [[ -n "$TARGET_REGION" ]] && ARGS+=(--region "$TARGET_REGION")
  [[ "$DRY_RUN" == "true" ]] && ARGS+=(--dry-run)
  [[ "$AUTO_YES" == "true" ]] && ARGS+=(--yes)

  if ! "$SCRIPT_DIR/purge-cloud-account.sh" "${ARGS[@]}"; then
    echo "Error: purge failed for account: $account" >&2
    FAILED=$((FAILED + 1))
  fi
done < <(echo "$ENABLED_ACCOUNTS" | python3 -c "import json,sys; [print(a) for a in json.load(sys.stdin)]")

if [[ "$FAILED" -gt 0 ]]; then
  echo ""
  echo "Completed with $FAILED failed account(s)." >&2
  exit 1
fi

echo ""
echo "All enabled accounts purged successfully."

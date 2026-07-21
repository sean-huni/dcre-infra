#!/bin/zsh
# Idempotent Grafana provisioning for DCRE client stats (spec section 7).
# Basic-auth admin API (dev admin/admin): /api/orgs/* accepts ONLY basic auth.
# Datasources are API-created (UI-editable by org Admins only; clients are Editors
# and cannot touch datasources; prod hardening = file provisioning, spec section 10).
set -e
# Target the IN-CLUSTER LGTM Grafana on host :3001 (scripts/lgtm-forward.sh forwards
# svc/lgtm 3000 -> host 3001). We deliberately do NOT read the ambient GRAFANA_URL:
# that variable points the Grafana MCP at the *compose* LGTM on :3000 (inner loop),
# a different Grafana - inheriting it silently provisions the wrong instance. Override
# this provisioner's target explicitly with DCRE_GRAFANA_URL if ever needed.
G="${DCRE_GRAFANA_URL:-http://localhost:3001}"
AUTH="admin:admin"
# Grafana 13 enforces a minimum password length of 4, so the brief's 3-char "dev"
# is rejected (password-policy-too-short). Use a policy-compliant dev credential;
# override with GRAFANA_DEV_PASSWORD if needed. Client login is <login>/$USER_PW.
USER_PW="${GRAFANA_DEV_PASSWORD:-devdev}"

org_id() { curl -sf -u "$AUTH" "$G/api/orgs/name/${1// /%20}" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || true }

ensure_org() {
  local name=$1
  local id=$(org_id "$name")
  if [[ -z "$id" ]]; then
    curl -sf -u "$AUTH" -H 'Content-Type: application/json' -X POST "$G/api/orgs" -d "{\"name\":\"$name\"}" > /dev/null
    id=$(org_id "$name")
  fi
  echo "$id"
}

ensure_user() {  # login, org_id
  local login=$1 oid=$2
  # Create the global user (tolerate "already exists" on re-run).
  curl -s -u "$AUTH" -H 'Content-Type: application/json' -X POST "$G/api/admin/users" \
    -d "{\"name\":\"$login\",\"login\":\"$login\",\"email\":\"$login@dcre.local\",\"password\":\"$USER_PW\"}" > /dev/null || true
  # Fail loudly if the user still does not exist (e.g. password policy rejected it),
  # instead of silently skipping the mandatory Editor account.
  if ! curl -sf -u "$AUTH" "$G/api/users/lookup?loginOrEmail=$login" > /dev/null 2>&1; then
    echo "ERROR: user $login not created (check Grafana password policy / GRAFANA_DEV_PASSWORD)" >&2
    exit 1
  fi
  # Add to the org as Editor (tolerate "already member" on re-run).
  curl -s -u "$AUTH" -H 'Content-Type: application/json' -X POST "$G/api/orgs/$oid/users" \
    -d "{\"loginOrEmail\":\"$login\",\"role\":\"Editor\"}" > /dev/null || true
  # Grafana auto-adds every admin-created user to Main Org (id 1) as Viewer, which would
  # land a client user in Main Org on login (breaking per-client isolation) and expose
  # Main Org's LGTM observability datasources. Remove the provisioned user from Main Org so
  # its sole membership is its client org. Idempotent: on re-run the user is already gone,
  # so DELETE returns non-2xx (404 / "user not found in org") and we tolerate it. Never the
  # admin user (id 1) - ensure_user is only ever called for client logins, and we guard on it.
  local uid=$(curl -sf -u "$AUTH" "$G/api/users/lookup?loginOrEmail=$login" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)
  if [[ -n "$uid" && "$uid" != "1" ]]; then
    curl -s -u "$AUTH" -X DELETE "$G/api/orgs/1/users/$uid" > /dev/null || true
  fi
}

ensure_ds() {  # org_id, ds_name, db, db_user
  local oid=$1 name=$2 db=$3 dbuser=$4
  # Update by UID: Grafana 13 removed the numeric-id datasource write endpoint
  # (PUT /api/datasources/:id -> 404); the supported path is /api/datasources/uid/:uid.
  local existing=$(curl -s -u "$AUTH" -H "X-Grafana-Org-Id: $oid" "$G/api/datasources/name/$name" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("uid",""))' 2>/dev/null || true)
  # Grafana 11+ Postgres frontend reads the database from jsonData.database, NOT the
  # legacy top-level "database" field. With only the top-level set, the BACKEND query
  # path (/api/ds/query) still connects (it honours the legacy field), but the browser
  # panel frontend short-circuits every query with "You do not currently have a default
  # database configured for this data source" and shows an error triangle on all panels.
  # Set database in BOTH places so panels actually render (kept legacy field for the
  # backend/older path; jsonData.database is the field the current UI requires).
  local payload=$(cat <<EOF
{"name":"$name","type":"postgres","access":"proxy","url":"crdb:26257","user":"$dbuser",
 "database":"$db","isDefault":$( [[ "$name" == "dcre-rpt" ]] && echo true || echo false ),
 "jsonData":{"database":"$db","sslmode":"disable","postgresVersion":1000,"timescaledb":false,"timeInterval":"30s","maxOpenConns":10},
 "secureJsonData":{"password":""}}
EOF
)
  if [[ -n "$existing" ]]; then
    curl -sf -u "$AUTH" -H "X-Grafana-Org-Id: $oid" -H 'Content-Type: application/json' \
      -X PUT "$G/api/datasources/uid/$existing" -d "$payload" > /dev/null
  else
    curl -sf -u "$AUTH" -H "X-Grafana-Org-Id: $oid" -H 'Content-Type: application/json' \
      -X POST "$G/api/datasources" -d "$payload" > /dev/null
  fi
}

typeset -A ORGS
for pair in "FNBCC01:fnbcc01" "FNBCC02:fnbcc02" "FNBRF01:fnbrf01" "FNB Internal:fnbinternal"; do
  name="${pair%%:*}"; login="${pair##*:}"
  oid=$(ensure_org "$name")
  ORGS[$name]=$oid
  ensure_user "$login" "$oid"
  case "$name" in
    "FNB Internal") ensure_ds "$oid" "dcre-rpt" "dcre_col" "rpt_internal"
                    ensure_ds "$oid" "dcre-ops" "agt_ops" "rpt_internal" ;;
    *)              ensure_ds "$oid" "dcre-rpt" "dcre_col" "${name:l}" ;;
  esac
  echo "org $name id=$oid provisioned"
done
echo "OK"

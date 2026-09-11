#!/usr/bin/env bash
# Proof that the DCRE observability dashboards arrived by FILE PROVISIONING and not
# through the HTTP API. Three halves, and each one covers a hole in the one before:
#
#   1. every dashboard reports meta.provisioned true, with provisionedExternalId naming
#      the mounted file it came from;
#   2. the Grafana log holds ZERO POSTs to /api/dashboards/db;
#   3. the panels Grafana actually SERVES match what the generator emits right now.
#
# Half 1 alone says a file provisioned it, never WHICH file: a stale ConfigMap or a
# `kubectl apply` nobody ran leaves provisioned=true beside the previous content. Half 3
# is what closes that.
#
# Half 2 is an ABSENCE, and an absence found by searching proves nothing until a control
# proves the search can find. So this script also requires at least one POST of some other
# kind in the same log, through the same matcher. Without that control the assertion is
# equally satisfied by a log that records no requests at all, which is exactly what this
# bundle does by default: run_with_logging discards Grafana's output unless
# ENABLE_LOGS_GRAFANA is true, and Grafana's router_logging defaults to false. Both are
# switched on in k8s/base/04-lgtm.yml for this reason.
#
# Bash, not zsh, and arrays throughout: ${PIPESTATUS[0]} is a bash spelling that expands
# to the EMPTY STRING in zsh, and an empty capture reads as success.
#
# Usage:  scripts/obs-provisioning-proof.sh [grafana-url]
# Default target is the port-forward on :3011, NOT the ambient GRAFANA_URL, which points
# at the compose LGTM and is a different Grafana.
set -uo pipefail

G="${1:-${DCRE_GRAFANA_URL:-http://localhost:3011}}"
AUTH="admin:admin"
NAMESPACE="dcre"
UIDS=(dcre-fleet-overview dcre-stage-jobs dcre-traces dcre-logs)
# Resolve the repository from THIS script's own location, never from the caller's cwd.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail=0
note() { printf '%s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

# ---------------------------------------------------------------------------- reachable
code=$(curl -s -o /dev/null -w '%{http_code}' "$G/api/health")
if [[ "$code" != "200" ]]; then
  printf 'REFUSED: %s/api/health answered %s, so nothing below is a measurement.\n' \
    "$G" "${code:-<empty>}" >&2
  exit 2
fi
note "Grafana at $G answered 200"

# ------------------------------------------------------------------- half 1: provisioned
note ""
note "HALF 1: every dashboard reports meta.provisioned true"
for uid in "${UIDS[@]}"; do
  body=$(curl -s -u "$AUTH" "$G/api/dashboards/uid/$uid")
  rc=$?
  if (( rc != 0 )); then
    bad "$uid: curl exited $rc"
    continue
  fi
  # Read the two fields with python so a missing key is an error rather than a silent
  # empty match, and so "provisioned" is compared to the literal true, never merely
  # to non-empty. Printing UNKNOWN on any parse failure keeps the default branch failing.
  read -r prov src panels <<<"$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    m, dash = d["meta"], d["dashboard"]
    print(m["provisioned"], m.get("provisionedExternalId") or "NONE", len(dash.get("panels", [])))
except Exception as e:
    print("UNKNOWN", "UNKNOWN", 0)
')"
  case "$prov" in
    True|true) : ;;
    *) bad "$uid: meta.provisioned is ${prov:-<empty>}, expected true"; continue ;;
  esac
  if [[ "$src" != "$uid.json" ]]; then
    bad "$uid: provisionedExternalId is $src, expected $uid.json"
    continue
  fi
  note "  OK  $uid  provisioned=$prov  from=$src  panels=$panels"
done

# --------------------------------------------------------- half 2: zero dashboard POSTs
note ""
note "HALF 2: the Grafana log holds zero POSTs to /api/dashboards/db"
pod=$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=lgtm \
        -o jsonpath='{.items[0].metadata.name}')
rc=$?
if (( rc != 0 )) || [[ -z "$pod" ]]; then
  bad "could not resolve the lgtm pod (kubectl exited $rc, pod='${pod}')"
else
  log=$(mktemp)
  kubectl -n "$NAMESPACE" logs "$pod" > "$log" 2>&1
  rc=$?
  if (( rc != 0 )); then
    bad "kubectl logs $pod exited $rc"
  else
    started=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.startTime}')
    lines=$(wc -l < "$log" | tr -d ' ')
    # Never `grep -c`: ugrep is grep on this machine and miscounts a file with no
    # trailing newline. awk counts what it matched.
    posts=$(awk '/method=POST/ {n++} END {print n+0}' "$log")
    dash_posts=$(awk '/method=POST/ && /\/api\/dashboards\/db/ {n++} END {print n+0}' "$log")
    note "  pod $pod started $started, $lines log lines"
    note "  POSTs of any kind (the positive control): $posts"
    note "  POSTs to /api/dashboards/db (the assertion): $dash_posts"
    if (( posts == 0 )); then
      bad "the control found no POST of any kind, so this log could not have recorded a" \
          "dashboard POST either and the zero above carries no information." \
          "Check ENABLE_LOGS_GRAFANA and GF_SERVER_ROUTER_LOGGING in k8s/base/04-lgtm.yml."
    fi
    if (( dash_posts != 0 )); then
      bad "$dash_posts POST(s) to /api/dashboards/db: these dashboards did not come from a file"
      awk '/method=POST/ && /\/api\/dashboards\/db/' "$log" | head -5 >&2
    fi
    note ""
    note "  UNIVERSE: this log begins at the pod's start ($started) and covers the whole"
    note "  life of the process that is serving these dashboards. It is not a claim about"
    note "  any earlier pod; it is the claim that THESE dashboards, in THIS process, were"
    note "  never posted."
  fi
  rm -f "$log"
fi

# ------------------------------------------- half 3: what is served IS what was generated
# provisioned=true says a FILE provisioned it. It does not say WHICH file, or that the
# file matches the generator: a stale ConfigMap, a volume that failed to update, or a
# `kubectl apply` nobody ran all leave provisioned=true beside the previous content, and
# every panel still renders. This half compares the served panel titles and target
# expressions against the ones this repository's generator emits right now.
note ""
note "HALF 3: the dashboards Grafana serves match the committed generator"
for uid in "${UIDS[@]}"; do
  # The served JSON goes to a FILE and the path is an argument. A heredoc-fed python
  # already owns stdin, so piping the response into it delivers nothing and every
  # dashboard reads as UNREADABLE: a harness failure that renders exactly like four
  # genuinely broken dashboards. Caught on this script's first run, 2026-09-11.
  served_file=$(mktemp)
  curl -s -u "$AUTH" "$G/api/dashboards/uid/$uid" > "$served_file"
  result=$(python3 - "$uid" "$served_file" "$REPO_ROOT" <<'PY'
import json, sys, pathlib
uid, served_path, root = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
try:
    served = json.loads(open(served_path).read())["dashboard"]
except Exception as e:
    print(f"UNREADABLE served dashboard: {e}"); sys.exit(0)

# Re-render from the generator in this working tree, never from the committed ConfigMap:
# the ConfigMap is itself an output, and comparing two outputs proves only that they agree.
sys.path.insert(0, str(root / "scripts"))
import importlib.util
spec = importlib.util.spec_from_file_location("gen", root / "scripts" / "obs-dashboards.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)
wanted = {d["uid"]: d for d in (gen.render_dashboard(b) for b in gen.DASHBOARDS)}.get(uid)
if wanted is None:
    print(f"the generator emits no dashboard with uid {uid}"); sys.exit(0)

def shape(d):
    return [(p["title"], tuple(t.get("expr") or t.get("query") or "" for t in p["targets"]))
            for p in d["panels"]]

a, b = shape(served), shape(wanted)
if a == b:
    print(f"MATCH {len(a)} panels")
else:
    diffs = [f"panel {i}: served={s!r} generated={g!r}"
             for i, (s, g) in enumerate(zip(a, b)) if s != g][:3]
    if len(a) != len(b):
        diffs.insert(0, f"panel count served={len(a)} generated={len(b)}")
    print("MISMATCH " + " | ".join(diffs))
PY
)
  rm -f "$served_file"
  case "$result" in
    MATCH*) note "  OK  $uid  $result" ;;
    *)      bad "$uid: served dashboard does not match the generator: $result" ;;
  esac
done

note ""
if (( fail == 0 )); then
  note "PROVISIONING PROOF: PASS (${#UIDS[@]} dashboards, provisioned from files, zero dashboard POSTs)"
else
  note "PROVISIONING PROOF: FAIL"
fi
exit "$fail"

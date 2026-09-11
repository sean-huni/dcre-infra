# Pausing and resuming the DCRE dev stack

Paused 2026-09-11 so another project could have the host ports. The state at that moment is in
`dcre-pause-state.txt` beside this file, recorded BEFORE the stop so a resume can be checked
against a measurement rather than against memory.

## What was done, and what was deliberately NOT done

The kind node container was STOPPED, not deleted:

```bash
docker stop dcre-dev-control-plane
```

`kind delete cluster --name dcre-dev` would have destroyed the cluster, every volume and the
`agt_ops` ledger, which at pause held 97,775 launch intents and 97,950 stage outcomes spanning
2026-08-07 to 2026-09-11. A stop keeps all of it. `kind get clusters` still lists `dcre-dev` and
`docker ps -a` still shows the node, Exited.

Three `kubectl port-forward` processes were also killed, on 3001, 4318 and 26257. Those were the
real port clash: every Service in the cluster is a ClusterIP and the node publishes only the API
server, on a random loopback port. **The forwards, not the cluster, were holding the interesting
ports.**

## Resume

```bash
docker start dcre-dev-control-plane
kubectl --context kind-dcre-dev wait --for=condition=Ready node --all --timeout=180s
kubectl --context kind-dcre-dev get pods -A
```

The orchestrator resumes launching clock windows on its own; nothing needs scaling back, because
nothing was scaled down. Restore the forwards only when something needs them:

```bash
kubectl --context kind-dcre-dev -n dcre port-forward deploy/lgtm 3001:3000 &
```

**Reclaim the port before forwarding.** A forward leaked by an earlier run points at a pod that has
since been replaced, so the new forward never binds, the checks read the dead pod, and a healthy
fleet reads as broken:

```bash
old=$(lsof -ti :3001); [ -n "$old" ] && kill $old
```

## Verify the resume against the recorded state

```bash
kubectl --context kind-dcre-dev get deploy -A          # match DECLARED in dcre-pause-state.txt
```

The three report tables must still read `type`, not `report_type`. That column was repaired on
2026-09-11 by a guarded rename, and it is the single cheapest check that the databases came back
as they went down:

```bash
for db in dcre_col dcre_man dcre_pay; do
  kubectl --context kind-dcre-dev -n dcre exec crdb-0 -- ./cockroach sql --insecure \
    --database=$db --format=tsv \
    -e "SELECT table_name||'.'||column_name FROM information_schema.columns
        WHERE table_name LIKE '%_report' AND column_name IN ('type','report_type')"
done
```

## Port hygiene, for whoever runs the next stack here

At pause, these host ports were free, checked with `lsof -nP -iTCP:<port> -sTCP:LISTEN` and a
control listener proving the instrument sees one when it exists: 3000, 3001, 3100, 3200, 4317,
4318, 5432, 8080, 8081, 8443, 9090, 9093, 26257, 26258.

**`lsof -ti :PORT` is the wrong instrument for this question.** It matches any socket touching the
port, including an OUTBOUND connection, so a dying client socket reads as a listener. That produced
a false "26257 still held" here. Ask for listeners explicitly.

Stopped containers reserve a port in their config and bind nothing while stopped, but they will
take it the moment somebody starts them. These were present at pause and belong to other projects:

| container | would bind |
| --- | --- |
| `tagmic-lgtm` | 3000, 4317, 4318 |
| `resume-crdb-local` | 26257, 18080 |
| `dcre-verify-crdb` | 26999 |
| `blissful_lovelace`, `adoring_robinson` | 55234, 55232 |

A `grafana/mcp-grafana` container is also running and is configured against the DCRE Grafana that
is now down. It publishes no host port, so it clashes with nothing, but any call through it will
fail until this stack is back.

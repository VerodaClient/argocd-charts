#!/usr/bin/env bash
# Verify the MCM tunnel chain end to end, and that the version knobs in git agree.
#
# WHY THIS EXISTS
#   Twice now the tunnel has died because a CE version change moved the Manager's
#   namespace / service names / tunnel secret name and something in this repo still
#   pointed at the old ones. Both times ArgoCD reported every app Synced and Healthy,
#   because the objects it applied were all valid, only the names inside them were
#   stale. Argo structurally cannot catch this. This script can.
#
# Run it after any CE version change, before concluding the tunnel is broken.
set -uo pipefail

MGMT="${MGMT_CTX:-leon@leon-mgmt-cluster.ca-central-1.eksctl.io}"
MNGD="${MNGD_CTX:-leon@leon-mngd-cluster.ca-central-1.eksctl.io}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAIL=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=1; }
note() { printf '        %s\n' "$1"; }

echo "== 1. the three version knobs in git must agree =="
CHART_V=$(awk '/name: tigera-operator/{f=1} f&&/version:/{print $2; exit}' \
  "$REPO/charts/calico-enterprise/Chart.yaml" | tr -d '"')
VALUES_V=$(awk '/^ce:/{f=1} f&&/version:/{print $2; exit}' \
  "$REPO/charts/calico-enterprise-configs/values.mgmt.yaml" | tr -d '"')
NGINX_T=$(awk '/9449:/{print $2; exit}' "$REPO/charts/ingress-nginx/values.mgmt.yaml")

note "Chart.yaml tigera-operator     = ${CHART_V:-<unset>}"
note "configs values.mgmt ce.version = ${VALUES_V:-<unset>}"
note "ingress-nginx 9449 target      = ${NGINX_T:-<unset>}"

if [ "$CHART_V" = "$VALUES_V" ]; then
  ok "chart pin and ce.version match"
else
  bad "chart pin ($CHART_V) != ce.version ($VALUES_V) -- every derived name is wrong"
fi

# Expected nginx target for this version, same rule as templates/_helpers.tpl.
MAJMIN=$(printf '%s' "${VALUES_V#v}" | cut -d. -f1,2)
if [ "$(printf '%s\n3.23\n' "$MAJMIN" | sort -V | head -1)" = "3.23" ]; then
  WANT="calico-system/calico-manager-mcm:9449"
else
  WANT="tigera-manager/tigera-manager-mcm:9449"
fi
if [ "$NGINX_T" = "$WANT" ]; then
  ok "ingress-nginx tcp target correct for $VALUES_V"
else
  bad "ingress-nginx tcp target is '$NGINX_T', should be '$WANT'"
fi

echo "== 2. what the live nginx is actually forwarding 9449 to =="
LIVE=$(kubectl --context="$MGMT" get cm -n ingress-nginx -o json 2>/dev/null \
  | python3 -c 'import json,sys
for i in json.load(sys.stdin)["items"]:
    if i["metadata"]["name"].endswith("-tcp"):
        print((i.get("data") or {}).get("9449",""))
        break' 2>/dev/null)
note "live configmap 9449 = ${LIVE:-<none>}"
if [ -z "$LIVE" ]; then
  bad "no live tcp configmap entry for 9449"
else
  NS=${LIVE%%/*}; rest=${LIVE#*/}; SVC=${rest%%:*}
  EPS=$(kubectl --context="$MGMT" get endpoints -n "$NS" "$SVC" \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  if [ -n "$EPS" ]; then
    ok "$NS/$SVC has endpoints ($EPS)"
  else
    bad "$NS/$SVC has NO endpoints -- this is the silent failure, nginx will accept the"
    note "connection with no backend and guardian will time out with no cert error"
  fi
fi

echo "== 3. Manager UI LoadBalancer has endpoints =="
for NS in tigera-manager calico-system; do
  if kubectl --context="$MGMT" get svc -n "$NS" tigera-manager-external >/dev/null 2>&1; then
    EPS=$(kubectl --context="$MGMT" get endpoints -n "$NS" tigera-manager-external \
          -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    if [ -n "$EPS" ]; then
      ok "$NS/tigera-manager-external -> $EPS"
    else
      SEL=$(kubectl --context="$MGMT" get svc -n "$NS" tigera-manager-external \
            -o jsonpath='{.spec.selector}' 2>/dev/null)
      bad "$NS/tigera-manager-external has no endpoints, selector=$SEL"
      note "a Service selector only matches pods in its OWN namespace"
    fi
  fi
done

echo "== 4. Voltron serving cert: does the CR point at the secret git supplies? =="
WANT_SECRET=$(kubectl --context="$MGMT" get managementcluster tigera-secure \
  -o jsonpath='{.spec.tls.secretName}' 2>/dev/null)
[ -z "$WANT_SECRET" ] && WANT_SECRET="calico-management-cluster-connection (CRD default)"
note "ManagementCluster.spec.tls.secretName = $WANT_SECRET"
for S in tigera-management-cluster-connection calico-management-cluster-connection; do
  FP=$(kubectl --context="$MGMT" get secret -n tigera-operator "$S" \
       -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null \
       | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | cut -c1-16)
  OWNER=$(kubectl --context="$MGMT" get secret -n tigera-operator "$S" \
          -o jsonpath='{.metadata.ownerReferences[*].kind}' 2>/dev/null)
  [ -n "$FP" ] && note "secret $S  fp=$FP  ownerRefs=${OWNER:-<none, so git-supplied>}"
done
case "$WANT_SECRET" in
  *"$( [ "$(printf '%s\n3.23\n' "$MAJMIN" | sort -V | head -1)" = "3.23" ] && echo calico- || echo tigera- )"*)
    ok "secretName matches the naming for $VALUES_V" ;;
  *) bad "secretName does not match the naming for $VALUES_V"
     note "an orphaned cert means the operator self-signs and guardian gets x509 errors" ;;
esac

echo "== 5. is the tunnel actually established? =="
# Authoritative signal, not the guardian restart count. Restarts are cumulative, so
# after a fix they stay high for the life of the pod and read as a false failure.
CONN=$(kubectl --context="$MGMT" get managedcluster my-managed-cluster \
  -o jsonpath='{range .status.conditions[?(@.type=="ManagedClusterConnected")]}{.status}{end}' 2>/dev/null)
if [ "$CONN" = "True" ]; then
  ok "ManagedClusterConnected=True"
else
  bad "ManagedClusterConnected=${CONN:-<unknown>}"
fi

# Pod detail is corroborating only. Note the label is k8s-app=guardian, NOT
# tigera-guardian, which is the container name.
kubectl --context="$MNGD" get pods -n calico-system -l k8s-app=guardian \
  -o jsonpath='        pod restarts={.items[0].status.containerStatuses[0].restartCount} ready={.items[0].status.containerStatuses[0].ready} since={.items[0].status.containerStatuses[0].state.running.startedAt}{"\n"}' 2>/dev/null
if [ "$CONN" != "True" ]; then
  kubectl --context="$MNGD" logs -n calico-system -l k8s-app=guardian \
    --tail=60 2>/dev/null | grep -iE "x509|FATAL|tunnel closed|dial" | tail -3 \
    | sed 's/^/        /'
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31mChecks failed -- fix the names above, they will NOT show up in Argo.\033[0m\n'
fi
exit "$FAIL"

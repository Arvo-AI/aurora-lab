#!/usr/bin/env bash
# The same three faults on the controllers people move to. Uses the r503 namespace
# from causes.yaml. Each block is independent; a failure does not stop the next.
set -uo pipefail
run() { echo "\$ $*"; eval "$*" 2>&1; echo; }
cx() { kubectl -n r503 exec curl -- "$@"; }
one() { # one <base> <path> [curl args]
  local b="$1" p="$2"; shift 2
  echo "### GET $p"; cx curl -si --max-time 10 "$@" "$b$p"; echo
}
routes() { # routes <gateway> <namespace-of-gateway>
cat <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: $1-app, namespace: r503}
spec:
  parentRefs: [{name: $1}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /app}}]
      backendRefs: [{name: backend, port: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: $1-limited, namespace: r503}
spec:
  parentRefs: [{name: $1}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /limited}}]
      backendRefs: [{name: backend, port: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: $1-scaled, namespace: r503}
spec:
  parentRefs: [{name: $1}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /scaled}}]
      backendRefs: [{name: scaled, port: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: $1-missing, namespace: r503}
spec:
  parentRefs: [{name: $1}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /missing}}]
      backendRefs: [{name: no-such-service, port: 8080}]
Y
}
burst() { cx sh -c "seq 1 30 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code}\n' $1 | sort | uniq -c"; }

echo "# $(date -u +%FT%TZ) Envoy Gateway"
EG=v1.9.3
run "helm install eg oci://docker.io/envoyproxy/gateway-helm --version $EG -n envoy-gateway-system --create-namespace --wait --timeout 5m | head -8"
run 'kubectl -n envoy-gateway-system wait --for=condition=Available deploy/envoy-gateway --timeout=180s'
kubectl apply -f - <<'Y'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata: {name: eg}
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: eg, namespace: r503}
spec:
  gatewayClassName: eg
  listeners:
    - {name: http, protocol: HTTP, port: 80}
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata: {name: limited, namespace: r503}
spec:
  targetRefs:
    - {group: gateway.networking.k8s.io, kind: HTTPRoute, name: eg-limited}
  rateLimit:
    type: Local
    local:
      rules:
        - limit: {requests: 5, unit: Second}
Y
routes eg | kubectl apply -f -
sleep 30
run 'kubectl -n envoy-gateway-system get pods,svc'
run 'kubectl -n r503 get gateway eg'
SVC="$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=eg -o jsonpath='{.items[0].metadata.name}')"
B="http://$SVC.envoy-gateway-system.svc"
for p in /app/ok /app/fail503 /scaled /missing; do one "$B" "$p"; done
echo "\$ 30 requests, 10 at a time, /limited/ok"; burst "$B/limited/ok"
one "$B" /limited/ok
sleep 2
POD="$(kubectl -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=eg -o name | head -1)"
run "kubectl -n envoy-gateway-system logs $POD -c envoy --tail=300 | grep -E '\"response_code\":(500|503)' | tail -4"
run "kubectl -n envoy-gateway-system logs $POD -c envoy --tail=300 | grep -E '\"response_code\":429' | tail -1"
kubectl -n envoy-gateway-system get "$POD" -o jsonpath='{.spec.containers[?(@.name=="envoy")].image}'; echo
helm list -n envoy-gateway-system

echo "# $(date -u +%FT%TZ) NGINX Gateway Fabric"
NGF=2.8.1
run "kubectl kustomize 'https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v$NGF' | kubectl apply --server-side --force-conflicts -f - | tail -3"
run "helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --version $NGF -n nginx-gateway --create-namespace --set nginx.service.type=ClusterIP --wait --timeout 5m | head -6"
kubectl apply -f - <<'Y'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: ngf, namespace: r503}
spec:
  gatewayClassName: nginx
  listeners:
    - {name: http, protocol: HTTP, port: 80}
---
apiVersion: gateway.nginx.org/v1alpha1
kind: RateLimitPolicy
metadata: {name: limited, namespace: r503}
spec:
  targetRefs:
    - {group: gateway.networking.k8s.io, kind: HTTPRoute, name: ngf-limited}
  rateLimit:
    local:
      rules:
        - {zoneSize: 10m, key: $binary_remote_addr, rate: 2r/s}
Y
routes ngf | kubectl apply -f -
sleep 30
run 'kubectl -n r503 get gateway ngf'
run 'kubectl -n r503 get pods,svc -l gateway.networking.k8s.io/gateway-name=ngf'
run 'kubectl -n r503 describe ratelimitpolicy limited | tail -14'
SVC="$(kubectl -n r503 get svc -l gateway.networking.k8s.io/gateway-name=ngf -o jsonpath='{.items[0].metadata.name}')"
B="http://$SVC.r503.svc"
for p in /app/ok /app/fail503 /scaled /missing; do one "$B" "$p"; done
echo "\$ 30 requests, 10 at a time, /limited/ok"; burst "$B/limited/ok"
one "$B" /limited/ok
sleep 2
POD="$(kubectl -n r503 get pods -l gateway.networking.k8s.io/gateway-name=ngf -o name | head -1)"
run "kubectl -n r503 logs $POD --tail=300 | grep -E 'GET|limiting' | tail -10"
kubectl -n r503 exec "$POD" -- nginx -v 2>&1
kubectl -n r503 get "$POD" -o jsonpath='{.spec.containers[0].image}'; echo
# free the shared port label for the next block; nothing else uses this
kubectl -n r503 delete gateway ngf --ignore-not-found >/dev/null

echo "# $(date -u +%FT%TZ) Traefik reading the same Ingress objects, with its ingress-nginx annotation provider"
run 'helm repo add traefik https://traefik.github.io/charts >/dev/null && helm repo update >/dev/null && helm search repo traefik/traefik | head -2'
run "helm install traefik traefik/traefik -n traefik --create-namespace --set providers.kubernetesIngress.enabled=false --set providers.kubernetesCRD.enabled=false --set providers.kubernetesIngressNGINX.enabled=true --set service.type=ClusterIP --set 'additionalArguments={--accesslog=true}' --wait --timeout 5m | head -6"
sleep 20
run 'kubectl -n traefik get pods,svc'
B=http://traefik.traefik.svc
for p in /app/ok /app/fail503 /scaled /badselector /missing /notready; do one "$B" "$p"; done
echo "\$ 30 requests, 10 at a time, /limited/ok (limit-rps 2 annotation, unchanged)"; burst "$B/limited/ok"
one "$B" /limited/ok
sleep 2
run "kubectl -n traefik logs deploy/traefik --tail=80 | grep -v -E '/limited' | tail -12"
run "kubectl -n traefik logs deploy/traefik --tail=80 | grep -E '/limited' | tail -2"
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
helm list -n traefik

echo "# $(date -u +%FT%TZ) F5 NGINX Ingress Controller, a different project from ingress-nginx"
run "helm install nic oci://ghcr.io/nginx/charts/nginx-ingress -n nic --create-namespace --set controller.service.type=ClusterIP --set controller.ingressClass.name=nic --wait --timeout 5m | head -6"
kubectl apply -f - <<'Y'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: nic-app, namespace: r503}
spec:
  ingressClassName: nic
  rules:
    - http:
        paths:
          - {path: /app, pathType: Prefix, backend: {service: {name: backend, port: {number: 8080}}}}
          - {path: /scaled, pathType: Prefix, backend: {service: {name: scaled, port: {number: 8080}}}}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nic-limited
  namespace: r503
  annotations:
    nginx.org/limit-req-rate: "2r/s"
spec:
  ingressClassName: nic
  rules:
    - http:
        paths:
          - {path: /limited, pathType: Prefix, backend: {service: {name: backend, port: {number: 8080}}}}
Y
sleep 20
run 'kubectl -n nic get pods,svc'
run 'kubectl -n r503 describe ingress nic-limited | tail -6'
SVC="$(kubectl -n nic get svc -o jsonpath='{.items[0].metadata.name}')"
B="http://$SVC.nic.svc"
for p in /app/ok /app/fail503 /scaled; do one "$B" "$p"; done
echo "\$ 30 requests, 10 at a time, /limited/ok"; burst "$B/limited/ok"
one "$B" /limited/ok
sleep 2
run "kubectl -n nic logs deploy/\$(kubectl -n nic get deploy -o jsonpath='{.items[0].metadata.name}') --tail=60 | grep -E '/scaled|limiting|/limited|fail503' | tail -8"
kubectl -n nic get deploy -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'; echo
helm list -n nic

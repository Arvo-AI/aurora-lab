# Installs ingress-nginx (once; reset leaves it in place) and routes /items to the
# api Service. A change moves the api's readiness probe to /items, which pings
# redis. Then redis goes away, standing in for a redis outage. Both api pods fail
# readiness and leave the Service, though neither pod has crashed. The controller
# has no upstream left, so it answers 503 itself.
node="$(kubectl get nodes -o name | grep worker | head -1)"
kubectl label "$node" ingress-ready=true --overwrite
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
# the validating webhook answers a little after the controller is Ready
for _ in $(seq 1 30); do
  kubectl apply -f - <<'Y' && break
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: shop, namespace: shop}
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /items
            pathType: Prefix
            backend:
              service: {name: api, port: {number: 8080}}
Y
  sleep 3
done
kubectl -n shop patch deploy api --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/items"}]'
kubectl -n shop rollout status deploy/api --timeout=120s
kubectl -n shop scale deploy/redis --replicas=0

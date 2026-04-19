#!/bin/sh
set -e

# Validate required variables before starting nginx
: "${API_GATEWAY_URL:?API_GATEWAY_URL must be set (e.g. http://api-gateway:3000 for Docker, http://api-gateway.swiftpay.svc.cluster.local:80 for K8s)}"
: "${NGINX_RESOLVER:?NGINX_RESOLVER must be set — must be an IP address (127.0.0.11 for Docker Compose; kube-dns ClusterIP for K8s, e.g. 10.152.183.10 for MicroK8s)}"

# Substitute both variables in the nginx config template.
# Both are needed: API_GATEWAY_URL for the upstream address,
# NGINX_RESOLVER for the DNS server used to resolve it at request time.
envsubst '${API_GATEWAY_URL} ${NGINX_RESOLVER}' \
  < /etc/nginx/conf.d/default.conf.template \
  > /etc/nginx/conf.d/default.conf

# Start nginx
exec nginx -g 'daemon off;'


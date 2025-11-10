Install the envoy gateway api

helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.5.4 -n envoy-gateway-system --create-namespace

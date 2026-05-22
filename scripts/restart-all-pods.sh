#!/bin/bash
# Restart all deployments and daemonsets across all namespaces.
# Use after CNI migrations or other cluster-wide changes.
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  kubectl rollout restart deployment -n $ns 2>/dev/null
  kubectl rollout restart daemonset -n $ns 2>/dev/null
done

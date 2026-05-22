#!/bin/bash
set -euo pipefail

echo "Deleting gitlab-demo namespace resources"
kubectl delete namespace gitlab-demo --ignore-not-found=true

echo "Deleting static PV"
kubectl delete pv gitlab-demo-data-pv --ignore-not-found=true

echo "Cleanup complete"

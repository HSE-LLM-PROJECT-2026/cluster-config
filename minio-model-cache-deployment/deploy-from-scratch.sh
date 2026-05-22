#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
NAMESPACE="${NAMESPACE:-hse-llm-project}"

MINIO_NAME="${MINIO_NAME:-minio-model-cache}"
MINIO_SERVICE_NAME="${MINIO_SERVICE_NAME:-minio-model-cache}"
MINIO_SECRET_NAME="${MINIO_SECRET_NAME:-minio-model-cache-credentials}"
MINIO_ACCESS_KEY_KEY="${MINIO_ACCESS_KEY_KEY:-accesskey}"
MINIO_SECRET_KEY_KEY="${MINIO_SECRET_KEY_KEY:-secretkey}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-adminadmin}"
MINIO_ROTATE_CREDENTIALS="${MINIO_ROTATE_CREDENTIALS:-false}"

MINIO_BUCKET="${MINIO_BUCKET:-llm-model-cache}"
MINIO_BUCKET_PREFIX="${MINIO_BUCKET_PREFIX:-hf-cache}"

MINIO_IMAGE="${MINIO_IMAGE:-quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z}"
MINIO_MC_IMAGE="${MINIO_MC_IMAGE:-quay.io/minio/mc:RELEASE.2025-04-16T18-13-26Z}"

MINIO_STORAGE_SIZE="${MINIO_STORAGE_SIZE:-250Gi}"
MINIO_STORAGE_CLASS="${MINIO_STORAGE_CLASS:-}"
MINIO_PV_NAME="${MINIO_PV_NAME:-minio-model-cache}"
MINIO_PV_HOST_PATH="${MINIO_PV_HOST_PATH:-/var/lib/minio-model-cache}"
MINIO_PV_NODE_NAME="${MINIO_PV_NODE_NAME:-gpu-worker-v100}"

MINIO_SYNC_SOURCE_PVC="${MINIO_SYNC_SOURCE_PVC:-vllm-model-cache}"
MINIO_SYNC_CRON_ENABLED="${MINIO_SYNC_CRON_ENABLED:-true}"
MINIO_SYNC_CRON_SCHEDULE="${MINIO_SYNC_CRON_SCHEDULE:-*/20 * * * *}"
MINIO_CONSOLE_ROUTE_NAME="${MINIO_CONSOLE_ROUTE_NAME:-minio-console-route}"
MINIO_CONSOLE_INTERNAL_HOST="${MINIO_CONSOLE_INTERNAL_HOST:-minio.hse-llm.internal}"
MINIO_CONSOLE_PUBLIC_HOST="${MINIO_CONSOLE_PUBLIC_HOST:-minio.hse-llm-project-2026.ru}"
MINIO_GATEWAY_NAME="${MINIO_GATEWAY_NAME:-web-gateway}"
MINIO_GATEWAY_NAMESPACE="${MINIO_GATEWAY_NAMESPACE:-$NAMESPACE}"
MINIO_CONSOLE_SERVICE_PORT="${MINIO_CONSOLE_SERVICE_PORT:-9001}"

CORE_MANIFEST="/tmp/minio-model-cache-core.yaml"
INIT_JOB_MANIFEST="/tmp/minio-model-cache-init-job.yaml"
SYNC_JOB_MANIFEST="/tmp/minio-model-cache-sync-job.yaml"
SYNC_CRON_MANIFEST="/tmp/minio-model-cache-sync-cron.yaml"
HTTPROUTE_MANIFEST="/tmp/minio-model-cache-httproute.yaml"

log() {
  echo "[minio-model-cache] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[minio-model-cache] ERROR: command not found: $1" >&2
    exit 1
  }
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

need_cmd kubectl
[[ -f "$KUBECONFIG_PATH" ]] || {
  echo "[minio-model-cache] ERROR: kubeconfig not found: $KUBECONFIG_PATH" >&2
  exit 1
}

export KUBECONFIG="$KUBECONFIG_PATH"

log "Namespace: $NAMESPACE"
log "MinIO service: $MINIO_SERVICE_NAME"
log "Bucket: $MINIO_BUCKET"
log "Bucket prefix: $MINIO_BUCKET_PREFIX"
log "Sync source PVC: $MINIO_SYNC_SOURCE_PVC"

kubectl create ns "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n "$NAMESPACE" get secret "$MINIO_SECRET_NAME" >/dev/null 2>&1 && ! is_true "$MINIO_ROTATE_CREDENTIALS"; then
  log "Secret ${MINIO_SECRET_NAME} already exists; keeping current credentials (MINIO_ROTATE_CREDENTIALS=false)."
else
  kubectl -n "$NAMESPACE" create secret generic "$MINIO_SECRET_NAME" \
    --from-literal="$MINIO_ACCESS_KEY_KEY=$MINIO_ROOT_USER" \
    --from-literal="$MINIO_SECRET_KEY_KEY=$MINIO_ROOT_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

if [[ -n "$MINIO_STORAGE_CLASS" ]]; then
  cat > "$CORE_MANIFEST" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${MINIO_NAME}-data
  namespace: ${NAMESPACE}
spec:
  storageClassName: ${MINIO_STORAGE_CLASS}
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${MINIO_STORAGE_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${MINIO_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${MINIO_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${MINIO_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${MINIO_NAME}
    spec:
      containers:
        - name: minio
          image: ${MINIO_IMAGE}
          imagePullPolicy: IfNotPresent
          args:
            - server
            - /data
            - --console-address
            - :9001
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET_NAME}
                  key: ${MINIO_ACCESS_KEY_KEY}
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET_NAME}
                  key: ${MINIO_SECRET_KEY_KEY}
          ports:
            - containerPort: 9000
              name: s3
            - containerPort: 9001
              name: console
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /minio/health/live
              port: 9000
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${MINIO_NAME}-data
---
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${MINIO_NAME}
spec:
  selector:
    app.kubernetes.io/name: ${MINIO_NAME}
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
EOF
else
  cat > "$CORE_MANIFEST" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${MINIO_PV_NAME}
spec:
  capacity:
    storage: ${MINIO_STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: ${MINIO_PV_HOST_PATH}
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${MINIO_PV_NODE_NAME}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${MINIO_NAME}-data
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${MINIO_STORAGE_SIZE}
  storageClassName: ""
  volumeName: ${MINIO_PV_NAME}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${MINIO_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${MINIO_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${MINIO_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${MINIO_NAME}
    spec:
      containers:
        - name: minio
          image: ${MINIO_IMAGE}
          imagePullPolicy: IfNotPresent
          args:
            - server
            - /data
            - --console-address
            - :9001
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET_NAME}
                  key: ${MINIO_ACCESS_KEY_KEY}
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET_NAME}
                  key: ${MINIO_SECRET_KEY_KEY}
          ports:
            - containerPort: 9000
              name: s3
            - containerPort: 9001
              name: console
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /minio/health/live
              port: 9000
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${MINIO_NAME}-data
---
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${MINIO_NAME}
spec:
  selector:
    app.kubernetes.io/name: ${MINIO_NAME}
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
EOF
fi

kubectl apply -f "$CORE_MANIFEST"
kubectl rollout status deployment/"$MINIO_NAME" -n "$NAMESPACE" --timeout=300s

cat > "$INIT_JOB_MANIFEST" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${MINIO_NAME}-bucket-init
  namespace: ${NAMESPACE}
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: ${MINIO_MC_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              mc alias set cache http://${MINIO_SERVICE_NAME}:9000 "\$MINIO_ACCESS_KEY" "\$MINIO_SECRET_KEY"
              mc mb --ignore-existing cache/${MINIO_BUCKET}
              mc anonymous set private cache/${MINIO_BUCKET} || true
          env:
            - name: MINIO_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET_NAME}
                  key: ${MINIO_ACCESS_KEY_KEY}
            - name: MINIO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET_NAME}
                  key: ${MINIO_SECRET_KEY_KEY}
EOF

kubectl -n "$NAMESPACE" delete job "${MINIO_NAME}-bucket-init" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f "$INIT_JOB_MANIFEST"
if ! kubectl wait --for=condition=complete --timeout=180s -n "$NAMESPACE" job/"${MINIO_NAME}-bucket-init"; then
  log "Bucket-init job did not complete in time. MinIO may still be usable if bucket already exists."
fi

cat > "$SYNC_JOB_MANIFEST" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${MINIO_NAME}-sync-once
  namespace: ${NAMESPACE}
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: ${MINIO_MC_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              mc alias set cache http://${MINIO_SERVICE_NAME}:9000 "\$MINIO_ACCESS_KEY" "\$MINIO_SECRET_KEY"
              mc mb --ignore-existing cache/${MINIO_BUCKET}
              mc mirror --overwrite /source-cache "cache/${MINIO_BUCKET}/${MINIO_BUCKET_PREFIX}/_global"
          env:
            - name: MINIO_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET_NAME}
                  key: ${MINIO_ACCESS_KEY_KEY}
            - name: MINIO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SECRET_NAME}
                  key: ${MINIO_SECRET_KEY_KEY}
          volumeMounts:
            - name: source-cache
              mountPath: /source-cache
      volumes:
        - name: source-cache
          persistentVolumeClaim:
            claimName: ${MINIO_SYNC_SOURCE_PVC}
EOF

kubectl -n "$NAMESPACE" delete job "${MINIO_NAME}-sync-once" --ignore-not-found >/dev/null 2>&1 || true
if kubectl -n "$NAMESPACE" get pvc "$MINIO_SYNC_SOURCE_PVC" >/dev/null 2>&1; then
  kubectl apply -f "$SYNC_JOB_MANIFEST"
  kubectl wait --for=condition=complete --timeout=180s -n "$NAMESPACE" job/"${MINIO_NAME}-sync-once" || {
    log "One-time sync job did not complete in time. Inspect job logs if needed."
  }
else
  log "PVC ${MINIO_SYNC_SOURCE_PVC} not found. Skipping one-time sync."
fi

cat > "$SYNC_CRON_MANIFEST" <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${MINIO_NAME}-sync
  namespace: ${NAMESPACE}
spec:
  schedule: "${MINIO_SYNC_CRON_SCHEDULE}"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: mc
              image: ${MINIO_MC_IMAGE}
              imagePullPolicy: IfNotPresent
              command:
                - /bin/sh
                - -c
                - |
                  set -eu
                  mc alias set cache http://${MINIO_SERVICE_NAME}:9000 "\$MINIO_ACCESS_KEY" "\$MINIO_SECRET_KEY"
                  mc mb --ignore-existing cache/${MINIO_BUCKET}
                  mc mirror --overwrite /source-cache "cache/${MINIO_BUCKET}/${MINIO_BUCKET_PREFIX}/_global"
              env:
                - name: MINIO_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: ${MINIO_SECRET_NAME}
                      key: ${MINIO_ACCESS_KEY_KEY}
                - name: MINIO_SECRET_KEY
                  valueFrom:
                    secretKeyRef:
                      name: ${MINIO_SECRET_NAME}
                      key: ${MINIO_SECRET_KEY_KEY}
              volumeMounts:
                - name: source-cache
                  mountPath: /source-cache
          volumes:
            - name: source-cache
              persistentVolumeClaim:
                claimName: ${MINIO_SYNC_SOURCE_PVC}
EOF

if is_true "$MINIO_SYNC_CRON_ENABLED"; then
  if kubectl -n "$NAMESPACE" get pvc "$MINIO_SYNC_SOURCE_PVC" >/dev/null 2>&1; then
    kubectl apply -f "$SYNC_CRON_MANIFEST"
  else
    log "PVC ${MINIO_SYNC_SOURCE_PVC} not found. Skipping sync CronJob."
  fi
else
  kubectl -n "$NAMESPACE" delete cronjob "${MINIO_NAME}-sync" --ignore-not-found >/dev/null 2>&1 || true
fi

cat > "$HTTPROUTE_MANIFEST" <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${MINIO_CONSOLE_ROUTE_NAME}
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: ${MINIO_GATEWAY_NAME}
      namespace: ${MINIO_GATEWAY_NAMESPACE}
  hostnames:
    - ${MINIO_CONSOLE_INTERNAL_HOST}
    - ${MINIO_CONSOLE_PUBLIC_HOST}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: ${MINIO_SERVICE_NAME}
          port: ${MINIO_CONSOLE_SERVICE_PORT}
EOF
kubectl apply -f "$HTTPROUTE_MANIFEST"

log "MinIO S3 model cache deployment completed."
log "Controller settings to enable prefetch:"
log "  MINIO_MODEL_CACHE_ENABLED=true"
log "  MINIO_MODEL_CACHE_ENDPOINT=${MINIO_SERVICE_NAME}:9000"
log "  MINIO_MODEL_CACHE_BUCKET=${MINIO_BUCKET}"
log "  MINIO_MODEL_CACHE_PREFIX=${MINIO_BUCKET_PREFIX}"
log "  MINIO_MODEL_CACHE_ACCESS_KEY_SECRET_NAME=${MINIO_SECRET_NAME}"
log "  MINIO_MODEL_CACHE_SECRET_KEY_SECRET_NAME=${MINIO_SECRET_NAME}"
log "MinIO Console hostname(s):"
log "  ${MINIO_CONSOLE_INTERNAL_HOST}"
log "  ${MINIO_CONSOLE_PUBLIC_HOST}"

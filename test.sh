#!/bin/bash
set -euo pipefail

export KUBECONFIG=~/.kube/okd

for i in $(seq 1 20); do
  echo "=== Iteration $i ==="
  kubectl rollout restart statefulset/thanos-compactor-ceph -n prometheus
  sleep 20

  # Wait for pod to crash or stabilize
  for j in $(seq 1 12); do
    STATUS=$(kubectl get pod -n prometheus -l app=thanos-compactor-ceph -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    READY=$(kubectl get pod -n prometheus -l app=thanos-compactor-ceph -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
    RESTARTS=$(kubectl get pod -n prometheus -l app=thanos-compactor-ceph -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    echo "  check $j: phase=$STATUS ready=$READY restarts=$RESTARTS"
    if [[ "$READY" == "false" && "$RESTARTS" -ge 1 ]] || [[ "$STATUS" == "Failed" ]]; then
      break
    fi
    sleep 10
  done

  # Extract bad block ID from logs
  BLOCK_ID=$(kubectl logs -n prometheus statefulset/thanos-compactor-ceph --tail=5 2>&1 | grep -oP 'downsample block \K[A-Z0-9]+' | head -1 || true)

  if [[ -z "$BLOCK_ID" ]]; then
    echo "  No corrupted block found — compactor may be running clean!"
    break
  fi

  echo "  Found corrupted block: $BLOCK_ID"
  POD_SUFFIX=$(echo "$BLOCK_ID" | tr '[:upper:]' '[:lower:]')

  # Mark in ceph
  kubectl run -n prometheus "mark-ceph-${POD_SUFFIX}" --rm -it --restart=Never \
    --image=quay.io/thanos/thanos:v0.41.0 \
    --overrides='{
      "spec": {
        "containers": [{
          "name": "mark",
          "image": "quay.io/thanos/thanos:v0.41.0",
          "command": ["thanos","tools","bucket","mark",
            "--objstore.config-file=/etc/secret/ceph.yaml",
            "--id='"$BLOCK_ID"'",
            "--marker=deletion-mark.json",
            "--details=checksum mismatch auto-detected"],
          "volumeMounts": [{"name":"secret","mountPath":"/etc/secret","readOnly":true}]
        }],
        "volumes": [{"name":"secret","secret":{"secretName":"ceph"}}]
      }
    }' 2>&1 | grep -E "marked|error"

  # Mark in nas
  kubectl run -n prometheus "mark-nas-${POD_SUFFIX}" --rm -it --restart=Never \
    --image=quay.io/thanos/thanos:v0.41.0 \
    --overrides='{
      "spec": {
        "containers": [{
          "name": "mark",
          "image": "quay.io/thanos/thanos:v0.41.0",
          "command": ["thanos","tools","bucket","mark",
            "--objstore.config-file=/etc/secret/nas.yaml",
            "--id='"$BLOCK_ID"'",
            "--marker=deletion-mark.json",
            "--details=checksum mismatch auto-detected"],
          "volumeMounts": [{"name":"secret","mountPath":"/etc/secret","readOnly":true}]
        }],
        "volumes": [{"name":"secret","secret":{"secretName":"nas"}}]
      }
    }' 2>&1 | grep -E "marked|error"

  echo "  Marked $BLOCK_ID for deletion in both stores"
  echo ""
done

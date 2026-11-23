#!/bin/bash
set -u
D=/root/hv-test-20261124
mkdir -p "$D"
K="ssh -i /root/.ssh/cubestack_k8s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/cubestack_known_hosts"
NS=hami-demo
kubectl create ns "$NS" 2>/dev/null || true
kubectl -n "$NS" create configmap b2c-bench --from-file="$D/bench.py" --dry-run=client -o yaml | kubectl apply -f -

echo "===== apply 7 blockers on worker02 =====" | tee "$D/B2C-blockers.txt"
kubectl apply -f "$D/b2c-blockers.yaml" 2>&1 | tee -a "$D/B2C-blockers.txt"
for i in $(seq 0 6); do
  kubectl -n "$NS" wait --for=condition=Ready "pod/b2c-blocker-$i" --timeout=240s 2>&1 | tail -1
done | tee -a "$D/B2C-blockers.txt"
kubectl -n "$NS" get pods -l exp=b2c,role=blocker -o wide 2>&1 | tee -a "$D/B2C-blockers.txt"
kubectl -n "$NS" get pods -l exp=b2c,role=blocker -o json > "$D/B2C-blockers-pods.json" 2>&1
echo "--- blocker placement ---" | tee -a "$D/B2C-blockers.txt"
kubectl -n "$NS" get pods -l exp=b2c,role=blocker -o json | jq -r '.items[] | "\(.metadata.name)\t\(.spec.nodeName)\t\(.metadata.annotations["metax-tech.com/gpu-allocated-status"] // "-")"' | sort | tee -a "$D/B2C-blockers.txt"

run_group() {
  local tag="$1" n="$2"
  echo "===== B2C group $tag (${n}x25%) =====" | tee "$D/B2C-$tag-summary.txt"
  kubectl apply -f "$D/b2c-$tag.yaml" 2>&1 | tee -a "$D/B2C-$tag-summary.txt"
  for i in $(seq 0 $((n-1))); do
    for j in $(seq 1 180); do
      phase=$(kubectl -n "$NS" get pod "b2c-$tag-$i" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      [ "$phase" = "Running" ] && break
      sleep 1
    done
  done
  kubectl -n "$NS" get pods -l "exp=b2c,group=$tag" -o wide 2>&1 | tee -a "$D/B2C-$tag-summary.txt"
  kubectl -n "$NS" get pods -l "exp=b2c,group=$tag" -o json > "$D/B2C-$tag-pods.json" 2>&1
  echo "--- placement ---" | tee -a "$D/B2C-$tag-summary.txt"
  kubectl -n "$NS" get pods -l "exp=b2c,group=$tag" -o json | jq -r '.items[] | "\(.metadata.name)\t\(.spec.nodeName)\t\(.metadata.annotations["metax-tech.com/gpu-allocated-status"] // "-")"' | sort | tee -a "$D/B2C-$tag-placement.txt"

  # 采样整卡 GPU 使用率（worker02）
  ( for i in $(seq 1 80); do $K ubuntu@10.66.3.40 "mx-smi --show-usage" 2>/dev/null; sleep 1; done > "$D/B2C-$tag-usage.txt" ) &
  spid=$!

  for i in $(seq 0 $((n-1))); do
    for j in $(seq 1 180); do
      phase=$(kubectl -n "$NS" get pod "b2c-$tag-$i" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      [ "$phase" = "Succeeded" ] && break
      [ "$phase" = "Failed" ] && break
      sleep 1
    done
  done
  wait "$spid" 2>/dev/null || true

  echo "--- results ---" | tee -a "$D/B2C-$tag-summary.txt"
  for i in $(seq 0 $((n-1))); do
    echo "--- b2c-$tag-$i" | tee -a "$D/B2C-$tag-summary.txt"
    kubectl -n "$NS" logs "b2c-$tag-$i" 2>&1 | tail -5 | tee -a "$D/B2C-$tag-summary.txt"
  done
  kubectl -n "$NS" delete pod -l "exp=b2c,group=$tag" --wait=true --timeout=180s 2>&1 | tee -a "$D/B2C-$tag-summary.txt"
  for j in $(seq 1 60); do
    [ -z "$(kubectl -n "$NS" get pods -l "exp=b2c,group=$tag" -o name 2>/dev/null)" ] && break
    sleep 2
  done
}

run_group 2x 2
run_group 4x 4

echo "===== cleanup blockers =====" | tee "$D/B2C-cleanup.txt"
kubectl -n "$NS" delete pod -l exp=b2c,role=blocker --wait=true --timeout=180s 2>&1 | tee -a "$D/B2C-cleanup.txt"
kubectl delete ns "$NS" --wait=true --timeout=180s 2>&1 | tee -a "$D/B2C-cleanup.txt"
$K ubuntu@10.66.3.40 "date; mx-smi" > "$D/B2C-mx-smi-after-cleanup.txt" 2>&1
echo "worker02 sliced rows: $(grep -cE "^\| [0-9]{3} +[0-9]+ +[0-9]+ +[0-9]+%" "$D/B2C-mx-smi-after-cleanup.txt")" | tee -a "$D/B2C-cleanup.txt"

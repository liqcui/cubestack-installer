#!/bin/bash
set -u
D=/root/hv-test-20261124
mkdir -p "$D"
NS=hami-demo
kubectl create ns "$NS" 2>/dev/null || true

run_group() {
  local grp="$1" file="$2"
  echo "===== B3 group $grp ($file) =====" | tee "$D/B3-$grp-summary.txt"
  kubectl apply -f "$file" 2>&1 | tee -a "$D/B3-$grp-summary.txt"
  for i in $(seq 0 7); do
    kubectl -n "$NS" wait --for=condition=Ready "pod/b3-$grp-$i" --timeout=240s 2>&1 | tail -1
  done | tee -a "$D/B3-$grp-summary.txt"
  kubectl -n "$NS" get pods -l "exp=b3,grp=$grp" -o wide 2>&1 | tee -a "$D/B3-$grp-summary.txt"
  kubectl -n "$NS" get pods -l "exp=b3,grp=$grp" -o json > "$D/B3-$grp-pods.json" 2>&1
  kubectl -n "$NS" get pods -l "exp=b3,grp=$grp" -o json | jq -r '.items[] | "\(.metadata.labels.grp)\t\(.metadata.name)\t\(.spec.nodeName)\t\(.metadata.annotations["metax-tech.com/gpu-allocated-status"] // "-")"' | sort > "$D/B3-$grp-placement.txt"
  echo "--- placement ---" | tee -a "$D/B3-$grp-summary.txt"
  cat "$D/B3-$grp-placement.txt" | tee -a "$D/B3-$grp-summary.txt"
  kubectl -n kube-system logs deploy/hami-scheduler -c vgpu-scheduler-extender --since=10m 2>&1 | grep -E "b3-$grp|NodeFitPod|NodeUnfitPod|policy" | tail -120 > "$D/B3-$grp-extender.txt"
  kubectl -n "$NS" delete pod -l "exp=b3,grp=$grp" --wait=true --timeout=240s 2>&1 | tee -a "$D/B3-$grp-summary.txt"
  for i in $(seq 1 60); do
    [ -z "$(kubectl -n "$NS" get pods -l "exp=b3,grp=$grp" -o name 2>/dev/null)" ] && break
    sleep 2
  done
}

run_group a /root/hv-test-20261124/b3-8pods-annot-spread.yaml
run_group b /root/hv-test-20261124/b3-8pods-annot-binpack.yaml
run_group c /root/hv-test-20261124/b3-8pods-noannot.yaml
kubectl delete ns "$NS" --wait=true --timeout=180s 2>&1 | tee "$D/B3-cleanup.txt"

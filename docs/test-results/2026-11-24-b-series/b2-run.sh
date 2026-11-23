#!/bin/bash
set -u
D=/root/hv-test-20261124
mkdir -p "$D"
K="ssh -i /root/.ssh/cubestack_k8s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/cubestack_known_hosts"
NS=hami-demo
kubectl create ns "$NS" 2>/dev/null || true
kubectl -n "$NS" create configmap b2-bench --from-file="$D/bench.py" --dry-run=client -o yaml | kubectl apply -f -

for v in 25 50 75 100; do
  name="b2-vc$v"
  sed -e "s/NAME/$name/" -e "s/VCORE/$v/" "$D/b2-job-template.yaml" > "/tmp/$name.yaml"
  echo "===== $name =====" | tee "$D/B2-$name-result.txt"
  kubectl apply -f "/tmp/$name.yaml" 2>&1 | tee -a "$D/B2-$name-result.txt"
  pod=""
  for i in $(seq 1 180); do
    pod=$(kubectl -n "$NS" get pod -l "job-name=$name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "$pod" ] && [ "$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
    sleep 1
  done
  if [ -z "$pod" ]; then
    echo "POD_NOT_RUNNING" | tee -a "$D/B2-$name-result.txt"
    kubectl -n "$NS" get jobs,pods -o wide 2>&1 | tee -a "$D/B2-$name-result.txt"
    kubectl -n "$NS" delete job "$name" --wait=false 2>/dev/null || true
    continue
  fi
  node=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.nodeName}')
  node_ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  echo "pod=$pod node=$node ip=$node_ip" | tee -a "$D/B2-$name-result.txt"
  kubectl -n "$NS" get pod "$pod" -o json > "$D/B2-$name-pod.json" 2>&1

  ( for i in $(seq 1 80); do $K ubuntu@"$node_ip" "mx-smi --show-usage" 2>/dev/null; sleep 1; done > "$D/B2-$name-usage.txt" ) &
  spid=$!

  set +e
  kubectl -n "$NS" wait --for=condition=complete "job/$name" --timeout=240s 2>&1 | tee -a "$D/B2-$name-result.txt"
  rc=$?
  echo "WAIT_RC=$rc" >> "$D/B2-$name-result.txt"
  kubectl -n "$NS" logs "job/$name" --tail=20 2>&1 | tee -a "$D/B2-$name-result.txt"
  set -e
  wait "$spid" 2>/dev/null || true
  $K ubuntu@"$node_ip" "mx-smi" > "$D/B2-$name-mx-smi.txt" 2>&1
  kubectl -n "$NS" delete job "$name" --wait=true --timeout=180s 2>&1 | tee -a "$D/B2-$name-result.txt"
done
kubectl delete ns "$NS" --wait=true --timeout=180s 2>&1 | tee "$D/B2-cleanup.txt"

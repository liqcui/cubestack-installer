#!/bin/bash
set -u
D=/root/hv-test-20261123/iso
mkdir -p "$D"
K="ssh -i /root/.ssh/cubestack_k8s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/cubestack_known_hosts"
NS=hami-demo
P=iso-mem-over

kubectl apply -f /root/hv-test-20261123/iso-mem-over.yaml > "$D/mem-over-apply.txt" 2>&1
kubectl -n "$NS" wait --for=condition=Ready pod/"$P" --timeout=300s > "$D/mem-over-wait.txt" 2>&1
kubectl -n "$NS" get pod "$P" -o wide > "$D/mem-over-pod.txt" 2>&1
kubectl -n "$NS" get pod "$P" -o json > "$D/mem-over-pod.json" 2>&1
NODE=$(kubectl -n "$NS" get pod "$P" -o jsonpath='{.spec.nodeName}')
echo "node=$NODE" >> "$D/mem-over-pod.txt"

# Start a 10GiB allocation (quota is 8GiB) in the background
kubectl -n "$NS" exec "$P" -- python3 -c 'import torch, time; print("cuda", torch.cuda.is_available(), flush=True); a=torch.empty(10 * 1024**3 // 4, dtype=torch.float32, device="cuda"); print("allocated_bytes", a.numel() * 4, flush=True); time.sleep(30)' > "$D/mem-over-run.txt" 2>&1 &
PID=$!
sleep 12
# Capture host view while allocation is active (if it succeeded)
NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
$K ubuntu@"$NODE_IP" "date; mx-smi" > "$D/mem-over-host-mx-smi.txt" 2>&1
wait "$PID"
echo "rc=$?" >> "$D/mem-over-run.txt"
kubectl -n "$NS" get pod "$P" -o wide > "$D/mem-over-pod-after.txt" 2>&1

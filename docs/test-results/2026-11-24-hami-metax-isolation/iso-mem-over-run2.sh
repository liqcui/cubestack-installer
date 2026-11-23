#!/bin/bash
set -u
D=/root/hv-test-20261123/iso
K="ssh -i /root/.ssh/cubestack_k8s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/cubestack_known_hosts"
NS=hami-demo
P=iso-mem-over
NODE=$(kubectl -n "$NS" get pod "$P" -o jsonpath='{.spec.nodeName}')
NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "node=$NODE ip=$NODE_IP" > "$D/mem-over-run2-meta.txt"

kubectl -n "$NS" exec "$P" -- /opt/conda/bin/python3.12 -c 'import torch, time; print("cuda", torch.cuda.is_available(), flush=True); print("device", torch.cuda.get_device_name(0), flush=True); a=torch.empty(10 * 1024**3 // 4, dtype=torch.float32, device="cuda"); print("allocated_bytes", a.numel() * 4, flush=True); time.sleep(30)' > "$D/mem-over-run2.txt" 2>&1 &
PID=$!
sleep 12
$K ubuntu@"$NODE_IP" "date; mx-smi" > "$D/mem-over-host-mx-smi2.txt" 2>&1
$K ubuntu@"$NODE_IP" "mx-smi --show-process" > "$D/mem-over-host-process2.txt" 2>&1
$K ubuntu@"$NODE_IP" "mx-smi --show-usage" > "$D/mem-over-host-usage2.txt" 2>&1
wait "$PID"
echo "rc=$?" >> "$D/mem-over-run2.txt"
kubectl -n "$NS" get pod "$P" -o wide > "$D/mem-over-pod-after2.txt" 2>&1

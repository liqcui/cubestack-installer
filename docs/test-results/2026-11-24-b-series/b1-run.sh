#!/bin/bash
set -u
D=/root/hv-test-20261124
mkdir -p "$D"
NS=hami-demo
kubectl create ns "$NS" 2>/dev/null || true
kubectl apply -f "$D/b1-fullcard.yaml" 2>&1 | tee "$D/B1-apply.txt"

phase=""
for i in $(seq 1 120); do
  phase=$(kubectl -n "$NS" get pod b1-fullcard -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = "Running" ] && break
  [ "$phase" = "Failed" ] && break
  sleep 2
done
echo "phase=$phase" | tee -a "$D/B1-apply.txt"
kubectl -n "$NS" get pod b1-fullcard -o wide 2>&1 | tee -a "$D/B1-apply.txt"
kubectl -n "$NS" get pod b1-fullcard -o json > "$D/B1-pod.json" 2>&1
kubectl -n "$NS" describe pod b1-fullcard > "$D/B1-describe.txt" 2>&1

if [ "$phase" = "Running" ]; then
  echo "===== annotations =====" | tee "$D/B1-annotations.txt"
  kubectl -n "$NS" get pod b1-fullcard -o jsonpath='{.metadata.annotations}' | jq . 2>&1 | tee -a "$D/B1-annotations.txt"
  echo "===== exec: mx-smi =====" | tee "$D/B1-mx-smi-in-container.txt"
  kubectl -n "$NS" exec b1-fullcard -- mx-smi 2>&1 | tee -a "$D/B1-mx-smi-in-container.txt"
  echo "===== exec: device properties =====" | tee "$D/B1-device-props.txt"
  kubectl -n "$NS" exec b1-fullcard -- /opt/conda/bin/python3.12 -c 'import torch, json; p=torch.cuda.get_device_properties(0); print(json.dumps({"name":p.name,"total_memory_bytes":p.total_memory,"total_memory_GiB":round(p.total_memory/1024**3,2)}))' 2>&1 | tee -a "$D/B1-device-props.txt"
  NODE=$(kubectl -n "$NS" get pod b1-fullcard -o jsonpath='{.spec.nodeName}')
  NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  echo "node=$NODE ip=$NODE_IP" | tee -a "$D/B1-annotations.txt"
  K="ssh -i /root/.ssh/cubestack_k8s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/cubestack_known_hosts"
  $K ubuntu@"$NODE_IP" "date; mx-smi" > "$D/B1-host-mx-smi.txt" 2>&1
  $K ubuntu@"$NODE_IP" "mx-smi --show-memory" > "$D/B1-host-memory.txt" 2>&1
  BDF=$(kubectl -n "$NS" get pod b1-fullcard -o jsonpath='{.metadata.annotations.metax-tech\.com/gpu-allocated-status}' 2>/dev/null | jq -r '.[0].sgpus[0].bdf' 2>/dev/null || true)
  if [ -n "$BDF" ]; then
    echo "bdf=$BDF" | tee -a "$D/B1-annotations.txt"
    $K ubuntu@"$NODE_IP" "echo '== $BDF'; ls -l /sys/bus/pci/devices/$BDF/sgpu/ 2>&1; for f in total_devcnt available_devcnt total_vram_quota available_vram_quota total_sched_quota available_sched_quota; do echo -n \"\$f=\"; cat /sys/bus/pci/devices/$BDF/sgpu/\$f 2>/dev/null; done" > "$D/B1-sysfs.txt" 2>&1
  fi
fi

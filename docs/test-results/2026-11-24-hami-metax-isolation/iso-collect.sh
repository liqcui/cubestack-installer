#!/bin/bash
set -u
D=/root/hv-test-20261123/iso
mkdir -p "$D"
NS=hami-demo
P=iso-probe

kubectl -n "$NS" get pod "$P" -o json > "$D/pod.json" 2>&1
kubectl -n "$NS" get pod "$P" -o yaml > "$D/pod.yaml" 2>&1

run_exec() {
  local name="$1"; shift
  local file="$D/$name"
  kubectl -n "$NS" exec "$P" -- "$@" > "$file" 2>&1
  local rc=$?
  echo "rc=$rc" >> "$file"
}

run_exec ld-preload.txt cat /etc/ld.so.preload
run_exec dev-list.txt ls -l /proc/1/root/dev/
run_exec environ.raw cat /proc/1/environ
run_exec mountinfo.txt cat /proc/self/mountinfo
run_exec dev-all.txt ls -la /dev
run_exec env.txt env
run_exec tools.txt sh -c 'command -v mx-smi; command -v nvidia-smi; command -v python3; ls -la /opt 2>/dev/null; ls -la /usr/local 2>/dev/null'
run_exec mx-smi-in-container.txt mx-smi
run_exec find-vgpu.txt sh -c "find / -maxdepth 5 -iname '*vgpu*' 2>/dev/null | head -50"
run_exec find-maca.txt sh -c "find / -maxdepth 4 \( -iname '*libcuda*' -o -iname '*libmaca*' -o -iname 'mx-smi' \) 2>/dev/null | head -50"
run_exec cgroup.txt cat /proc/1/cgroup

# NUL-separated environ -> readable
tr '\0' '\n' < "$D/environ.raw" > "$D/environ.txt" 2>/dev/null || true

# Pod annotations / spec summary
kubectl -n "$NS" get pod "$P" -o json > "$D/pod.json" 2>&1

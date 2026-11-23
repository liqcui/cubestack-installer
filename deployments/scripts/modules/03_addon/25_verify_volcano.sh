#!/bin/bash
# ============================================================
# MODULE: verify_volcano
# DESC: 验证 Volcano 组件 + Volcano Job(schedulerName=hami-scheduler)消费 MetaX vGPU
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: volcano
# 说明:
#   · 组件级: controller/scheduler/admission Deployment Ready + Job CRD + admission webhook;
#     HAMi scheduler 必须存在(Volcano Job 的 Pod 交给它调度)。
#   · 端到端: 创建 1 个 Volcano Job(tasks[].template.spec.schedulerName=hami-scheduler,
#     同时 Job spec.schedulerName=hami-scheduler), 请求 MetaX sgpu/vcore/vmemory
#     (native 模式则 gpu=1); 断言 Volcano 创建的 Pod 由 hami-scheduler 调度且带 HAMi 分配注解。
#   · 无 MetaX GPU/sGPU: 组件级通过并明确告警跳过端到端(不误报)。
#   · 探针资源默认 25%/4GiB, 避免集群已有负载时 CardInsufficientCore 误判;
#     VOLCANO_VERIFY_VCORE / VOLCANO_VERIFY_VMEMORY / VOLCANO_VERIFY_WAIT_SECONDS 可覆盖。
# 用法: sudo ./deploy-cluster.sh --steps verify_volcano
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

NS="${VOLCANO_NAMESPACE:-volcano-system}"
RELEASE="${VOLCANO_RELEASE:-volcano}"
CHART_VER="${VOLCANO_VERSION:-1.16.0}"
IMG_TAG="${HAMI_IMAGE_TAG:-v${HAMI_VERSION:-2.11.0}}"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
_FULL="${RELEASE}"

init_remote_kubectl || exit 1

# ---- 门禁: 以实际部署为准 ----
if ! SSH "${K}" -n "${NS}" get deploy "${_FULL}-controllers" --no-headers >/dev/null 2>&1 \
   && [ "${VOLCANO_ENABLED:-false}" != "true" ]; then
    say "Volcano 未部署(${NS}/${_FULL}-controllers 不存在且 VOLCANO_ENABLED≠true), 跳过验证"
    exit 0
fi

say "Verify Volcano: components → Volcano Job → HAMi vGPU ..."

# ---------- ① 组件 ----------
for _dep in "${_FULL}-controllers" "${_FULL}-scheduler" "${_FULL}-admission"; do
    if ! SSH "${K}" -n "${NS}" rollout status "deployment/${_dep}" --timeout=60s >/dev/null 2>&1; then
        SSH "${K}" -n "${NS}" get pods -o wide 2>/dev/null | sed 's/^/    /' || true
        err "  ${NS}/${_dep} 未就绪"
        exit 1
    fi
done
ok "  controller/scheduler/admission Ready ✓"
SSH "${K}" get crd jobs.batch.volcano.sh >/dev/null 2>&1 \
    || { err "  Volcano Job CRD 不存在"; exit 1; }
SSH "${K}" get validatingwebhookconfiguration "${_FULL}-admission-service-jobs-validate" >/dev/null 2>&1 \
    || { err "  Volcano admission webhook 不存在"; exit 1; }
ok "  Job CRD + admission webhook 已注册 ✓"

# HAMi scheduler 必须存在
_hami_ns="${HAMI_NAMESPACE:-kube-system}"
_hami_rel="${HAMI_RELEASE:-hami}"
if ! SSH "${K}" -n "${_hami_ns}" get deploy "${_hami_rel}-scheduler" >/dev/null 2>&1; then
    err "  HAMi scheduler(${_hami_ns}/${_hami_rel}-scheduler)不存在; 先 --steps hami"
    exit 1
fi
ok "  HAMi scheduler 在位(${_hami_ns}/${_hami_rel}-scheduler) ✓"

# ---------- ② MetaX 资源探测 ----------
_nodes_json="$( (SSH "${K}" get nodes -o json 2>/dev/null) || true )"
read -r _n_nodes _gpu_total _sgpu_total <<< "$(printf '%s' "${_nodes_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("0 0 0"); raise SystemExit
nodes = gpu_total = sgpu_total = 0
for n in d.get("items", []):
    a = (n.get("status") or {}).get("allocatable") or {}
    def num(k):
        try: return int(a.get(k) or 0)
        except Exception: return 0
    gv = num("metax-tech.com/gpu"); sv = num("metax-tech.com/sgpu")
    gpu_total += gv; sgpu_total += sv
    if gv > 0 or sv > 0: nodes += 1
print(nodes, gpu_total, sgpu_total)
' 2>/dev/null || true)"
for _v in _n_nodes _gpu_total _sgpu_total; do
    eval "_v2=\${${_v}:-0}"
    case "${_v2}" in ''|*[!0-9]*) eval "${_v}=0" ;; *) eval "${_v}=${_v2}" ;; esac
done
unset _v _v2
if [ "${_n_nodes}" -eq 0 ]; then
    warn "  无节点声明 metax-tech.com/gpu 或 sgpu allocatable; 组件级通过, 跳过 GPU 端到端"
    ok "verify_volcano 完成(组件级)"
    exit 0
fi
ok "  MetaX 节点=${_n_nodes}, GPU=${_gpu_total}, sGPU=${_sgpu_total} ✓"

# ---------- ③ Volcano Job 端到端 ----------
_vcore="${VOLCANO_VERIFY_VCORE:-25}"
_vmemory="${VOLCANO_VERIFY_VMEMORY:-4}"
_wait="${VOLCANO_VERIFY_WAIT_SECONDS:-180}"
case "${_vcore}" in ''|*[!0-9]*|0) _vcore=25 ;; esac
case "${_vmemory}" in ''|*[!0-9]*|0) _vmemory=4 ;; esac
case "${_wait}" in ''|*[!0-9]*|0) _wait=180 ;; esac
if [ "${_sgpu_total}" -gt 0 ]; then
    _probe_kind="sGPU"
    _limits=$'                limits:\n                  metax-tech.com/sgpu: 1\n                  metax-tech.com/vcore: '"${_vcore}"$'\n                  metax-tech.com/vmemory: '"${_vmemory}"
    _desc="sgpu=1 / vcore=${_vcore} / vmemory=${_vmemory}"
else
    _probe_kind="GPU"
    _limits=$'                limits:\n                  metax-tech.com/gpu: 1'
    _desc="gpu=1(native 模式)"
fi
_probe_img="${VOLCANO_VERIFY_IMAGE:-${REG_BASE}/mirrors/docker.io/projecthami/hami:${IMG_TAG}}"
say "  ③ 创建 Volcano Job(${_probe_kind}: ${_desc})..."
SSH "${K}" -n default delete vcjob volcano-verify-gpu --ignore-not-found --wait=false >/dev/null 2>&1 || true
cleanup() {
    SSH "${K}" -n default delete vcjob volcano-verify-gpu --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! SSH "${K}" apply -f - >/dev/null <<EOF
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: volcano-verify-gpu
  namespace: default
spec:
  minAvailable: 1
  schedulerName: hami-scheduler
  queue: default
  tasks:
    - name: main
      replicas: 1
      template:
        metadata:
          annotations:
            metax-tech.com/sgpu-topology-aware: "true"
        spec:
          schedulerName: hami-scheduler
          restartPolicy: Never
          containers:
            - name: main
              image: ${_probe_img}
              imagePullPolicy: IfNotPresent
              command: ["sh", "-c", "sleep 120"]
              resources:
${_limits}
EOF
then
    err "  Volcano Job 创建失败(检查 CRD/admission/queue)"
    exit 1
fi

# Volcano controller 创建 Pod 需要短暂时间; kubectl wait 在"尚无匹配 Pod"时会立即报错,
# 因此先有界等 Pod 出现, 再等 Ready。
_pod_seen=0
for _i in $(seq 1 60); do
    if SSH "${K}" -n default get pods -l volcano.sh/job-name=volcano-verify-gpu \
            --no-headers 2>/dev/null | grep -q .; then
        _pod_seen=1; break
    fi
    sleep 2
done
if [ "${_pod_seen}" != "1" ]; then
    SSH "${K}" -n default get vcjob volcano-verify-gpu 2>/dev/null | sed 's/^/    /' || true
    err "  Volcano controller 未在 120s 内创建 Pod"
    exit 1
fi

if ! SSH "${K}" -n default wait --for=condition=Ready \
        pod -l volcano.sh/job-name=volcano-verify-gpu --timeout="${_wait}s" >/dev/null 2>&1; then
    SSH "${K}" -n default get vcjob volcano-verify-gpu 2>/dev/null | sed 's/^/    /' || true
    SSH "${K}" -n default get pods -l volcano.sh/job-name=volcano-verify-gpu -o wide 2>/dev/null | sed 's/^/    /' || true
    SSH "${K}" -n default describe pods -l volcano.sh/job-name=volcano-verify-gpu 2>/dev/null | tail -40 | sed 's/^/    /' || true
    err "  Volcano Job Pod 未在 ${_wait}s 内 Ready"
    exit 1
fi
ok "    Volcano Job Pod Ready ✓"

_pods_json="$( (SSH "${K}" -n default get pods -l volcano.sh/job-name=volcano-verify-gpu -o json 2>/dev/null) || true )"
printf '%s' "${_pods_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
ok = True
for p in d.get("items", []):
    name = p["metadata"]["name"]
    sched = (p.get("spec") or {}).get("schedulerName")
    ann = (p["metadata"].get("annotations") or {})
    alloc = ann.get("hami.io/metax-sgpu-devices-allocated") or ann.get("metax-tech.com/gpu-devices-allocated") or ""
    if sched != "hami-scheduler" or not alloc:
        print(f"BAD {name} scheduler={sched} alloc={alloc!r}")
        ok = False
if not ok: sys.exit(1)
' || { err "  Pod 未由 hami-scheduler 调度或缺少 HAMi 分配注解"; exit 1; }
ok "    Pod schedulerName=hami-scheduler + HAMi 分配注解 ✓"

# Volcano Job state 是对象(status.state.phase), 且 Pod Ready 后状态更新有秒级延迟 → 有界等待
_state=""
for _i in $(seq 1 30); do
    _job_json="$( (SSH "${K}" -n default get vcjob volcano-verify-gpu -o json 2>/dev/null) || true )"
    _state="$(printf '%s' "${_job_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
s = d.get("status") or {}
st = s.get("state") or {}
print(st.get("phase") or s.get("phase") or "")
' 2>/dev/null || true)"
    case "${_state}" in Running|Completed) break ;; esac
    sleep 2
done
case "${_state}" in
    Running|Completed) ok "    Volcano Job state=${_state} ✓" ;;
    *)
        SSH "${K}" -n default get vcjob volcano-verify-gpu -o yaml 2>/dev/null | tail -30 | sed 's/^/    /' || true
        err "    Volcano Job state=${_state:-<空>}(期望 Running/Completed)"
        exit 1
        ;;
esac

ok "verify_volcano 完成(组件级 + Volcano Job → HAMi ${_probe_kind} 端到端)"

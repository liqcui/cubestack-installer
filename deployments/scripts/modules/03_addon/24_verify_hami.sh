#!/bin/bash
# ============================================================
# MODULE: verify_hami
# DESC: 验证 HAMi 调度器/Webhook/device-config 就绪; 有沐曦卡节点时验证 sGPU 共享 Pod 调度
# PHASE: addon
# DEFAULT: 0
# REPEAT: 1
# REQUIRES: hami
# 说明:
#   · 验证模块不设 TOGGLE(否则 HAMI_ENABLED=true 时会被安装流程自动启用);
#     仅由 --steps verify_hami 或 --steps verify 显式执行。
#   · 门禁看**实际部署**(hami-scheduler Deployment 存在); 未部署且 HAMI_ENABLED≠true → 跳过。
#   · 组件级(始终): scheduler Deployment Ready + MutatingWebhookConfiguration 存在 +
#     device-config 含 metax-tech.com/gpu|sgpu|vcore|vmemory。
#   · 端到端(仅当有节点声明 metax-tech.com/gpu 或 sgpu allocatable):
#     创建 1 个 Pod(native 模式用 gpu=1; sGPU 模式用 sgpu=1/vcore=60/vmemory=4)
#     (sgpu=1 / vcore=60 / vmemory=4), 断言 admission webhook 自动把 schedulerName 改成
#     hami-scheduler 且 Pod Ready; 容器内设备节点存在为 warn(驱动版本差异, 不误判失败)。
#   · 测试 Pod 用 HAMi 自身镜像(安装时已推入集群内置 registry), 不额外拉公网镜像。
# 用法: sudo ./deploy-cluster.sh --steps verify_hami
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

NS="${HAMI_NAMESPACE:-kube-system}"
RELEASE="${HAMI_RELEASE:-hami}"
CHART_VER="${HAMI_VERSION:-2.11.0}"
IMG_TAG="${HAMI_IMAGE_TAG:-v${CHART_VER}}"
TOPOLOGY_AWARE="${HAMI_METAX_SGPU_TOPOLOGY_AWARE:-false}"
WHITELIST="${HAMI_WEBHOOK_WHITELIST_NAMESPACES:-kube-system}"
CHART_TGZ="${REPO_ROOT}/deployments/cubestack-addon/hami/hami-${CHART_VER}.tgz"
HELPER="${SCRIPT_DIR}/tools/k8s/hami-values.sh"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
SCHED_NAME="${HAMI_SCHEDULER_NAME:-hami-scheduler}"

case "${RELEASE}" in
    *hami*) _full="${RELEASE}" ;;
    *) _full="${RELEASE}-hami" ;;
esac

init_remote_kubectl || exit 1

# ---- 门禁: 以实际部署为准 ----
if ! SSH "${K}" -n "${NS}" get deploy "${_full}-scheduler" --no-headers >/dev/null 2>&1 \
   && [ "${HAMI_ENABLED:-false}" != "true" ]; then
    say "HAMi 未部署(${_full}-scheduler 不存在且 HAMI_ENABLED≠true), 跳过验证(先 --steps hami 部署)"
    exit 0
fi

say "Verify HAMi(MetaX 模式): scheduler → webhook → device-config → sGPU Pod ..."

# ---------- ① scheduler Deployment ----------
say "  ① 检查 ${_full}-scheduler Deployment..."
if ! SSH "${K}" -n "${NS}" rollout status "deployment/${_full}-scheduler" --timeout=60s >/dev/null 2>&1; then
    SSH "${K}" -n "${NS}" get pods -l "app.kubernetes.io/instance=${RELEASE}" -o wide 2>/dev/null | sed 's/^/    /' || true
    err "  ${_full}-scheduler 未就绪"
    exit 1
fi
_ready_n="$( (SSH "${K}" -n "${NS}" get deploy "${_full}-scheduler" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || true)"
ok "    scheduler Ready=${_ready_n:-?} ✓"

# ---------- ② admission webhook ----------
say "  ② 检查 MutatingWebhookConfiguration..."
if ! SSH "${K}" get mutatingwebhookconfiguration "${_full}-webhook" >/dev/null 2>&1; then
    err "    ${_full}-webhook 不存在(检查 ${_full}-admission-create/patch Job)"
    exit 1
fi
ok "    ${_full}-webhook 已注册 ✓"

# ---------- ③ device-config: MetaX 资源名 ----------
say "  ③ 检查 device-config 的 MetaX 资源名..."
_dev_cfg="$( (SSH "${K}" -n "${NS}" get cm "${_full}-scheduler-device" -o json 2>/dev/null) || true )"
[ -n "${_dev_cfg}" ] || { err "    ConfigMap ${_full}-scheduler-device 不存在"; exit 1; }
for _res in metax-tech.com/gpu metax-tech.com/sgpu metax-tech.com/vcore metax-tech.com/vmemory; do
    printf '%s' "${_dev_cfg}" | grep -q "${_res}" \
        || { err "    device-config 缺少 ${_res}"; exit 1; }
done
ok "    metax-tech.com/{gpu,sgpu,vcore,vmemory} 均已配置 ✓"

# ---------- ④ MetaX 节点探测 ----------
# vendor 插件有两种模式: native(advertise metax-tech.com/gpu) / sgpu(advertise metax-tech.com/sgpu)。
# 两种都要支持: HAMi 侧 pod 资源按实际 allocatable 选择, 不能只看 gpu。
_nodes_json="$( (SSH "${K}" get nodes -o json 2>/dev/null) || true )"
read -r _n_nodes _gpu_total _sgpu_nodes _sgpu_total _gpu_nodes <<< "$(printf '%s' "${_nodes_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("0 0 0 0 0"); raise SystemExit
nodes = gpu_total = sgpu_nodes = sgpu_total = gpu_nodes = 0
for n in d.get("items", []):
    a = (n.get("status") or {}).get("allocatable") or {}
    def num(k):
        try: return int(a.get(k) or 0)
        except Exception: return 0
    gv = num("metax-tech.com/gpu"); sv = num("metax-tech.com/sgpu")
    if gv > 0: gpu_nodes += 1; gpu_total += gv
    if sv > 0: sgpu_nodes += 1; sgpu_total += sv
    if gv > 0 or sv > 0: nodes += 1
print(nodes, gpu_total, sgpu_nodes, sgpu_total, gpu_nodes)
' 2>/dev/null || true)"
for _v in _n_nodes _gpu_total _sgpu_nodes _sgpu_total _gpu_nodes; do
    eval "_v2=\${${_v}:-0}"
    case "${_v2}" in ''|*[!0-9]*) eval "${_v}=0" ;; *) eval "${_v}=${_v2}" ;; esac
done
unset _v _v2
if [ "${_n_nodes}" -eq 0 ]; then
    warn "  无节点声明 metax-tech.com/gpu 或 metax-tech.com/sgpu allocatable"
    warn "  (集群无沐曦卡, 或 MetaX device plugin 未就绪/模式未开启)"
    warn "  → 已通过组件级校验(scheduler/webhook/device-config); GPU 端到端验证跳过"
    ok "verify_hami 完成(组件级)"
    exit 0
fi
ok "  检测到 ${_n_nodes} 个 MetaX 节点(GPU=${_gpu_total}, sGPU=${_sgpu_total}; 节点数 gpu=${_gpu_nodes}/sgpu=${_sgpu_nodes}) ✓"

# ---------- ⑤ 共享/整卡 Pod 端到端 ----------
# 探针资源: 25% 算力/4GiB, 避免集群已有 GPU 负载时因 CardInsufficientCore 误判失败;
# 需要更高算力/显存时用 HAMI_VERIFY_VCORE / HAMI_VERIFY_VMEMORY 覆盖。
_vcore="${HAMI_VERIFY_VCORE:-25}"
_vmemory="${HAMI_VERIFY_VMEMORY:-4}"
case "${_vcore}" in ''|*[!0-9]*|0) _vcore=25 ;; esac
case "${_vmemory}" in ''|*[!0-9]*|0) _vmemory=4 ;; esac
if [ "${_sgpu_nodes}" -gt 0 ]; then
    _probe_kind="sGPU"
    _probe_desc="sgpu=1 / vcore=${_vcore} / vmemory=${_vmemory}"
else
    _probe_kind="GPU"
    _probe_desc="gpu=1(native 模式)"
fi
say "  ④ 创建 ${_probe_kind} 测试 Pod(${_probe_desc})..."
[ -f "${CHART_TGZ}" ] && [ -x "${HELPER}" ] \
    || { err "    缺少 vendored chart/生成器, 无法推导 HAMi 镜像"; exit 1; }
_hami_img="$( "${HELPER}" --chart "${CHART_TGZ}" --registry "${REG_BASE}" \
    --image-tag "${IMG_TAG}" --scheduler-version "${K8S_VERSION:-v1.35.8}" \
    --topology-aware "${TOPOLOGY_AWARE}" --webhook-whitelist "${WHITELIST}" \
    --print-images 2>/dev/null | awk -F'\t' '$3 ~ /\/projecthami\/hami$/ {print $3":"$4; exit}' )"
[ -n "${_hami_img}" ] || { err "    无法推导 HAMi 镜像"; exit 1; }
_hami_img="${REG_BASE}/${_hami_img}"

POD="hami-verify-gpu"
cleanup() {
    SSH "${K}" -n default delete pod "${POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

SSH "${K}" -n default delete pod "${POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
if [ "${_sgpu_nodes}" -gt 0 ]; then
SSH "${K}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: default
  labels:
    app: cubestack-hami-verify
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: ${_hami_img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 300"]
      resources:
        limits:
          metax-tech.com/sgpu: 1
          metax-tech.com/vcore: ${_vcore}
          metax-tech.com/vmemory: ${_vmemory}
EOF
else
SSH "${K}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: default
  labels:
    app: cubestack-hami-verify
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: ${_hami_img}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 300"]
      resources:
        limits:
          metax-tech.com/gpu: 1
EOF
fi

_wait="${HAMI_VERIFY_WAIT_SECONDS:-180}"
case "${_wait}" in ''|*[!0-9]*|0) _wait=180 ;; esac
if ! SSH "${K}" -n default wait --for=condition=Ready "pod/${POD}" --timeout="${_wait}s" >/dev/null 2>&1; then
    SSH "${K}" -n default describe pod "${POD}" 2>/dev/null | tail -40 | sed 's/^/    /' || true
    SSH "${K}" -n default get events --field-selector "involvedObject.name=${POD}" \
        --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/    /' || true
    if [ "${_sgpu_nodes}" -gt 0 ]; then
        err "    测试 Pod 未在 ${_wait}s 内 Ready(检查 vendor plugin 是否 advertise metax-tech.com/sgpu/vcore/vmemory)"
    else
        err "    测试 Pod 未在 ${_wait}s 内 Ready(检查 vendor plugin 是否 advertise metax-tech.com/gpu)"
    fi
    exit 1
fi
ok "    ${_probe_kind} Pod Ready ✓"

_sched_used="$( (SSH "${K}" -n default get pod "${POD}" -o jsonpath='{.spec.schedulerName}' 2>/dev/null) || true )"
[ "${_sched_used}" = "${SCHED_NAME}" ] \
    || { err "    Pod schedulerName=${_sched_used:-<空>}, 期望 ${SCHED_NAME}(admission webhook 未生效?)"; exit 1; }
ok "    admission webhook 已注入 schedulerName=${SCHED_NAME} ✓"

if SSH "${K}" -n default exec "${POD}" -- sh -c 'test -e /dev/mxcd' >/dev/null 2>&1; then
    ok "    容器内可见沐曦设备节点 /dev/mxcd ✓"
else
    warn "    容器内未发现 /dev/mxcd(驱动/device plugin 版本差异; 调度与共享已通过)"
fi

ok "verify_hami 完成(组件级 + MetaX ${_probe_kind} 端到端)"

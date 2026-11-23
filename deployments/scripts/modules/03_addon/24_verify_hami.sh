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
#   · 端到端(仅当有节点声明 metax-tech.com/gpu allocatable): 创建 1 个 sGPU 共享 Pod
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
_nodes_json="$( (SSH "${K}" get nodes -o json 2>/dev/null) || true )"
read -r _n_nodes _n_gpus <<< "$(printf '%s' "${_nodes_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("0 0"); raise SystemExit
nodes = gpus = 0
for n in d.get("items", []):
    a = (n.get("status") or {}).get("allocatable") or {}
    try:
        v = int(a.get("metax-tech.com/gpu") or 0)
    except Exception:
        v = 0
    if v > 0:
        nodes += 1; gpus += v
print(nodes, gpus)
' 2>/dev/null || true)"
_n_nodes="${_n_nodes:-0}"; _n_gpus="${_n_gpus:-0}"
case "${_n_nodes}" in ''|*[!0-9]*) _n_nodes=0 ;; esac
case "${_n_gpus}" in ''|*[!0-9]*) _n_gpus=0 ;; esac
if [ "${_n_nodes}" -eq 0 ]; then
    warn "  无节点声明 metax-tech.com/gpu allocatable(集群无沐曦卡, 或 MetaX device plugin 未就绪)"
    warn "  → 已通过组件级校验(scheduler/webhook/device-config); GPU 端到端验证跳过"
    ok "verify_hami 完成(组件级)"
    exit 0
fi
ok "  检测到 ${_n_nodes} 个 MetaX 节点, 共 ${_n_gpus} 张卡 ✓"

# ---------- ⑤ sGPU 共享 Pod 端到端 ----------
say "  ④ 创建 sGPU 共享测试 Pod(sgpu=1 / vcore=60 / vmemory=4)..."
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
          metax-tech.com/vcore: 60
          metax-tech.com/vmemory: 4
EOF

_ok=0
for _i in $(seq 1 60); do
    _ready="$( (SSH "${K}" -n default get pod "${POD}" \
        -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null) || true )"
    [ "${_ready}" = "True" ] && { _ok=1; break; }
    _phase="$( (SSH "${K}" -n default get pod "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null) || true )"
    [ "${_phase}" = "Failed" ] && break
    sleep 2
done
if [ "${_ok}" != "1" ]; then
    SSH "${K}" -n default describe pod "${POD}" 2>/dev/null | tail -40 | sed 's/^/    /' || true
    SSH "${K}" -n default get events --field-selector "involvedObject.name=${POD}" \
        --sort-by=.lastTimestamp 2>/dev/null | tail -15 | sed 's/^/    /' || true
    err "    测试 Pod 未在 120s 内 Ready(检查 MetaX device plugin 是否 advertise sgpu/vcore/vmemory)"
    exit 1
fi
ok "    sGPU Pod Ready ✓"

_sched_used="$( (SSH "${K}" -n default get pod "${POD}" -o jsonpath='{.spec.schedulerName}' 2>/dev/null) || true )"
[ "${_sched_used}" = "${SCHED_NAME}" ] \
    || { err "    Pod schedulerName=${_sched_used:-<空>}, 期望 ${SCHED_NAME}(admission webhook 未生效?)"; exit 1; }
ok "    admission webhook 已注入 schedulerName=${SCHED_NAME} ✓"

if SSH "${K}" -n default exec "${POD}" -- sh -c 'test -e /dev/mxcd' >/dev/null 2>&1; then
    ok "    容器内可见沐曦设备节点 /dev/mxcd ✓"
else
    warn "    容器内未发现 /dev/mxcd(驱动/device plugin 版本差异; 调度与共享已通过)"
fi

ok "verify_hami 完成(组件级 + MetaX sGPU 端到端)"

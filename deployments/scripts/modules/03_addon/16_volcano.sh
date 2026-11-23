#!/bin/bash
# ============================================================
# MODULE: volcano
# DESC: 部署 Volcano(Job/Queue 批处理)并以 hami-scheduler 调度 MetaX vGPU Job
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: VOLCANO_ENABLED
# UNINSTALL: 1
# REQUIRES: k8s_deploy k8s_registry hami
# 说明:
#   · 集成方式(2026-11-23): Volcano 负责 Job/Queue 生命周期; Volcano Job 的
#     spec.schedulerName 与 task template.schedulerName 显式设为 hami-scheduler,
#     由已部署的 HAMi scheduler 完成 MetaX vGPU(sgpu/vcore/vmemory) 分配。
#     **不需要 volcano-hami**; **不要**部署 volcano-vgpu-device-plugin(NVIDIA-only)。
#   · Volcano chart 1.16.0 vendored; 3 个镜像推入集群 registry 的 mirrors/ 路径:
#       docker.io/volcanosh/vc-controller-manager
#       docker.io/volcanosh/vc-scheduler
#       docker.io/volcanosh/vc-webhook-manager
#     在线拉取默认走 DaoCloud(m.daocloud.io); 离线 tar 放 offline-files/volcano/
#     或 offline-files/base/volcano/(后者 seal 豁免、offline-sync 保留)。
#   · Volcano 自带 scheduler 仍保留(CPU/普通批处理 Job 可用); GPU Job 走 HAMi,
#     因此 Volcano 的 Gang/Queue/DRF 不参与 GPU Pod 调度(详见 docs/volcano.md)。
#   · 卸载: 单独 `sudo env CUBESTACK_MODULE_ACTION=uninstall bash <本文件>`;
#     helm uninstall + webhook/CRD/命名空间残留清理; 状态置 uninstalled 可直接重装。
# 数据源: cluster.conf (VOLCANO_* / HAMI_* / REGISTRY_* / OFFLINE_FILES_ROOT / NODES)
# 用法:   sudo ./deploy-cluster.sh --steps volcano
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---------------- 派生变量(全部来自 cluster.conf, 无硬编码) ----------------
NS="${VOLCANO_NAMESPACE:-volcano-system}"
RELEASE="${VOLCANO_RELEASE:-volcano}"
CHART_VER="${VOLCANO_VERSION:-1.16.0}"
IMG_TAG="${VOLCANO_IMAGE_TAG:-v${CHART_VER}}"
IMG_MODE="${VOLCANO_IMAGE_MODE:-auto}"
IMG_SOURCE="${VOLCANO_IMAGE_SOURCE:-daocloud}"
CHART_SYNC="${VOLCANO_CHART_SYNC:-offline}"
CHART_DIR="${REPO_ROOT}/deployments/cubestack-addon/volcano"
CHART_TGZ="${CHART_DIR}/volcano-${CHART_VER}.tgz"
HELPER="${SCRIPT_DIR}/tools/k8s/volcano-values.sh"
OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
OFFLINE_DIR="${VOLCANO_OFFLINE_DIR:-${OFFLINE_ROOT}/volcano}"
OFFLINE_LOCAL_DIR="${OFFLINE_ROOT}/base/volcano"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
REGISTRY_BASE="${REGISTRY_BASE:-${REG_BASE}}"
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_BASE}}"
_FULL="${RELEASE}"

# ---------------- 卸载分支(必须在 TOGGLE 检查之前) ----------------
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _have=0
    SSH "${K}" -n "${NS}" get deploy "${_FULL}-controllers" --no-headers >/dev/null 2>&1 && _have=1
    SSH "${K}" get crd jobs.batch.volcano.sh >/dev/null 2>&1 && _have=1
    SSH "${K}" get ns "${NS}" >/dev/null 2>&1 && _have=1
    if [ "${_have}" = "0" ]; then
        say "  Volcano(${RELEASE} @ ${NS}) 不存在, 跳过"
        save_state "volcano" "uninstalled"
        exit 0
    fi
    if command -v helm >/dev/null 2>&1 && sync_kubeconfig >/dev/null 2>&1; then
        say "  volcano: helm uninstall ${RELEASE}(ns=${NS})..."
        helm uninstall "${RELEASE}" -n "${NS}" --wait --timeout 180s >/dev/null 2>&1 \
            || warn "  helm uninstall 未完成(残留由下方清理序列兜底)"
    else
        warn "  helm 不可用 / kubeconfig 同步失败 → 跳过 helm uninstall, 直接残留清理"
    fi
    say "  清理残留(webhook/CRD/命名空间)..."
    # webhook(Helm 可能已删; 幂等)
    for _wh in queues-mutate jobs-mutate jobs-validate queues-validate podgroups-validate \
               hypernodes-validate cronjobs-validate; do
        SSH "${K}" delete mutatingwebhookconfiguration "${_FULL}-admission-service-${_wh}" \
            --ignore-not-found >/dev/null 2>&1 || true
        SSH "${K}" delete validatingwebhookconfiguration "${_FULL}-admission-service-${_wh}" \
            --ignore-not-found >/dev/null 2>&1 || true
    done
    SSH "${K}" -n "${NS}" delete job "${_FULL}-admission-init" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    # CRD(有 CR 的先摘 finalizer, 有界)
    for _crd in jobtemplates.flow.volcano.sh jobflows.flow.volcano.sh cronjobs.batch.volcano.sh \
                jobs.batch.volcano.sh commands.bus.volcano.sh colocationconfigurations.config.volcano.sh \
                numatopologies.nodeinfo.volcano.sh namespacequeues.scheduling.volcano.sh \
                podgroups.scheduling.volcano.sh queues.scheduling.volcano.sh \
                nodeshards.shard.volcano.sh hypernodes.topology.volcano.sh; do
        delete_crd_with_finalizer_cleanup "${_crd}"
    done
    # 命名空间
    SSH "${K}" patch ns "${NS}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    SSH "timeout 30 ${K} delete ns ${NS} --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1" </dev/null || true
    _end=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${_end}" ]; do
        SSH "${K}" get ns "${NS}" >/dev/null 2>&1 || break
        sleep 3
    done
    if SSH "${K}" get ns "${NS}" >/dev/null 2>&1; then
        warn "  ${NS} 在 60s 内未消失(检查 finalizer)"
    else
        ok "  Volcano 已卸载(${RELEASE} @ ${NS})"
    fi
    save_state "volcano" "uninstalled"
    exit 0
fi

# ---------------- 镜像清单模式(不连集群) ----------------
if [ "${VOLCANO_LIST_IMAGES:-false}" = "true" ]; then
    [ -f "${CHART_TGZ}" ] || { err "chart 缺失: ${CHART_TGZ}"; exit 1; }
    [ -x "${HELPER}" ] || { err "缺少生成器: ${HELPER}"; exit 1; }
    echo "=============================================="
    echo "Volcano 所需镜像 — chart ${CHART_VER}, 目标 ${REG_BASE}"
    "${HELPER}" --chart "${CHART_TGZ}" --registry "${REG_BASE}" \
        --image-tag "${IMG_TAG}" --image-source "${IMG_SOURCE}" --print-images \
        | while IFS=$'\t' read -r _src_repo _src_tag _dst_repo _dst_tag _pull_ref; do
            echo "  ${_src_repo}:${_src_tag}  →  ${REG_BASE}/${_dst_repo}:${_dst_tag}"
            echo "      拉取源: ${_pull_ref}"
        done
    echo "=============================================="
    echo "  离线备料目录: ${OFFLINE_DIR} 或 ${OFFLINE_LOCAL_DIR}(tar 命名 <域>_<路径>_<tag>.tar)"
    exit 0
fi

# ---- 开关 ----
[ "${VOLCANO_ENABLED:-false}" = "true" ] || { say "VOLCANO_ENABLED=false, 跳过 Volcano"; exit 0; }

# ---------------- 前置检查 ----------------
say "检查 Volcano 前置条件..."
[ -f "${CHART_TGZ}" ] || { err "vendored chart 缺失: ${CHART_TGZ}"; exit 1; }
[ -x "${HELPER}" ] || { err "缺少镜像/values 生成器: ${HELPER}"; exit 1; }
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+)"; exit 1; }
case "${IMG_SOURCE}" in
    daocloud|upstream) ;;
    *) err "VOLCANO_IMAGE_SOURCE 只接受 daocloud|upstream, 实得: ${IMG_SOURCE}"; exit 1 ;;
esac
skopeo_require "volcano"

init_remote_kubectl || exit 1
SSH "${K}" get nodes --no-headers >/dev/null 2>&1 \
    || { err "无法访问集群(${FIRST_MASTER})"; exit 1; }
# 集成依赖 HAMi scheduler(Volcano Job 的 Pod 交给 hami-scheduler)
_hami_ns="${HAMI_NAMESPACE:-kube-system}"
_hami_rel="${HAMI_RELEASE:-hami}"
if ! SSH "${K}" -n "${_hami_ns}" get deploy "${_hami_rel}-scheduler" >/dev/null 2>&1; then
    err "未找到 HAMi scheduler(${_hami_ns}/${_hami_rel}-scheduler)"
    err "  Volcano + MetaX vGPU 集成要求先部署 HAMi: --steps hami"
    exit 1
fi
ok "HAMi scheduler 在位(${_hami_ns}/${_hami_rel}-scheduler)"

_registry_ready=0
for _t in $(seq 1 15); do
    if curl -s -m 8 "http://${REG_DIRECT}/v2/" >/dev/null 2>&1; then _registry_ready=1; break; fi
    say "  registry ${REG_DIRECT}/v2/ 未就绪, ${_t}/15 次重试 ..."
    sleep 2
done
[ "${_registry_ready}" = "1" ] \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 30s 内不可达"; exit 1; }
ok "registry ${REG_DIRECT}/v2/ 可达"

sync_kubeconfig >/dev/null 2>&1 \
    || { err "宿主机 kubeconfig 同步失败"; exit 1; }
ok "前置检查通过(registry=${REG_BASE}, ns=${NS})"

# ---------------- [1/4] 镜像推送 ----------------
_plan="$(mktemp)"
_work="$(mktemp -d -t cubestack-volcano.XXXXXX)"
trap 'rm -rf "${_plan}" "${_work}"' EXIT
"${HELPER}" --chart "${CHART_TGZ}" --registry "${REG_BASE}" \
    --image-tag "${IMG_TAG}" --image-source "${IMG_SOURCE}" --print-images > "${_plan}" \
    || { err "生成镜像清单失败"; exit 1; }

say "[1/4] 推送 Volcano 镜像 → ${REG_BASE}/mirrors/** ..."
_n_push=0; _n_skip=0
while IFS=$'\t' read -r _src_repo _src_tag _dst_repo _dst_tag _pull_ref; do
    [ -n "${_src_repo}" ] || continue
    _pr="${REG_DIRECT}/$(dirname "${_dst_repo}")"
    _rn="$(basename "${_dst_repo}")"
    if reg_has_tag "${_pr}" "${_rn}" "${_dst_tag}"; then
        _n_skip=$((_n_skip + 1)); continue
    fi
    _pushed=0
    # ① 离线 tar
    _tar="$(find_offline_tar "${_src_repo}:${_src_tag}" \
        "*$(basename "${_src_repo}")*${_src_tag}*.tar" \
        "${OFFLINE_DIR}" "${OFFLINE_LOCAL_DIR}" 2>/dev/null || true)"
    if [ -n "${_tar}" ]; then
        say "  推 ${_src_repo}:${_src_tag} ← $(basename "${_tar}")"
        if push_image_skopeo "docker-archive:${_tar}" \
            "docker://${REG_DIRECT}/${_dst_repo}:${_dst_tag}" >/dev/null 2>&1; then _pushed=1; fi
    fi
    # ② 本地 docker
    if [ "${_pushed}" = "0" ] && command -v docker >/dev/null 2>&1; then
        _local="$( (sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true) \
            | grep -Fx "${_src_repo}:${_src_tag}" | head -1 || true )"
        if [ -n "${_local}" ]; then
            _tmp="/tmp/volcano-img-$$-${_n_push}.tar"
            say "  推 ${_src_repo}:${_src_tag} ← 本地 docker"
            if sudo docker save "${_local}" -o "${_tmp}" >/dev/null 2>&1 \
               && push_image_skopeo "docker-archive:${_tmp}" \
                    "docker://${REG_DIRECT}/${_dst_repo}:${_dst_tag}" >/dev/null 2>&1; then
                _pushed=1
            fi
            rm -f "${_tmp}"
        fi
    fi
    # ③ 在线拉取(auto|online)
    if [ "${_pushed}" = "0" ] && [ "${IMG_MODE}" != "offline" ]; then
        say "  推 ${_src_repo}:${_src_tag} ← ${_pull_ref}"
        push_image_skopeo "docker://${_pull_ref}" \
            "docker://${REG_DIRECT}/${_dst_repo}:${_dst_tag}" >/dev/null 2>&1 && _pushed=1 || true
    fi
    if [ "${_pushed}" = "0" ]; then
        err "镜像推送失败: ${_src_repo}:${_src_tag}"
        err "  离线: tar 放入 ${OFFLINE_LOCAL_DIR}/(命名 <域>_<路径>_<tag>.tar)"
        err "  在线: 确认可达 ${_pull_ref} (VOLCANO_IMAGE_SOURCE=${IMG_SOURCE})"
        exit 1
    fi
    _n_push=$((_n_push + 1))
done < "${_plan}"
ok "  镜像就绪: 新推 ${_n_push} 个, 已在 registry 跳过 ${_n_skip} 个"

# ---------------- [2/4] chart(恒用 vendored 副本) ----------------
say "[2/4] 校验 Volcano chart(${CHART_VER}, sync=${CHART_SYNC})..."
helm_chart_ensure "volcano" "${CHART_TGZ}" "${CHART_VER}" "${CHART_SYNC}" \
    "volcano" "https://volcano-sh.github.io/helm-charts" || exit 1

# ---------------- [3/4] helm install ----------------
_values="${_work}/values.yaml"
"${HELPER}" --chart "${CHART_TGZ}" --registry "${REG_BASE}" \
    --image-tag "${IMG_TAG}" --image-source "${IMG_SOURCE}" > "${_values}" \
    || { err "生成 helm values 失败"; exit 1; }

say "[3/4] helm upgrade --install ${RELEASE} → ${NS}(Volcano Job 由 hami-scheduler 调度 GPU Pod)..."
if ! helm upgrade --install "${RELEASE}" "${CHART_TGZ}" \
        --namespace "${NS}" --create-namespace \
        --values "${_values}" --wait --timeout 300s; then
    warn "  helm 安装/等待失败, 输出诊断:"
    SSH "${K}" -n "${NS}" get pods -o wide 2>/dev/null | sed 's/^/    /' || true
    SSH "${K}" -n "${NS}" get job 2>/dev/null | sed 's/^/    /' || true
    err "Volcano helm 安装失败(检查镜像拉取/admission-init job/registry 连通性)"
    exit 1
fi

# ---------------- [4/4] 就绪校验 + 登记 ----------------
say "[4/4] 等待 Volcano controller/scheduler/admission 就绪 ..."
for _dep in "${_FULL}-controllers" "${_FULL}-scheduler" "${_FULL}-admission"; do
    if ! SSH "${K}" -n "${NS}" rollout status "deployment/${_dep}" --timeout=300s >/dev/null 2>&1; then
        SSH "${K}" -n "${NS}" get pods -o wide 2>/dev/null | sed 's/^/    /' || true
        err "Volcano Deployment ${_dep} 未在 300s 内就绪"
        exit 1
    fi
done
SSH "${K}" get crd jobs.batch.volcano.sh >/dev/null 2>&1 \
    || { err "Volcano Job CRD(jobs.batch.volcano.sh)未创建"; exit 1; }
SSH "${K}" get validatingwebhookconfiguration "${_FULL}-admission-service-jobs-validate" >/dev/null 2>&1 \
    || { err "Volcano admission webhook 未创建"; exit 1; }

record_installed_component "volcano"
ok "Volcano 部署完成: ${_FULL}-controllers/scheduler/admission @ ${NS}"
say "  集成方式: Volcano Job -> spec.schedulerName=hami-scheduler -> HAMi 分配 MetaX vGPU"
say "  示例 Job: docs/volcano-example-job.yaml"
say "  验证:     sudo ./deploy-cluster.sh --steps verify_volcano"
say "  单独卸载: sudo env CUBESTACK_MODULE_ACTION=uninstall bash $0"

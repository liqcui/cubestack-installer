#!/bin/bash
# ============================================================
# MODULE: hami
# DESC: 部署 HAMi 调度器(沐曦 MetaX GPU 共享/拓扑感知); 设备插件由 gpu_operator(MetaX GPU Operator)提供
# PHASE: addon
# DEFAULT: 0
# REPEAT: 0
# TOGGLE: HAMI_ENABLED
# UNINSTALL: 1
# REQUIRES: k8s_deploy k8s_registry gpu_operator
# 说明:
#   · 定位(2026-11-23): HAMi 只提供 scheduler extender + admission webhook + 调度器,
#     **不装** HAMi 自带 NVIDIA device plugin(devicePlugin.enabled=false)。沐曦卡由已有
#     gpu_operator(metax-gpu-k8s 0.15.3, 满足 HAMi 对 MetaX Operator >=0.10.2 的要求)
#     的 vendor device plugin 提供 metax-tech.com/gpu|sgpu|vcore|vmemory;
#   · 镜像(3 个)全部推入集群内置 registry 的 mirrors/<上游全名> 路径, 节点只从 registry 拉:
#       docker.io/projecthami/hami:<HAMI_IMAGE_TAG>
#       registry.k8s.io/kube-scheduler:<集群 server 版本>
#       registry.k8s.io/ingress-nginx/kube-webhook-certgen:<chart 默认 tag+digest 钉子>
#     源优先级: 离线 tar → 本地 docker → 在线拉取; 离线 tar 搜索
#     HAMI_OFFLINE_DIR(默认 offline-files/hami/, release 登记后使用)→
#     offline-files/base/hami/(本地手工备料; seal 豁免且 offline-sync 保留)→
#     kubespray images(kube-scheduler); 在线拉取默认走 DaoCloud 镜像
#     (m.daocloud.io; 国内无法直连 docker.io/registry.k8s.io), 可设
#     HAMI_IMAGE_SOURCE=upstream 直连上游;
#   · 单独安装: sudo ./deploy-cluster.sh --steps hami
#     单独卸载: sudo env CUBESTACK_MODULE_ACTION=uninstall \
#                 bash deployments/scripts/modules/03_addon/15_hami.sh
#     (卸载只动 HAMi 自身资源; 不碰 MetaX GPU Operator / 节点驱动; 卸载后状态置
#      uninstalled, 可直接再次 --steps hami 安装, 无需 --fresh)
#   · 卸载分支在 TOGGLE 检查之前: HAMI_ENABLED=false 时也能卸掉旧装。
#   · chart 恒用 vendored 副本 deployments/cubestack-addon/hami/hami-<ver>.tgz
#     (HAMI_CHART_SYNC=offline 默认; online 仅用于比对刷新)。
#   · 验证: --steps verify_hami(无沐曦卡时组件级通过, 仅告警跳过 GPU 端到端)。
# 数据源: cluster.conf (HAMI_* / K8S_VERSION / REGISTRY_* / OFFLINE_FILES_ROOT / NODES)
# ============================================================
set -euo pipefail

# shellcheck source=lib-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib-common.sh"
load_config

# ---------------- 派生变量(全部来自 cluster.conf, 无硬编码) ----------------
NS="${HAMI_NAMESPACE:-kube-system}"
RELEASE="${HAMI_RELEASE:-hami}"
CHART_VER="${HAMI_VERSION:-2.11.0}"
IMG_TAG="${HAMI_IMAGE_TAG:-v${CHART_VER}}"
IMG_MODE="${HAMI_IMAGE_MODE:-auto}"
IMG_SOURCE="${HAMI_IMAGE_SOURCE:-daocloud}"
CHART_SYNC="${HAMI_CHART_SYNC:-offline}"
TOPOLOGY_AWARE="${HAMI_METAX_SGPU_TOPOLOGY_AWARE:-false}"
WHITELIST="${HAMI_WEBHOOK_WHITELIST_NAMESPACES:-kube-system}"
CHART_DIR="${REPO_ROOT}/deployments/cubestack-addon/hami"
CHART_TGZ="${CHART_DIR}/hami-${CHART_VER}.tgz"
HELPER="${SCRIPT_DIR}/tools/k8s/hami-values.sh"
OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
OFFLINE_DIR="${HAMI_OFFLINE_DIR:-${OFFLINE_ROOT}/hami}"
# 本地手工备料目录: base/ 是离线树里唯一"不属于 release 清单、且 offline-sync 会保留"的
# 目录(校验器对 os/、base/ 免 extra_file 检查) → 手工放入的 tar 不会破坏 seal 门禁。
OFFLINE_LOCAL_DIR="${OFFLINE_ROOT}/base/hami"
KUBESPRAY_IMAGES="${OFFLINE_ROOT}/kubespray/${KUBESPRAY_VERSION:-v2.32.0}/images"
REG_BASE="${REGISTRY_DOMAIN:-${REGISTRY_IP}}:${REGISTRY_PORT:-5000}"
REGISTRY_BASE="${REGISTRY_BASE:-${REG_BASE}}"
REG_DIRECT="${REGISTRY_DIRECT:-${REGISTRY_BASE}}"

# chart 的 fullname 规则(helm common.names.fullname): release 名已含 chart 名 → 直接用,
# 否则 <release>-hami。默认 release=hami → 资源名 hami-scheduler / hami-webhook。
_hami_fullname() {
    case "${RELEASE}" in
        *hami*) printf '%s' "${RELEASE}" ;;
        *) printf '%s-hami' "${RELEASE}" ;;
    esac
}

# ---------------- 卸载分支(必须在 TOGGLE 检查之前) ----------------
# 单独卸载: sudo env CUBESTACK_MODULE_ACTION=uninstall bash <本文件>
# 存在性检查 → helm uninstall → webhook/RBAC/ConfigMap 残留清理(幂等, 有界)。
if [ "${CUBESTACK_MODULE_ACTION:-install}" = "uninstall" ]; then
    init_remote_kubectl || exit 1
    _full="$(_hami_fullname)"
    _have=0
    SSH "${K}" -n "${NS}" get deploy "${_full}-scheduler" --no-headers >/dev/null 2>&1 && _have=1
    SSH "${K}" get mutatingwebhookconfiguration "${_full}-webhook" >/dev/null 2>&1 && _have=1
    SSH "${K}" -n "${NS}" get cm "${_full}-scheduler-device" >/dev/null 2>&1 && _have=1
    if [ "${_have}" = "0" ]; then
        say "  HAMi(${RELEASE} @ ${NS}) 不存在, 跳过"
        save_state "hami" "uninstalled"
        exit 0
    fi
    # 先摘 webhook, 避免 scheduler 卸载过程中 apiserver 仍回调已死服务
    SSH "${K}" delete mutatingwebhookconfiguration "${_full}-webhook" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    if command -v helm >/dev/null 2>&1 && sync_kubeconfig >/dev/null 2>&1; then
        say "  hami: helm uninstall ${RELEASE}(ns=${NS})..."
        helm uninstall "${RELEASE}" -n "${NS}" --wait --timeout 180s >/dev/null 2>&1 \
            || warn "  helm uninstall 未完成(残留由下方清理序列兜底)"
    else
        warn "  helm 不可用 / kubeconfig 同步失败 → 跳过 helm uninstall, 直接残留清理"
    fi
    say "  清理残留(webhook/RBAC/job/configmap/serviceaccount)..."
    SSH "${K}" -n "${NS}" delete job "${_full}-admission-create" "${_full}-admission-patch" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    for _cr in scheduler scheduler-kube scheduler-volume admission; do
        SSH "${K}" delete clusterrole "${_full}-${_cr}" --ignore-not-found >/dev/null 2>&1 || true
        SSH "${K}" delete clusterrolebinding "${_full}-${_cr}" --ignore-not-found >/dev/null 2>&1 || true
    done
    SSH "${K}" -n "${NS}" delete deploy "${_full}-scheduler" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    SSH "${K}" -n "${NS}" delete service "${_full}-scheduler" --ignore-not-found >/dev/null 2>&1 || true
    SSH "${K}" -n "${NS}" delete configmap "${_full}-scheduler" "${_full}-scheduler-device" \
        --ignore-not-found >/dev/null 2>&1 || true
    SSH "${K}" -n "${NS}" delete serviceaccount "${_full}-scheduler" "${_full}-admission" \
        --ignore-not-found >/dev/null 2>&1 || true
    for _r in scheduler admission; do
        SSH "${K}" -n "${NS}" delete role "${_full}-${_r}" --ignore-not-found >/dev/null 2>&1 || true
        SSH "${K}" -n "${NS}" delete rolebinding "${_full}-${_r}" --ignore-not-found >/dev/null 2>&1 || true
    done
    # 有界等待 Deployment 真正消失(最多 60s)
    _end=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${_end}" ]; do
        SSH "${K}" -n "${NS}" get deploy "${_full}-scheduler" >/dev/null 2>&1 || break
        sleep 2
    done
    if SSH "${K}" -n "${NS}" get deploy "${_full}-scheduler" >/dev/null 2>&1; then
        warn "  ${_full}-scheduler 在 60s 内未消失(检查 finalizer/Pod 终止)"
    else
        ok "  HAMi 已卸载(${RELEASE} @ ${NS})"
    fi
    # 状态置 uninstalled(非 done) → 下次 --steps hami 不会被断点续跑跳过, 无需 --fresh
    save_state "hami" "uninstalled"
    exit 0
fi

# ---------------- 镜像清单模式(不连集群, HAMI_ENABLED=false 也可查) ----------------
if [ "${HAMI_LIST_IMAGES:-false}" = "true" ]; then
    [ -f "${CHART_TGZ}" ] || { err "chart 缺失: ${CHART_TGZ}(先在联网机 helm pull 并提交)"; exit 1; }
    [ -x "${HELPER}" ] || { err "缺少生成器: ${HELPER}"; exit 1; }
    _v="${HAMI_SCHEDULER_VERSION:-${K8S_VERSION:-v1.35.8}}"
    echo "=============================================="
    echo "HAMi(MetaX 模式)所需镜像 — chart ${CHART_VER}, 目标 ${REG_BASE}"
    "${HELPER}" --chart "${CHART_TGZ}" --registry "${REG_BASE}" \
        --image-tag "${IMG_TAG}" --scheduler-version "${_v}" \
        --topology-aware "${TOPOLOGY_AWARE}" --webhook-whitelist "${WHITELIST}" \
        --image-source "${IMG_SOURCE}" --print-images \
        | while IFS=$'\t' read -r _src_repo _src_tag _dst_repo _dst_tag _pull_ref; do
            echo "  ${_src_repo}:${_src_tag}  →  ${REG_BASE}/${_dst_repo}:${_dst_tag}"
            echo "      拉取源: ${_pull_ref}"
        done
    echo "=============================================="
    echo "  离线备料目录: ${OFFLINE_DIR}(tar 命名 <域>_<路径>_<tag>.tar)"
    exit 0
fi

# ---- 开关 ----
[ "${HAMI_ENABLED:-false}" = "true" ] || { say "HAMI_ENABLED=false, 跳过 HAMi"; exit 0; }

# ---------------- 前置检查 ----------------
say "检查 HAMi 前置条件..."
[ -f "${CHART_TGZ}" ] || { err "vendored chart 缺失: ${CHART_TGZ}"; exit 1; }
[ -x "${HELPER}" ] || { err "缺少镜像/values 生成器: ${HELPER}"; exit 1; }
command -v helm >/dev/null 2>&1 || { err "未找到 helm(需 3.0+)"; exit 1; }
case "${IMG_SOURCE}" in
    daocloud|upstream) ;;
    *) err "HAMI_IMAGE_SOURCE 只接受 daocloud|upstream, 实得: ${IMG_SOURCE}"; exit 1 ;;
esac
skopeo_require "hami"

init_remote_kubectl || exit 1
SSH "${K}" get nodes --no-headers >/dev/null 2>&1 \
    || { err "无法访问集群(${FIRST_MASTER}); 检查 kubectl/集群状态"; exit 1; }

# 集群 server 版本(决定 kube-scheduler 镜像 tag; 显式覆盖 HAMI_SCHEDULER_VERSION 优先)
SERVER_VER="${HAMI_SCHEDULER_VERSION:-}"
if [ -z "${SERVER_VER}" ]; then
    _ver_json="$( (SSH "${K}" version -o json 2>/dev/null) || true )"
    SERVER_VER="$(printf '%s' "${_ver_json}" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["serverVersion"]["gitVersion"])
except Exception:
    pass' 2>/dev/null || true)"
    SERVER_VER="${SERVER_VER%%+*}"   # 去掉 +k3s1 之类发行版后缀
fi
[ -n "${SERVER_VER}" ] || { SERVER_VER="${K8S_VERSION:-v1.35.8}"; warn "  无法探测集群 server 版本, 使用 K8S_VERSION=${SERVER_VER}"; }

# registry 可达性(时序竞态: VIP 出现后数据面需数秒)
_registry_ready=0
for _t in $(seq 1 15); do
    if curl -s -m 8 "http://${REG_DIRECT}/v2/" >/dev/null 2>&1; then _registry_ready=1; break; fi
    say "  registry ${REG_DIRECT}/v2/ 未就绪, ${_t}/15 次重试 ..."
    sleep 2
done
[ "${_registry_ready}" = "1" ] \
    || { err "集群内置 registry ${REG_DIRECT}/v2/ 30s 内不可达(REGISTRY_SERVICE_TYPE=${REGISTRY_SERVICE_TYPE:-nodeport})"; exit 1; }
ok "registry ${REG_DIRECT}/v2/ 可达"

# helm/kubectl 需要从安装机连 API Server
sync_kubeconfig >/dev/null 2>&1 \
    || { err "宿主机 kubeconfig 同步失败(${FIRST_MASTER} admin.conf → ~/.kube/config)"; exit 1; }
ok "前置检查通过(server=${SERVER_VER}, registry=${REG_BASE})"

# ---------------- [1/4] 镜像推送 ----------------
_plan="$(mktemp)"
_work="$(mktemp -d -t cubestack-hami.XXXXXX)"
trap 'rm -rf "${_plan}" "${_work}"' EXIT

"${HELPER}" --chart "${CHART_TGZ}" --registry "${REG_BASE}" \
    --image-tag "${IMG_TAG}" --scheduler-version "${SERVER_VER}" \
    --topology-aware "${TOPOLOGY_AWARE}" --webhook-whitelist "${WHITELIST}" \
    --image-source "${IMG_SOURCE}" --print-images > "${_plan}" \
    || { err "生成镜像清单失败"; exit 1; }

# certgen 的 chart 默认 tag 带多架构 index digest 钉子。
#   · 在线推送: skopeo --all 保留 index digest → chart 继续用 digest 引用;
#   · 离线 tar(docker-archive 只能单架构): index digest 无法保留 → 降级为 tag 引用
#     (内容仍来自同一 tar; 见 _check_pushed_digest)。
_certgen_tag_override=""
_check_pushed_digest() {   # <src_tag> <dst_repo> <dst_tag> <origin:online|offline|existing>
    case "$1" in
        *@sha256:*) ;;
        *) return 0 ;;
    esac
    local want="${1#*@}" got
    got="$(skopeo inspect --tls-verify=false --no-creds --format '{{.Digest}}' \
        "docker://${REG_DIRECT}/$2:$3" 2>/dev/null || true)"
    [ "${got}" = "${want}" ] && return 0
    if [ "$4" = "online" ]; then
        err "digest 不一致(在线 --all 推送未保留 index digest): $2:$3 期望 ${want}, 实得 ${got:-<空>}"
        return 1
    fi
    warn "  $2 的离线 tar 为单架构(digest ${got:-<空>}), 无法保留 chart digest 钉子 ${want}"
    warn "  → certgen 引用降级为 tag: $3(镜像内容仍来自本次推送的同一 tar)"
    _certgen_tag_override="$3"
    return 0
}

say "[1/4] 推送 HAMi 镜像 → ${REG_BASE}/mirrors/** ..."
_n_push=0; _n_skip=0
while IFS=$'\t' read -r _src_repo _src_tag _dst_repo _dst_tag _pull_ref; do
    [ -n "${_src_repo}" ] || continue
    _pr="${REG_DIRECT}/$(dirname "${_dst_repo}")"
    _rn="$(basename "${_dst_repo}")"
    _pushed_from=""
    if reg_has_tag "${_pr}" "${_rn}" "${_dst_tag}"; then
        _check_pushed_digest "${_src_tag}" "${_dst_repo}" "${_dst_tag}" existing || exit 1
        _n_skip=$((_n_skip + 1)); continue
    fi
    _pushed=0
    # ① 离线 tar(版本树 offline-files/hami/base/hami 或 kubespray images)
    _tar="$(find_offline_tar "${_src_repo}:${_dst_tag}" \
        "*$(basename "${_src_repo}")*${_dst_tag}*.tar" \
        "${OFFLINE_DIR}" "${OFFLINE_LOCAL_DIR}" "${KUBESPRAY_IMAGES}" 2>/dev/null || true)"
    if [ -n "${_tar}" ]; then
        say "  推 ${_src_repo}:${_src_tag} ← $(basename "${_tar}")"
        if push_image_skopeo "docker-archive:${_tar}" \
            "docker://${REG_DIRECT}/${_dst_repo}:${_dst_tag}" >/dev/null 2>&1; then
            _pushed=1; _pushed_from="offline"
        fi
    fi
    # ② 本地 docker(仅当安装机有 docker; CLI 容器内通常没有)
    if [ "${_pushed}" = "0" ] && command -v docker >/dev/null 2>&1; then
        _local="$( (sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true) \
            | grep -Fx "${_src_repo}:${_dst_tag}" | head -1 || true )"
        if [ -n "${_local}" ]; then
            _tmp="/tmp/hami-img-$$-${_n_push}.tar"
            say "  推 ${_src_repo}:${_src_tag} ← 本地 docker"
            if sudo docker save "${_local}" -o "${_tmp}" >/dev/null 2>&1 \
               && push_image_skopeo "docker-archive:${_tmp}" \
                    "docker://${REG_DIRECT}/${_dst_repo}:${_dst_tag}" >/dev/null 2>&1; then
                _pushed=1; _pushed_from="offline"
            fi
            rm -f "${_tmp}"
        fi
    fi
    # ③ 在线拉取(auto|online); pull_ref 默认走 m.daocloud.io; digest 钉子用 --all 保 index
    if [ "${_pushed}" = "0" ] && [ "${IMG_MODE}" != "offline" ]; then
        say "  推 ${_src_repo}:${_src_tag} ← ${_pull_ref}"
        _extra=()
        case "${_src_tag}" in *@sha256:*) _extra+=(--all) ;; esac
        if push_image_skopeo "docker://${_pull_ref}" \
            "docker://${REG_DIRECT}/${_dst_repo}:${_dst_tag}" \
            ${_extra[@]+"${_extra[@]}"} >/dev/null 2>&1; then
            _pushed=1; _pushed_from="online"
        fi
    fi
    if [ "${_pushed}" = "0" ]; then
        err "镜像推送失败: ${_src_repo}:${_src_tag}"
        err "  离线: 把 tar 放入 ${OFFLINE_LOCAL_DIR}/(命名 <域>_<路径>_<tag>.tar; 不受 seal 门禁影响)"
        err "        或版本树 ${OFFLINE_DIR}/(release 登记后可长期保留)"
        err "  在线: 确认安装机可达拉取源 ${_pull_ref} (HAMI_IMAGE_SOURCE=${IMG_SOURCE};"
        err "        可选 daocloud=m.daocloud.io | upstream=直连上游)"
        exit 1
    fi
    _check_pushed_digest "${_src_tag}" "${_dst_repo}" "${_dst_tag}" "${_pushed_from}" || exit 1
    _n_push=$((_n_push + 1))
done < "${_plan}"
ok "  镜像就绪: 新推 ${_n_push} 个, 已在 registry 跳过 ${_n_skip} 个"

# ---------------- [2/4] chart(恒用 vendored 副本) ----------------
say "[2/4] 校验 HAMi chart(${CHART_VER}, sync=${CHART_SYNC})..."
helm_chart_ensure "hami" "${CHART_TGZ}" "${CHART_VER}" "${CHART_SYNC}" \
    "hami" "https://project-hami.github.io/HAMi/" || exit 1

# ---------------- [3/4] helm install ----------------
_values="${_work}/values.yaml"
_certgen_args=()
if [ -n "${_certgen_tag_override}" ]; then
    _certgen_args=(--certgen-tag "${_certgen_tag_override}")
fi
"${HELPER}" --chart "${CHART_TGZ}" --registry "${REG_BASE}" \
    --image-tag "${IMG_TAG}" --scheduler-version "${SERVER_VER}" \
    --topology-aware "${TOPOLOGY_AWARE}" --webhook-whitelist "${WHITELIST}" \
    --image-source "${IMG_SOURCE}" ${_certgen_args[@]+"${_certgen_args[@]}"} \
    > "${_values}" || { err "生成 helm values 失败"; exit 1; }

say "[3/4] helm upgrade --install ${RELEASE} → ${NS}(MetaX 模式, devicePlugin=false)..."
SSH "${K}" get ns "${NS}" >/dev/null 2>&1 \
    || SSH "${K}" create namespace "${NS}" >/dev/null 2>&1 || true
if ! helm upgrade --install "${RELEASE}" "${CHART_TGZ}" \
        --namespace "${NS}" --create-namespace \
        --values "${_values}" --wait --timeout 300s; then
    warn "  helm 安装/等待失败, 输出诊断:"
    SSH "${K}" -n "${NS}" get pods -l "app.kubernetes.io/instance=${RELEASE}" -o wide 2>/dev/null | sed 's/^/    /' || true
    SSH "${K}" -n "${NS}" get job -l "app.kubernetes.io/instance=${RELEASE}" 2>/dev/null | sed 's/^/    /' || true
    err "HAMi helm 安装失败(检查镜像 digest/webhook 证书 job/registry 连通性)"
    exit 1
fi

# ---------------- [4/4] 就绪校验 + 登记 ----------------
say "[4/4] 等待 scheduler/webhook/device-config 就绪 ..."
_full="$(_hami_fullname)"
if ! SSH "${K}" -n "${NS}" rollout status "deployment/${_full}-scheduler" --timeout=300s >/dev/null 2>&1; then
    SSH "${K}" -n "${NS}" get pods -l "app.kubernetes.io/instance=${RELEASE}" -o wide 2>/dev/null | sed 's/^/    /' || true
    SSH "${K}" -n "${NS}" describe deploy "${_full}-scheduler" 2>/dev/null | tail -40 | sed 's/^/    /' || true
    err "HAMi scheduler(${_full}-scheduler)未在 300s 内就绪"
    exit 1
fi
SSH "${K}" get mutatingwebhookconfiguration "${_full}-webhook" >/dev/null 2>&1 \
    || { err "admission webhook ${_full}-webhook 未创建(检查 ${_full}-admission-create/patch Job 日志)"; exit 1; }
SSH "${K}" -n "${NS}" get cm "${_full}-scheduler-device" -o json 2>/dev/null \
    | grep -q 'metax-tech.com/gpu' \
    || { err "device-config 缺少 metax-tech.com/gpu(检查 ${_full}-scheduler-device ConfigMap)"; exit 1; }

record_installed_component "hami"
ok "HAMi(MetaX 模式)部署完成: ${_full}-scheduler @ ${NS}"
say "  MetaX 整卡:   resources.limits.\"metax-tech.com/gpu\"=1"
say "  MetaX 共享:   metax-tech.com/sgpu=1, metax-tech.com/vcore=60, metax-tech.com/vmemory=<GiB>"
say "  拓扑感知:     HAMI_METAX_SGPU_TOPOLOGY_AWARE=true 或 Pod annotation metax-tech.com/sgpu-topology-aware=true"
say "  验证:         sudo ./deploy-cluster.sh --steps verify_hami"
say "  单独卸载:     sudo env CUBESTACK_MODULE_ACTION=uninstall bash $0"

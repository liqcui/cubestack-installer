#!/bin/bash
# ============================================================
# TOOL: volcano-values.sh — 生成 Volcano helm values / 镜像清单
# ------------------------------------------------------------
# 目标: Volcano(Job/Queue 生命周期) + HAMi(MetaX vGPU 调度) 集成。
#   · Volcano 组件镜像全部改写到集群内置 registry 的 mirrors/ 路径:
#       docker.io/volcanosh/vc-controller-manager
#       docker.io/volcanosh/vc-scheduler
#       docker.io/volcanosh/vc-webhook-manager
#   · **不**设置 custom.scheduler_name —— Volcano Job 自己指定
#     spec.schedulerName=hami-scheduler(见 docs/volcano.md), 以免影响 CPU 类 Volcano 作业。
#   · 在线拉取默认走 DaoCloud(m.daocloud.io; 国内无法直连 docker.io)。
#
# 用法:
#   volcano-values.sh --chart <volcano.tgz> --registry <host:port> \
#                     --image-tag <vX.Y.Z> [--image-source daocloud|upstream] [--print-images]
# 输出:
#   默认        : values YAML → stdout
#   --print-images: TSV, 每行 <src_repo>\t<src_tag>\t<dest_repo>\t<dest_tag>\t<pull_ref>
# ============================================================
set -euo pipefail

die() { echo "volcano-values.sh: $*" >&2; exit 2; }

CHART=""; REGISTRY=""; IMAGE_TAG=""; IMAGE_SOURCE="daocloud"; PRINT_IMAGES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --chart)         CHART="${2:?--chart 需要 chart tgz 路径}"; shift 2 ;;
        --registry)      REGISTRY="${2:?--registry 需要 host[:port]}"; shift 2 ;;
        --image-tag)     IMAGE_TAG="${2:?--image-tag 需要镜像 tag}"; shift 2 ;;
        --image-source)  IMAGE_SOURCE="${2:?--image-source 需要 daocloud|upstream}"; shift 2 ;;
        --print-images)  PRINT_IMAGES=1; shift ;;
        -h|--help)       sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

[ -n "${CHART}" ] || die "缺少 --chart"
[ -f "${CHART}" ] || die "chart 不存在: ${CHART}"
[ -n "${REGISTRY}" ] || die "缺少 --registry"
[ -n "${IMAGE_TAG}" ] || die "缺少 --image-tag"
[[ "${REGISTRY}" =~ ^[A-Za-z0-9._:-]+$ ]] || die "--registry 只能是 host[:port], 实得: ${REGISTRY}"
case "${IMAGE_SOURCE}" in
    daocloud|upstream) ;;
    *) die "--image-source 只接受 daocloud|upstream, 实得: ${IMAGE_SOURCE}" ;;
esac

# 组件名与 chart 1.16.0 的 basic.*_image_name 对应(vc-webhook-manager = admission)
_COMPONENTS=(vc-controller-manager vc-scheduler vc-webhook-manager)

_pull_ref() {
    if [ "${IMAGE_SOURCE}" = "upstream" ]; then
        printf 'docker.io/volcanosh/%s:%s' "$1" "${IMAGE_TAG}"
    else
        printf 'm.daocloud.io/docker.io/volcanosh/%s:%s' "$1" "${IMAGE_TAG}"
    fi
}

if [ "${PRINT_IMAGES}" = "1" ]; then
    for c in "${_COMPONENTS[@]}"; do
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "docker.io/volcanosh/${c}" "${IMAGE_TAG}" \
            "mirrors/docker.io/volcanosh/${c}" "${IMAGE_TAG}" \
            "$(_pull_ref "${c}")"
    done
    exit 0
fi

cat <<EOF
basic:
  image_registry: "${REGISTRY}"
  image_pull_policy: "IfNotPresent"
  image_tag_version: "${IMAGE_TAG}"
  controller_image_name: "mirrors/docker.io/volcanosh/vc-controller-manager"
  scheduler_image_name: "mirrors/docker.io/volcanosh/vc-scheduler"
  admission_image_name: "mirrors/docker.io/volcanosh/vc-webhook-manager"
custom:
  admission_enable: true
  controller_enable: true
  scheduler_enable: true
EOF

#!/bin/bash
# ============================================================
# TOOL: hami-values.sh — 生成 HAMi(MetaX 模式)的 helm values / 镜像清单
# ------------------------------------------------------------
# 设计目标: 把"HAMi chart 版本/资源名/镜像来源"收敛到一处, 供 15_hami.sh 与
#   verify_hami 共用; 纯本地计算(不连集群), 便于单测覆盖。
#
# MetaX 口径:
#   · devicePlugin.enabled=false —— 设备由已有 MetaX GPU Operator(vendor device plugin)提供,
#     不能再用 HAMi 自带的 NVIDIA device plugin;
#   · 三个镜像全部改写到集群内置 registry 的 mirrors/<上游全名> 路径:
#       docker.io/projecthami/hami
#       registry.k8s.io/kube-scheduler
#       registry.k8s.io/ingress-nginx/kube-webhook-certgen(KEEP chart 的 digest 钉子)
#   · devices.metax.* 资源名沿用 chart 默认(metax-tech.com/gpu|sgpu|vcore|vmemory);
#   · admission webhook 默认跳过 kube-system, 避免触碰控制面 Pod。
#
# 用法:
#   hami-values.sh --chart <hami.tgz> --registry <host:port> \
#                  --image-tag <vX.Y.Z> --scheduler-version <vA.B.C> \
#                  [--topology-aware true|false] [--webhook-whitelist ns1,ns2] \
#                  [--image-source daocloud|upstream] [--print-images]
# 输出:
#   默认        : values YAML → stdout
#   --print-images: TSV, 每行
#                  <src_repo>\t<src_tag>\t<dest_repo>\t<dest_tag>\t<pull_ref>
#                  pull_ref 是实际拉取引用: daocloud(默认)=m.daocloud.io/<repo>:<tag>,
#                  upstream=<repo>:<tag>(适合能直连 docker.io/registry.k8s.io 的环境)。
#
# chart 中的镜像默认值(registry/repository/tag)从 vendored chart 的 values.yaml 读取;
# chart 升级换了 certgen tag/digest 时本工具自动跟随, 不需要改本脚本。
# ============================================================
set -euo pipefail

die() { echo "hami-values.sh: $*" >&2; exit 2; }

CHART=""; REGISTRY=""; IMAGE_TAG=""; SCHED_VERSION=""
TOPOLOGY_AWARE="false"; WHITELIST="kube-system"; PRINT_IMAGES=0
IMAGE_SOURCE="daocloud"; CERTGEN_TAG_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --chart)            CHART="${2:?--chart 需要 chart tgz 路径}"; shift 2 ;;
        --registry)         REGISTRY="${2:?--registry 需要 host[:port]}"; shift 2 ;;
        --image-tag)        IMAGE_TAG="${2:?--image-tag 需要镜像 tag}"; shift 2 ;;
        --scheduler-version) SCHED_VERSION="${2:?--scheduler-version 需要 kube-scheduler tag}"; shift 2 ;;
        --topology-aware)   TOPOLOGY_AWARE="${2:?--topology-aware 需要 true|false}"; shift 2 ;;
        --webhook-whitelist) WHITELIST="${2:-}"; shift 2 ;;
        --image-source)     IMAGE_SOURCE="${2:?--image-source 需要 daocloud|upstream}"; shift 2 ;;
        --certgen-tag)      CERTGEN_TAG_OVERRIDE="${2:?--certgen-tag 需要 tag}" ; shift 2 ;;
        --print-images)     PRINT_IMAGES=1; shift ;;
        -h|--help)          sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

case "${IMAGE_SOURCE}" in
    daocloud|upstream) ;;
    *) die "--image-source 只接受 daocloud|upstream, 实得: ${IMAGE_SOURCE}" ;;
esac

[ -n "${CHART}" ] || die "缺少 --chart"
[ -f "${CHART}" ] || die "chart 不存在: ${CHART}"
[ -n "${REGISTRY}" ] || die "缺少 --registry"
[ -n "${IMAGE_TAG}" ] || die "缺少 --image-tag"
[ -n "${SCHED_VERSION}" ] || die "缺少 --scheduler-version"
[[ "${REGISTRY}" =~ ^[A-Za-z0-9._:-]+$ ]] || die "--registry 只能是 host[:port], 实得: ${REGISTRY}"
python3 -c 'import yaml' 2>/dev/null || die "需要 python3-yaml"

# 从 chart tgz 里取 values.yaml(不依赖 helm 可执行文件, 单测更轻)
ENTRY="$(tar -tzf "${CHART}" | grep -E '/values\.yaml$' | head -1 || true)"
[ -n "${ENTRY}" ] || die "chart 内找不到 values.yaml: ${CHART}"

python3 - "${CHART}" "${ENTRY}" "${REGISTRY}" "${IMAGE_TAG}" "${SCHED_VERSION}" \
         "${TOPOLOGY_AWARE}" "${WHITELIST}" "${PRINT_IMAGES}" "${IMAGE_SOURCE}" \
         "${CERTGEN_TAG_OVERRIDE}" <<'PY'
import sys
import tarfile
import yaml

(chart, entry, registry, image_tag, sched_version,
 topology, whitelist, print_images, image_source, certgen_tag_override) = sys.argv[1:11]

with tarfile.open(chart, "r:gz") as tf:
    values = yaml.safe_load(tf.extractfile(entry).read()) or {}

sched = values.get("scheduler") or {}
ext = ((sched.get("extender") or {}).get("image") or {})
ks = ((sched.get("kubeScheduler") or {}).get("image") or {})
patch = sched.get("patch") or {}
cert = (patch.get("imageNew") or {})

ext_reg = str(ext.get("registry") or "docker.io").rstrip("/")
ext_repo = str(ext.get("repository") or "projecthami/hami").strip("/")
ks_reg = str(ks.get("registry") or "registry.k8s.io").rstrip("/")
ks_repo = str(ks.get("repository") or "kube-scheduler").strip("/")
cert_reg = str(cert.get("registry") or "registry.k8s.io").rstrip("/")
cert_repo = str(cert.get("repository") or "ingress-nginx/kube-webhook-certgen").strip("/")
cert_tag = str(cert.get("tag") or "")
cert_dest_tag = cert_tag.split("@", 1)[0]

ks_enabled = bool((sched.get("kubeScheduler") or {}).get("enabled", True))
patch_enabled = bool(patch.get("enabled", True))

def truth(v):
    s = str(v).strip().lower()
    if s in ("1", "true", "yes", "on"):
        return True
    if s in ("0", "false", "no", "off", ""):
        return False
    raise SystemExit("hami-values.sh: --topology-aware 只接受 true|false")

topo = truth(topology)
whitelist_ns = [x.strip() for x in str(whitelist).split(",") if x.strip()]

def pull_ref(repo, tag):
    # 国内环境 docker.io/registry.k8s.io 常不可达 → 默认走 DaoCloud 镜像;
    # 目标仓库路径仍按上游全名(mirrors/<上游域>/...), 保持来源可追溯。
    # ⚠ skopeo 不支持 "tag@digest" 源引用 → 带 digest 的 tag 只保留 repo@digest。
    if "@" in tag:
        ref = f"{repo}@{tag.split('@', 1)[1]}"
    else:
        ref = f"{repo}:{tag}"
    if image_source == "upstream":
        return ref
    return f"m.daocloud.io/{ref}"

rows = [
    (f"{ext_reg}/{ext_repo}", image_tag, f"mirrors/{ext_reg}/{ext_repo}", image_tag,
     pull_ref(f"{ext_reg}/{ext_repo}", image_tag)),
]
if ks_enabled:
    rows.append((f"{ks_reg}/{ks_repo}", sched_version, f"mirrors/{ks_reg}/{ks_repo}", sched_version,
                 pull_ref(f"{ks_reg}/{ks_repo}", sched_version)))
if patch_enabled and cert_tag:
    rows.append((f"{cert_reg}/{cert_repo}", cert_tag, f"mirrors/{cert_reg}/{cert_repo}", cert_dest_tag,
                 pull_ref(f"{cert_reg}/{cert_repo}", cert_tag)))

if print_images == "1":
    for row in rows:
        print("\t".join(row))
    raise SystemExit(0)

out = {
    "global": {"imageTag": image_tag},
    "devicePlugin": {"enabled": False},
    "scheduler": {
        "tolerations": [
            {"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"},
            {"key": "node.kubernetes.io/unschedulable", "operator": "Exists", "effect": "NoSchedule"},
        ],
        "admissionWebhook": {"whitelistNamespaces": whitelist_ns},
        "extender": {
            "image": {
                "registry": registry,
                "repository": f"mirrors/{ext_reg}/{ext_repo}",
                "tag": image_tag,
            }
        },
    },
    "devices": {"metax": {"sgpuTopologyAware": topo}},
}
if ks_enabled:
    out["scheduler"]["kubeScheduler"] = {
        "image": {
            "registry": registry,
            "repository": f"mirrors/{ks_reg}/{ks_repo}",
            "tag": sched_version,
        }
    }
if patch_enabled and cert_tag:
    # 默认不覆盖 tag: 保留 chart 默认的 digest 钉子(<tag>@sha256:...);
    # 离线单架构 tar 无法保留 index digest 时, 模块传 --certgen-tag 降级为 tag 引用。
    _patch_img = {
        "registry": registry,
        "repository": f"mirrors/{cert_reg}/{cert_repo}",
    }
    if certgen_tag_override:
        _patch_img["tag"] = certgen_tag_override
    out["scheduler"]["patch"] = {"imageNew": _patch_img}

yaml.safe_dump(out, sys.stdout, sort_keys=False, default_flow_style=False)
PY

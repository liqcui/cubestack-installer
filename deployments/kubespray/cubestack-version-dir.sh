#!/bin/bash
# ============================================================
# cubestack-version-dir.sh — kubespray 版本目录: 列出 / 校验 / 物化
#
#  版本目录 = ${OFFLINE_FILES_ROOT}/kubespray/<版本>/(版本名 = 上游 tag 全名, 决策 D8)
#  内容: tree.tar.gz(预打补丁的整树, 不含 .venv 与 inventory/local)+ images/ + packages/
#        + 裸二进制 + VERSION.profile(档案副本)+ 可选 LOCAL_ONLY(本地临时版本标记, 不上 MinIO)
#
# 设计: docs/kubespray-versioning/design.md §9.1
#
# 用法:
#   bash cubestack-version-dir.sh list                 # 列出在场版本目录(档位/树 tar/镜像数)
#   bash cubestack-version-dir.sh verify <版本> [--full] # 校验 tar/档案/images; --full 再校验制品齐全
#   bash cubestack-version-dir.sh materialize <版本>   # 解树 → deployments/kubespray/versions/<版本>/
#   bash cubestack-version-dir.sh new <版本> --from-root <部署根> [--k8s-version V|auto] [--force]
#   bash cubestack-version-dir.sh profile <版本> --from-root <部署根> [--k8s-version V|auto] [--out FILE]
#       # 只推导 VERSION.profile（stdout 或 --out）；auto/省略 = 取该树表首（最高 Kubernetes）
#   bash cubestack-version-dir.sh refresh <版本> --from-root <部署根> --assets-from <旧版本目录> [--k8s-version V|auto] [--force]
#       # 阶段 2: 复制旧版本目录的未变资产, 再打新树/新档案; 输出缺件清单
#   bash cubestack-version-dir.sh check-assets <版本> [--tree DIR] [--quiet]
#       # 按新树表 + images.manifest 列出缺失/多余制品
#   bash cubestack-version-dir.sh repack <版本> --from-root <部署根>
#
# 退出码: 0=通过; 1=校验不过; 2=参数/环境错误
# ============================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${REPO_ROOT}/deployments/offline-files}"
VERSIONS_DIR="${REPO_ROOT}/deployments/kubespray/versions"

# 树内版本表解析(与 check-modules.sh ⑯ 共用一份口径; 见该库头部)
# shellcheck source=lib-kubespray-tables.sh
source "${SELF_DIR}/lib-kubespray-tables.sh"
# 镜像清单解析(阶段 2: 版本目录制品完整性)
# shellcheck source=../scripts/tools/images/lib-image-manifest.sh
source "${SELF_DIR}/../scripts/tools/images/lib-image-manifest.sh"

ok()   { echo -e "\033[32m✅ $*\033[0m"; }
bad()  { echo -e "\033[31m❌ $*\033[0m"; }
say()  { echo -e "\033[36m→ $*\033[0m"; }
warn() { echo -e "\033[33m⚠  $*\033[0m"; }

vd_dir() { printf '%s\n' "${OFFLINE_ROOT}/$1/$2"; }

# 是不是"版本目录": 至少有一个版本目录标记(树 tar / 档案副本 / LOCAL_ONLY / images/)
_is_version_dir() {
    local d="$1"
    [ -f "${d}/tree.tar.gz" ] || [ -f "${d}/VERSION.profile" ] || [ -f "${d}/LOCAL_ONLY" ] || [ -d "${d}/images" ]
}

# ---------- 阶段 2: 制品清单 / 完整性 ----------
_profile_val() { # <profile> <key>
    grep -m1 -E "^$2=" "$1" 2>/dev/null | cut -d= -f2-
}

# 版本目录对应的树根: 仓库树(版本匹配) / 物化树 / 解 tree.tar.gz 到临时目录。
# 输出 "<tree>\t<tmpdir>"(tmpdir 为空 = 不需要清理)。
_vd_tree_for_dir() { # <版本> <版本目录>
    local v="$1" d="$2" gal tmp
    gal="$(awk '/^version:/{print $2; exit}' "${REPO_ROOT}/deployments/kubespray/kubespray/galaxy.yml" 2>/dev/null)"
    if [ "v${gal}" = "${v}" ]; then
        printf '%s\t\n' "${REPO_ROOT}/deployments/kubespray/kubespray"; return 0
    fi
    if [ -d "${VERSIONS_DIR}/${v}/kubespray" ]; then
        printf '%s\t\n' "${VERSIONS_DIR}/${v}/kubespray"; return 0
    fi
    if [ -f "${d}/tree.tar.gz" ]; then
        tmp="$(mktemp -d)"
        tar -xzf "${d}/tree.tar.gz" -C "${tmp}" >/dev/null 2>&1 || { rm -rf "${tmp}"; return 1; }
        printf '%s\t%s\n' "${tmp}/kubespray" "${tmp}"; return 0
    fi
    return 1
}

# 该版本应存在的二进制/CRD 文件名(与 download.yml 的 dest basename 同口径)。
_required_binaries() { # <tree> <profile>
    local tree="$1" prof="$2"
    local ck="${tree}/roles/kubespray_defaults/vars/main/checksums.yml"
    [ -f "${ck}" ] || { bad "树内缺 ${ck}"; return 1; }
    local k8s etcd calico crictl containerd runc nerdctl helm skopeo yq cni major
    k8s="$(_profile_val "${prof}" K8S_VERSION)"
    etcd="$(_profile_val "${prof}" ETCD_VERSION)"
    calico="$(_profile_val "${prof}" CALICO_VERSION)"
    major="${k8s#v}"; major="${major%.*}"
    crictl="$(kb_tables_crictl_for "${ck}" "${major}")"
    containerd="$(kb_tables_first_key "${ck}" containerd_archive_checksums amd64)"
    runc="$(kb_tables_first_key "${ck}" runc_checksums amd64)"
    nerdctl="$(kb_tables_first_key "${ck}" nerdctl_archive_checksums amd64)"
    helm="$(kb_tables_first_key "${ck}" helm_archive_checksums amd64)"
    skopeo="$(kb_tables_first_key "${ck}" skopeo_binary_checksums amd64)"
    yq="$(kb_tables_first_key "${ck}" yq_checksums amd64)"
    cni="$(kb_tables_first_key "${ck}" cni_binary_checksums amd64)"
    local v
    for v in "${k8s}" "${etcd}" "${calico}" "${crictl}" "${containerd}" "${runc}" "${nerdctl}" \
             "${helm}" "${skopeo}" "${yq}" "${cni}"; do
        [ -n "${v}" ] || { bad "取不到制品版本(k8s=${k8s}, major=${major})"; return 1; }
    done
    printf '%s\n' \
        "kubelet-${k8s#v}-amd64" \
        "kubectl-${k8s#v}-amd64" \
        "kubeadm-${k8s#v}-amd64" \
        "crictl-${crictl}-linux-amd64.tar.gz" \
        "containerd-${containerd}-linux-amd64.tar.gz" \
        "etcd-${etcd#v}-linux-amd64.tar.gz" \
        "runc-${runc}.amd64" \
        "nerdctl-${nerdctl}-linux-amd64.tar.gz" \
        "helm-${helm}-linux-amd64.tar.gz" \
        "skopeo-${skopeo}-amd64" \
        "yq-${yq}-amd64" \
        "cni-plugins-linux-amd64-${cni}.tgz" \
        "calicoctl-${calico#v}-amd64" \
        "calico-${calico#v}-kdd-crds.yaml" \
        "gateway-api-standard-install.yaml"
}

# 该版本应存在的镜像 tar 完整路径(images.manifest 的 k8s-base + ceph)。
_required_images() { # <版本> <profile>
    local v="$1" prof="$2" entries
    (
        set +u
        # shellcheck disable=SC1090
        source "${prof}"
        image_manifest_load >/dev/null 2>&1 || exit 1
        KUBESPRAY_VERSION="${v}"
        IMAGE_OFFLINE_ROOT="${OFFLINE_ROOT}"
        entries="$(image_manifest_entries)" || exit 1
        while IFS=$'\t' read -r g r n; do
            case "${g}" in k8s-base|ceph) image_tar_path "${g}" "${r}" "${n}" ;; esac
        done <<< "${entries}"
    )
}

cmd_list() {
    local comp_dir comp d name tier has_tree n_img marker
    say "版本目录(${OFFLINE_ROOT}; 档位 = 在库 / 本地临时)"
    shopt -s nullglob
    for comp_dir in "${OFFLINE_ROOT}"/*/; do
        comp="$(basename "${comp_dir}")"
        for d in "${comp_dir}"*/; do
            name="$(basename "${d}")"
            _is_version_dir "${d}" || { printf '  %-14s %-12s %s\n' "${comp}" "${name}" "(不像版本目录, 跳过标注)"; continue; }
            if [ -f "${d}/LOCAL_ONLY" ]; then tier="本地临时(不入库/不上 MinIO)"; else tier="在库"; fi
            has_tree="无 tree.tar.gz"; [ -f "${d}/tree.tar.gz" ] && has_tree="有 tree.tar.gz"
            n_img="$(find "${d}/images" -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l)"
            marker=""; [ -f "${d}/VERSION.profile" ] || marker=" ⚠缺 VERSION.profile"
            printf '  %-14s %-12s %-28s %-16s images=%s%s\n' "${comp}" "${name}" "${tier}" "${has_tree}" "${n_img}" "${marker}"
        done
    done
    shopt -u nullglob
}

cmd_verify() {
    local v="${1:-}"
    [ -n "${v}" ] || { bad "用法: $0 verify <版本> [--full]"; return 2; }
    shift || true
    local full=0
    [ "${1:-}" = "--full" ] && full=1
    local d rc=0
    d="$(vd_dir kubespray "${v}")"
    [ -d "${d}" ] || { bad "版本目录不存在: ${d}"; return 1; }
    say "校验 ${d}"
    if [ -f "${d}/tree.tar.gz" ]; then
        if [ -f "${d}/tree.tar.gz.sha256" ]; then
            ( cd "${d}" && sha256sum -c --quiet tree.tar.gz.sha256 ) \
                || { bad "tree.tar.gz 指纹不符(重打包或重新下载)"; rc=1; }
        else
            warn "无 tree.tar.gz.sha256(旧目录?), 跳过指纹校验"
        fi
    else
        bad "缺 tree.tar.gz(版本目录无法物化出树)"; rc=1
    fi
    [ -f "${d}/VERSION.profile" ] || { bad "缺 VERSION.profile(自包含档案副本)"; rc=1; }
    if [ ! -d "${d}/images" ] || [ -z "$(find "${d}/images" -maxdepth 1 -name '*.tar' -print -quit 2>/dev/null)" ]; then
        bad "images/ 为空(节点预加载镜像缺失)"; rc=1
    fi
    if [ "${full}" = "1" ]; then
        cmd_check_assets "${v}" --quiet || rc=1
    fi
    [ "${rc}" = "0" ] && ok "版本目录校验通过: ${v}"
    return "${rc}"
}

cmd_materialize() {
    local v="${1:-}"
    [ -n "${v}" ] || { bad "用法: $0 materialize <版本>"; return 2; }
    local d dst want have
    d="$(vd_dir kubespray "${v}")"; dst="${VERSIONS_DIR}/${v}"
    [ -f "${d}/tree.tar.gz" ] || { bad "缺 ${d}/tree.tar.gz(无法物化)"; return 1; }
    want="$(sha256sum "${d}/tree.tar.gz" | awk '{print $1}')"
    if [ -f "${dst}/kubespray/cluster.yml" ] && [ -f "${dst}/.tree.sha256" ] && [ "$(cat "${dst}/.tree.sha256")" = "${want}" ]; then
        ok "已物化且指纹一致(跳过): ${dst}"
        return 0
    fi
    mkdir -p "${dst}"
    say "解树 → ${dst}(已有内容会被覆盖)"
    tar -xzf "${d}/tree.tar.gz" -C "${dst}" || { bad "解包失败"; return 1; }
    printf '%s\n' "${want}" > "${dst}/.tree.sha256"
    ok "已物化: ${dst}/kubespray(版本 ${v}; .venv 由首次运行时按需重建)"
}

# 打包树: 以 **kubespray/ 为顶层目录**(与物化目标 versions/<版本>/kubespray 同形;
#   ⚠ 曾用 `-C 树 .`(内容平铺)⇒ 解出来没有 kubespray/ 层, materialize 幂等判定与
#   模块的 BASE_DIR/kubespray 推导全对不上 —— 两个版本的 tar 必须同形, 故统一到本函数)
_pack_tree() {   # <部署根(含 kubespray/)> <版本目录>
    local from_root="$1" d="$2"
    [ -d "${from_root}/kubespray" ] || { bad "缺 ${from_root}/kubespray"; return 1; }
    say "打包树 → ${d}/tree.tar.gz(顶层 kubespray/; 排除 .venv 与 inventory/local)"
    tar -czf "${d}/tree.tar.gz" -C "${from_root}" \
        --exclude='kubespray/.venv' --exclude='kubespray/inventory/local' kubespray \
        || { bad "打包失败"; return 1; }
    ( cd "${d}" && sha256sum tree.tar.gz > tree.tar.gz.sha256 )
    ok "树已打包(顶层 kubespray/)"
}

# ── repack: 为已存在的版本目录**重打**树 tar(打包格式变更 / 树内容更新时用) ──
cmd_repack() {   # repack <版本> --from-root DIR
    local v="${1:-}"; [ -n "${v}" ] || { bad "用法: $0 repack <版本> --from-root <部署根>"; return 2; }
    shift || true
    local from_root=""
    while [ $# -gt 0 ]; do case "$1" in
        --from-root) from_root="${2:?}"; shift 2 ;;
        *) bad "未知参数: $1"; return 2 ;;
    esac; done
    [ -n "${from_root}" ] || { bad "缺 --from-root"; return 2; }
    local d; d="$(vd_dir kubespray "${v}")"
    [ -d "${d}" ] || { bad "版本目录不存在: ${d}"; return 1; }
    local gal_ver; gal_ver="$(awk '/^version:/{print $2; exit}' "${from_root}/kubespray/galaxy.yml")"
    [ "v${gal_ver}" = "${v}" ] || { bad "galaxy.yml 版本 v${gal_ver} ≠ 目录名 ${v}"; return 1; }
    if [ -x "${from_root}/cubestack-patch-apply.sh" ]; then
        bash "${from_root}/cubestack-patch-apply.sh" --check || { bad "补丁不在位 → 拒收"; return 1; }
    else
        bad "缺 cubestack-patch-apply.sh → 拒收"; return 1
    fi
    _pack_tree "${from_root}" "${d}" || return 1
    warn "指纹已变 ⇒ 若该版本已物化, 重跑 materialize 会重新解树;若在 MinIO 上需重新上传"
}

# ── new/profile: 造版本目录 / 只推导档案 ──
# 版本面的 k8s 线默认取树内 kubelet_checksums 表首(该 kubespray 支持的最高 Kubernetes);
#   --k8s-version 可显式覆盖(必须在表内), --line 由升级脚本换算后传入。
#   其余 10 项全部从树内表机械取值(禁手抄)。
# v 前缀风格继承: 镜像 ref 直接把变量当 tag(registry.k8s.io/kube-apiserver:${K8S_VERSION}),
#   而真实 tag 是 v1.35.8 ⇒ **v 是值的一部分**(少了就拉不到镜像)。树内表值多数不带 v,
#   故按仓库里的同名声明继承写法。事实源(2026-10-15 版本变量下沉后): cluster.defaults.conf;
#   兼容回退 cluster.conf(用户覆盖) / cluster.conf.example(旧版式)。
_style_prefix() {   # <键> → 输出 "v" 或 ""
    local line="" f v
    for f in         "${REPO_ROOT}/deployments/config/cluster.defaults.conf"         "${REPO_ROOT}/deployments/config/cluster.conf"         "${REPO_ROOT}/deployments/config/cluster.conf.example"; do
        [ -f "${f}" ] || continue
        line="$(grep -m1 -E "^$1=" "${f}" 2>/dev/null)"
        [ -n "${line}" ] && break
    done
    [ -n "${line}" ] || return 0
    v="${line#*=}"
    case "${v}" in *'${'*:-v*) printf 'v' ;; esac
}

_derive_profile() {   # <树根> <版本> <k8s_version>
    local tree="$1" ver="$2" k8s="$3"
    local dl="${tree}/roles/kubespray_defaults/defaults/main/download.yml"
    local ck="${tree}/roles/kubespray_defaults/vars/main/checksums.yml"
    local vm="${tree}/roles/kubespray_defaults/vars/main/main.yml"
    [ -f "${dl}" ] && [ -f "${ck}" ] && [ -f "${vm}" ] || { bad "树内表不全(缺 download.yml/checksums.yml/vars-main)"; return 1; }
    local major="${k8s#v}"; major="${major%.*}"
    [ "$(kb_tables_kubelet_has "${ck}" "${k8s#v}")" = "1" ] || {
        bad "K8S_VERSION=${k8s} 不在该树 kubelet_checksums 表内(该表=可安装版本全集)"
        warn "表内可选项: $(kb_tables_kubelet_list "${ck}" | tr '\n' ' ')"
        return 1
    }
    local calico etcd coredns pause ndc metrics cpa nginx lvp nfd
    calico="$(kb_tables_first_key "${ck}" calicoctl_binary_checksums amd64)"
    # 这三项跨版本形态会漂移(表位置/字面量 vs Jinja/条件表达式)⇒ 走布局容忍层(见库头)
    etcd="$(kb_tables_version_for "${tree}" etcd_supported_versions "${major}")"
    coredns="$(kb_tables_version_for "${tree}" coredns_supported_versions "${major}")"
    pause="$(kb_tables_version_for "${tree}" pod_infra_supported_versions "${major}")"
    ndc="$(kb_tables_scalar "${dl}" nodelocaldns_version)"
    metrics="$(kb_tables_scalar "${dl}" metrics_server_version)"
    cpa="$(kb_tables_scalar "${dl}" dnsautoscaler_version)"
    nginx="$(kb_tables_scalar "${dl}" nginx_image_tag)"
    lvp="$(kb_tables_scalar "${dl}" local_volume_provisioner_version)"
    nfd="$(kb_tables_scalar "${dl}" node_feature_discovery_version)"
    local v
    for v in "${calico}" "${etcd}" "${coredns}" "${pause}" "${ndc}" "${metrics}" "${cpa}" "${nginx}" "${lvp}" "${nfd}"; do
        [ -n "${v}" ] || { bad "有表值取不到(kube_major=${major}) —— 树内表可能没有该 k8s 线"; return 1; }
    done
    cat <<EOF
# 版本套装档案: kubespray ${ver}(本文件由 cubestack-version-dir.sh new 从树内表值机械推导)
#
# 规则(见 docs/kubespray-versioning/design.md §3.2):
#   · 选定档案后, 本文件的版本面变量**接管** cluster.conf / cluster.defaults.conf 的同名变量(档案 > 两者);
#   · 要手工钉某一项 → KUBESPRAY_PROFILE=none;
#   · 字段真值由 check-modules.sh ⑯ 对照该版本树表值逐项断言。
#   · K8S_VERSION=${k8s} 默认取 kubelet_checksums 表首(最高线); --k8s-version 可显式覆盖。
KUBESPRAY_VERSION=${ver}
K8S_VERSION=$(_style_prefix K8S_VERSION)${k8s#v}
PAUSE_VERSION=$(_style_prefix PAUSE_VERSION)${pause#v}
COREDNS_VERSION=$(_style_prefix COREDNS_VERSION)${coredns#v}
DNS_NODE_CACHE_VERSION=$(_style_prefix DNS_NODE_CACHE_VERSION)${ndc#v}
ETCD_VERSION=$(_style_prefix ETCD_VERSION)${etcd#v}
CALICO_VERSION=$(_style_prefix CALICO_VERSION)${calico#v}
METRICS_SERVER_VERSION=$(_style_prefix METRICS_SERVER_VERSION)${metrics#v}
CPA_VERSION=$(_style_prefix CPA_VERSION)${cpa#v}
API_LB_NGINX_IMAGE_TAG=$(_style_prefix API_LB_NGINX_IMAGE_TAG)${nginx#v}
LOCAL_VOLUME_PROVISIONER_VERSION=$(_style_prefix LOCAL_VOLUME_PROVISIONER_VERSION)${lvp#v}
NFD_VERSION=$(_style_prefix NFD_VERSION)${nfd#v}
EOF
}

# ── profile: 只推导 VERSION.profile（不建目录、不打包），供升级脚本写 config/profiles/ ──
cmd_profile() {   # profile <标签> --from-root DIR [--k8s-version V|auto] [--out FILE]
    local v="${1:-}"; [ -n "${v}" ] || { bad "用法: $0 profile <标签> --from-root <部署根> [--k8s-version V|auto] [--out FILE]"; return 2; }
    shift || true
    local from_root="" k8s_arg="" out=""
    while [ $# -gt 0 ]; do case "$1" in
        --from-root)   from_root="${2:?}"; shift 2 ;;
        --k8s-version) k8s_arg="${2:?}"; shift 2 ;;
        --out)         out="${2:?}"; shift 2 ;;
        *) bad "未知参数: $1"; return 2 ;;
    esac; done
    [ -n "${from_root}" ] || { bad "缺 --from-root <部署根>"; return 2; }
    local tree="${from_root}/kubespray"
    [ -d "${tree}" ] || { bad "--from-root 下无 kubespray/: ${from_root}"; return 2; }
    local gal_ver; gal_ver="$(awk '/^version:/{print $2; exit}' "${tree}/galaxy.yml")"
    [ "v${gal_ver}" = "${v}" ] || { bad "galaxy.yml 版本 v${gal_ver} ≠ 目录名 ${v}"; return 1; }
    if [ -x "${from_root}/cubestack-patch-apply.sh" ]; then
        bash "${from_root}/cubestack-patch-apply.sh" --check >/dev/null 2>&1 \
            || { bad "补丁不在位 → 拒收"; return 1; }
    else
        bad "缺 cubestack-patch-apply.sh → 拒收"; return 1
    fi
    local k8s="${k8s_arg}"
    case "${k8s}" in
        ""|auto|max)
            k8s="$(kb_tables_kubelet_max "${tree}/roles/kubespray_defaults/vars/main/checksums.yml")"
            [ -n "${k8s}" ] || { bad "取不到 ${v} 的 kubelet_checksums 表首"; return 2; }
            ;;
    esac
    if [ -n "${out}" ]; then
        _derive_profile "${tree}" "${v}" "${k8s}" > "${out}" || { bad "档案推导失败"; return 1; }
        ok "已写入 ${out}"
    else
        _derive_profile "${tree}" "${v}" "${k8s}"
    fi
}

# ── check-assets: 校验版本目录的二进制/CRD + 镜像是否齐全 ──
cmd_check_assets() {   # check-assets <版本> [--tree DIR] [--quiet]
    local v="${1:-}"; [ -n "${v}" ] || { bad "用法: $0 check-assets <版本> [--tree DIR] [--quiet]"; return 2; }
    shift || true
    local tree_arg="" quiet=0
    while [ $# -gt 0 ]; do case "$1" in
        --tree)  tree_arg="${2:?}"; shift 2 ;;
        --quiet) quiet=1; shift ;;
        *) bad "未知参数: $1"; return 2 ;;
    esac; done
    local d; d="$(vd_dir kubespray "${v}")"
    [ -d "${d}" ] || { bad "版本目录不存在: ${d}"; return 1; }
    local prof="${d}/VERSION.profile"
    [ -f "${prof}" ] || { bad "缺 VERSION.profile: ${prof}"; return 1; }

    local tree="${tree_arg}" tmp="" parsed
    if [ -z "${tree}" ]; then
        parsed="$(_vd_tree_for_dir "${v}" "${d}")" || { bad "取不到树(无 tree.tar.gz / 未物化)"; return 1; }
        tree="${parsed%%$'\t'*}"
        tmp="${parsed#*$'\t'}"
    fi
    say "制品检查 ${d}"
    local req_bin req_img
    req_bin="$(_required_binaries "${tree}" "${prof}")" || { [ -n "${tmp}" ] && rm -rf "${tmp}"; return 1; }
    req_img="$(_required_images "${v}" "${prof}")" || { bad "解析 images.manifest 失败"; [ -n "${tmp}" ] && rm -rf "${tmp}"; return 1; }

    local n_bin=0 n_bin_ok=0 miss_bin="" name
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        n_bin=$((n_bin+1))
        if [ -e "${d}/${name}" ]; then n_bin_ok=$((n_bin_ok+1)); else miss_bin="${miss_bin} ${name}"; fi
    done <<< "${req_bin}"

    local n_img=0 n_img_ok=0 miss_img="" path
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        n_img=$((n_img+1))
        if [ -e "${path}" ]; then n_img_ok=$((n_img_ok+1)); else miss_img="${miss_img} ${path##*/}"; fi
    done <<< "${req_img}"

    local rc=0
    if [ -n "${miss_bin}" ]; then
        bad "缺二进制/CRD(${n_bin_ok}/${n_bin}):${miss_bin}"; rc=1
    else
        ok "二进制/CRD ${n_bin_ok}/${n_bin}"
    fi
    if [ -n "${miss_img}" ]; then
        bad "缺镜像(${n_img_ok}/${n_img}):${miss_img}"; rc=1
    else
        ok "镜像 ${n_img_ok}/${n_img}"
    fi

    if [ "${quiet}" != "1" ]; then
        local extra_bin="" extra_img=""
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            printf '%s\n' "${req_bin}" | grep -qxF "${name}" || extra_bin="${extra_bin} ${name}"
        done < <(find "${d}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
                 | grep -vE '^(tree\.tar\.gz(\.sha256)?|VERSION\.profile|README\.md|LOCAL_ONLY|SHA256SUMS|SIZES)$')
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            printf '%s\n' "${req_img}" | grep -qxF "${d}/images/${name}" || extra_img="${extra_img} ${name}"
        done < <(find "${d}/images" -maxdepth 1 -name '*.tar' -printf '%f\n' 2>/dev/null)
        [ -n "${extra_bin}" ] && warn "新版本不需要的二进制(保留回滚, 可手工删):${extra_bin}"
        [ -n "${extra_img}" ] && warn "新版本不需要的镜像(保留回滚, 可手工删):${extra_img}"
    fi
    [ -n "${tmp}" ] && rm -rf "${tmp}"
    return "${rc}"
}

# ── refresh: 以旧版本目录为基线复制未变资产, 再打新树/新档案(阶段 2) ──
cmd_refresh() {   # refresh <标签> --from-root DIR --assets-from OLD_DIR [--k8s-version V|auto] [--force]
    local v="${1:-}"; [ -n "${v}" ] || { bad "用法: $0 refresh <标签> --from-root <部署根> --assets-from <旧版本目录> [--k8s-version V|auto] [--force]"; return 2; }
    shift || true
    local from_root="" assets_from="" k8s_arg="" force=0
    while [ $# -gt 0 ]; do case "$1" in
        --from-root)   from_root="${2:?}"; shift 2 ;;
        --assets-from) assets_from="${2:?}"; shift 2 ;;
        --k8s-version) k8s_arg="${2:?}"; shift 2 ;;
        --force)       force=1; shift ;;
        *) bad "未知参数: $1"; return 2 ;;
    esac; done
    [ -n "${from_root}" ] || { bad "缺 --from-root <部署根>"; return 2; }
    [ -n "${assets_from}" ] || { bad "缺 --assets-from <旧版本目录>"; return 2; }
    [ -d "${assets_from}" ] || { bad "旧版本目录不存在: ${assets_from}"; return 1; }
    command -v rsync >/dev/null || { bad "缺 rsync"; return 1; }
    local tree="${from_root}/kubespray"
    [ -d "${tree}" ] || { bad "--from-root 下无 kubespray/: ${from_root}"; return 2; }
    local d; d="$(vd_dir kubespray "${v}")"
    if [ -e "${d}" ]; then
        [ "${force}" = "1" ] || { bad "版本目录已存在(先删或加 --force): ${d}"; return 1; }
        warn "--force: 删除已存在的版本目录后重建: ${d}"
        rm -rf "${d}" || { bad "删除失败: ${d}"; return 1; }
    fi

    if [ -x "${from_root}/cubestack-patch-apply.sh" ]; then
        bash "${from_root}/cubestack-patch-apply.sh" --check >/dev/null \
            || { bad "补丁不在位 → 拒收"; return 1; }
    else
        bad "缺 cubestack-patch-apply.sh → 拒收"; return 1
    fi
    local gal_ver; gal_ver="$(awk '/^version:/{print $2; exit}' "${tree}/galaxy.yml")"
    [ "v${gal_ver}" = "${v}" ] || { bad "galaxy.yml 版本 v${gal_ver} ≠ 目录名 ${v}"; return 1; }

    local k8s="${k8s_arg}"
    case "${k8s}" in
        ""|auto|max)
            k8s="$(kb_tables_kubelet_max "${tree}/roles/kubespray_defaults/vars/main/checksums.yml")"
            [ -n "${k8s}" ] || { bad "取不到 ${v} 的 kubelet_checksums 表首"; return 2; }
            say "k8s 未显式指定 → 取新树表首: ${k8s}"
            ;;
    esac

    mkdir -p "${d}"
    say "复制旧版本未变资产: ${assets_from} → ${d}(排除 tree/profile/README/封印)"
    rsync -a --exclude='tree.tar.gz' --exclude='tree.tar.gz.sha256' \
        --exclude='VERSION.profile' --exclude='README.md' --exclude='LOCAL_ONLY' \
        --exclude='SHA256SUMS' --exclude='SIZES' "${assets_from}/" "${d}/" \
        || { bad "复制资产失败"; return 1; }
    _pack_tree "${from_root}" "${d}" || return 1
    say "机械推导档案骨架 → ${d}/VERSION.profile"
    _derive_profile "${tree}" "${v}" "${k8s}" > "${d}/VERSION.profile" || { bad "档案推导失败"; return 1; }
    ok "版本目录已刷新: ${d}"

    cmd_check_assets "${v}" --tree "${tree}" || warn "制品不齐(见上); 补齐后再发布"
    say "下一步:"
    say "  Harbor : sudo KUBESPRAY_VERSION=${v} bash ${REPO_ROOT}/deployments/scripts/tools/images/harbor-sync-images.sh --group k8s-base,ceph  # 上游→Harbor(需联网)"
    say "  镜像   : sudo KUBESPRAY_VERSION=${v} bash ${REPO_ROOT}/deployments/scripts/tools/images/harbor-save-images.sh --group k8s-base,ceph  # Harbor→版本目录"
    say "  二进制 : 从 MinIO 暂存区(如 _upstream-release-*)或上游补齐(见上面的缺件清单)"
    say "  校验   : bash ${REPO_ROOT}/deployments/scripts/tools/offline/verify-offline-files.sh --root ${d} --level full --no-stamp"
    say "  发布   : bash ${REPO_ROOT}/deployments/scripts/tools/offline/sync-to-minio.sh --version ${v}"
}

cmd_new() {   # new <标签> --from-root DIR [--force] [--local] [--assets-from DIR] [--k8s-version V|auto]
    local v="${1:-}"; [ -n "${v}" ] || { bad "用法: $0 new <标签> --from-root <部署根> [--force] [--local] [--assets-from DIR] [--k8s-version V|auto]"; return 2; }
    shift || true
    local from_root="" local_only=0 assets_from="" k8s_arg="" force=0
    while [ $# -gt 0 ]; do case "$1" in
        --from-root)   from_root="${2:?}"; shift 2 ;;
        --assets-from) assets_from="${2:?}"; shift 2 ;;
        --k8s-version) k8s_arg="${2:?}"; shift 2 ;;
        --local)       local_only=1; shift ;;
        --force)       force=1; shift ;;
        *) bad "未知参数: $1"; return 2 ;;
    esac; done
    [ -n "${from_root}" ] || { bad "缺 --from-root <部署根>(需含 kubespray/ 与 cubestack-patch-apply.sh)"; return 2; }
    local tree="${from_root}/kubespray"
    [ -d "${tree}" ] || { bad "--from-root 下无 kubespray/: ${from_root}"; return 2; }
    local d; d="$(vd_dir kubespray "${v}")"
    if [ -e "${d}" ]; then
        if [ "${force}" = "1" ]; then
            warn "--force: 删除已存在的版本目录后重建: ${d}"
            rm -rf "${d}" || { bad "删除失败: ${d}"; return 1; }
        else
            bad "版本目录已存在(先删或加 --force): ${d}"; return 1
        fi
    fi

    # ① 预验证: 补丁必须在位 —— 只打包"已验证过"的树(设计 §5.2)
    if [ -x "${from_root}/cubestack-patch-apply.sh" ]; then
        say "预验证补丁在位: cubestack-patch-apply.sh --check"
        bash "${from_root}/cubestack-patch-apply.sh" --check \
            || { bad "补丁不在位 → 拒收(先按 docs/kubespray-upgrade.md 重放补丁)"; return 1; }
    else
        bad "缺 cubestack-patch-apply.sh(无法证明补丁在位) → 拒收"; return 1
    fi

    # ② 树版本自洽: galaxy.yml 版本 == 目录名
    local gal_ver; gal_ver="$(awk '/^version:/{print $2; exit}' "${tree}/galaxy.yml")"
    [ "v${gal_ver}" = "${v}" ] || { bad "galaxy.yml 版本 v${gal_ver} ≠ 目录名 ${v}"; return 1; }

    # ③ k8s 线: 显式给 → 校验; auto/省略 → 取该树表首(最高 Kubernetes)
    local k8s="${k8s_arg}"
    case "${k8s}" in
        ""|auto|max)
            k8s="$(kb_tables_kubelet_max "${tree}/roles/kubespray_defaults/vars/main/checksums.yml")"
            [ -n "${k8s}" ] || { bad "取不到 ${v} 的 kubelet_checksums 表首"; return 2; }
            say "k8s 未显式指定 → 取新树表首: ${k8s}"
            ;;
    esac

    mkdir -p "${d}"
    _pack_tree "${from_root}" "${d}" || return 1

    say "机械推导档案骨架 → ${d}/VERSION.profile"
    _derive_profile "${tree}" "${v}" "${k8s}" > "${d}/VERSION.profile" || { bad "档案骨架推导失败"; rm -rf "${d}"; return 1; }

    [ "${local_only}" = "1" ] && printf '本地临时版本: 不入 git、不上 MinIO(设计 D4)\n' > "${d}/LOCAL_ONLY"
    if [ -n "${assets_from}" ]; then
        [ -d "${assets_from}" ] || { bad "--assets-from 不是目录: ${assets_from}"; return 1; }
        say "拷入资产: ${assets_from}/ → ${d}/"
        cp -a "${assets_from}"/. "${d}"/
    fi
    ok "版本目录已产出: ${d}"
    [ "${local_only}" = "1" ] && warn "本地临时版本(LOCAL_ONLY): 不会进 git、不会被 sync-to-minio 上传"
    say "下一步: $0 verify ${v}    # 校验(树指纹/档案/images)"
}

main() {
    local sub="${1:-}"
    case "${sub}" in
        list)        cmd_list ;;
        verify)      shift; cmd_verify "$@" ;;
        materialize) shift; cmd_materialize "$@" ;;
        new)         shift; cmd_new "$@" ;;
        profile)     shift; cmd_profile "$@" ;;
        refresh)     shift; cmd_refresh "$@" ;;
        check-assets) shift; cmd_check_assets "$@" ;;
        repack)      shift; cmd_repack "$@" ;;
        -h|--help|"") sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
        *)           bad "未知子命令: ${sub}(可用 list / verify / materialize / new / profile / refresh / check-assets / repack)"; exit 2 ;;
    esac
}
main "$@"

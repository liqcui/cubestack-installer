#!/bin/bash
# ============================================================
# test-kubespray-upgrade-modes.sh — 阶段 1 回归:
#   · kb_tables_kubelet_max / max_in_line / lines(最高 Kubernetes 选择器)
#   · cubestack-version-dir.sh profile: 默认表首 / 显式覆盖
#   · cubestack-kubespray-upgrade.sh --check: refresh vs line-upgrade 判定 + 目标选择
#
# 只用仓库内 fixture, 不联网、不碰集群、不写仓库。失败打印 FAIL 并 rc=1。
# ============================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../../../.." && pwd)"
TABLES="${REPO_ROOT}/deployments/kubespray/lib-kubespray-tables.sh"
VD="${REPO_ROOT}/deployments/kubespray/cubestack-version-dir.sh"
UP="${REPO_ROOT}/deployments/kubespray/cubestack-kubespray-upgrade.sh"
REAL_TREE="${REPO_ROOT}/deployments/kubespray/kubespray"
REAL_CHK="${REAL_TREE}/roles/kubespray_defaults/vars/main/checksums.yml"

fail=0
chk() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s: expected=[%s] actual=[%s]\n' "$1" "$2" "$3"
        fail=1
    fi
}
chk_contains() { # <label> <needle> <haystack>
    if printf '%s' "$3" | grep -qF "$2"; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s: 未找到 [%s]\n' "$1" "$2"
        fail=1
    fi
}
mk_galaxy() { # <dir> <version>
    mkdir -p "$1"
    printf 'namespace: kubernetes_sigs\nname: kubespray\nversion: %s\n' "$2" > "$1/galaxy.yml"
}
cleanup() { rm -rf "${R:-}" "${T:-}" "${T2:-}" "${P:-}" "${PD:-}" "${O:-}" "${VROOT:-}" "${OLDV:-}"; }
trap cleanup EXIT

# 1) 选择器(对 vendored 树真实表)
# shellcheck source=../../kubespray/lib-kubespray-tables.sh
source "${TABLES}"
chk "kubelet_max" "1.36.4" "$(kb_tables_kubelet_max "${REAL_CHK}")"
chk "kubelet_max_in_line 1.35" "1.35.8" "$(kb_tables_kubelet_max_in_line "${REAL_CHK}" 1.35)"
chk "kubelet_max_in_line 1.36" "1.36.4" "$(kb_tables_kubelet_max_in_line "${REAL_CHK}" 1.36)"
chk "kubelet_lines" "1.36 1.35 1.34 " "$(kb_tables_kubelet_lines "${REAL_CHK}" | tr '\n' ' ')"
chk "kubelet_max_in_line 9.9(不存在)" "" "$(kb_tables_kubelet_max_in_line "${REAL_CHK}" 9.9)"

# 2) profile: 显式版本 / 默认表首
P="$(mktemp -d)"; O="$(mktemp -d)"
cp -a "${REAL_TREE}" "${P}/kubespray"
cp -a "${REPO_ROOT}/deployments/kubespray/cubestack-patch-apply.sh" \
      "${REPO_ROOT}/deployments/kubespray/cubestack-patches" \
      "${REPO_ROOT}/deployments/kubespray/lib-kubespray-tables.sh" "${P}/"
out="${O}/explicit.profile"
bash "${VD}" profile v2.32.0 --from-root "${P}" --k8s-version v1.35.8 --out "${out}" >/dev/null 2>&1
chk_contains "profile 显式 K8S_VERSION" "K8S_VERSION=v1.35.8" "$(cat "${out}" 2>/dev/null)"
chk_contains "profile 显式 ETCD_VERSION" "ETCD_VERSION=v3.6.14" "$(cat "${out}" 2>/dev/null)"
out2="${O}/auto.profile"
bash "${VD}" profile v2.32.0 --from-root "${P}" --out "${out2}" >/dev/null 2>&1
chk_contains "profile 默认表首" "K8S_VERSION=v1.36.4" "$(cat "${out2}" 2>/dev/null)"

# 4) refresh: 复制旧版本未变资产 + 重打树/档案; check-assets 报缺件与多余
VROOT="${O}/offline"; OLDV="${O}/old-v2.32.0"
mkdir -p "${VROOT}/kubespray" "${OLDV}/images"
printf 'fake-old-tree\n' > "${OLDV}/tree.tar.gz"
printf 'K8S_VERSION=v1.35.8\n' > "${OLDV}/VERSION.profile"
printf 'old readme\n' > "${OLDV}/README.md"
printf 'img\n' > "${OLDV}/images/old_image.tar"
printf 'bin\n' > "${OLDV}/kubelet-1.35.8-amd64"
rout="$(OFFLINE_FILES_ROOT="${VROOT}" bash "${VD}" refresh v2.32.0 \
    --from-root "${P}" --assets-from "${OLDV}" --k8s-version v1.35.8 --force 2>&1)"; rrc=$?
chk "refresh rc" "0" "${rrc}"
chk "refresh 复制旧镜像" "1" "$([ -f "${VROOT}/kubespray/v2.32.0/images/old_image.tar" ] && echo 1 || echo 0)"
chk "refresh 复制旧二进制" "1" "$([ -f "${VROOT}/kubespray/v2.32.0/kubelet-1.35.8-amd64" ] && echo 1 || echo 0)"
chk "refresh 不复制旧 README" "0" "$([ -f "${VROOT}/kubespray/v2.32.0/README.md" ] && echo 1 || echo 0)"
chk "refresh 重打 tree.tar.gz" "1" "$(tar -tzf "${VROOT}/kubespray/v2.32.0/tree.tar.gz" >/dev/null 2>&1 && echo 1 || echo 0)"
chk_contains "refresh 新 profile" "K8S_VERSION=v1.35.8" "$(cat "${VROOT}/kubespray/v2.32.0/VERSION.profile" 2>/dev/null)"
aout="$(OFFLINE_FILES_ROOT="${VROOT}" bash "${VD}" check-assets v2.32.0 2>&1)"; arc=$?
chk "check-assets 缺件 rc" "1" "${arc}"
chk_contains "check-assets 报缺镜像" "缺镜像" "${aout}"
chk_contains "check-assets 报多余旧镜像" "old_image.tar" "${aout}"

# 3) --check: 模式判定 + 目标选择
R="$(mktemp -d)"; T="$(mktemp -d)"; PD="$(mktemp -d)"
mk_galaxy "${R}/kubespray" 2.32.0
mk_galaxy "${T}" 2.32.1
mkdir -p "${T}/roles/kubespray_defaults/vars/main"
cp "${REAL_CHK}" "${T}/roles/kubespray_defaults/vars/main/checksums.yml"
printf 'KUBESPRAY_VERSION=v2.32.0\nK8S_VERSION=v1.35.8\n' > "${PD}/v2.32.0.profile"

run_check() { # <tag> <tree> [args...]
    local tag="$1" tree="$2"; shift 2
    bash "${UP}" "${tag}" --root "${R}" --tree-src "${tree}" --profile-dir "${PD}" --check "$@" 2>&1
}
out="$(run_check v2.32.1 "${T}")"; rc=$?
chk "--check rc" "0" "${rc}"
chk_contains "--check refresh 判定" "升级类型: refresh" "${out}"
chk_contains "--check 默认表首" "目标 k8s: 1.36.4" "${out}"
chk_contains "--check 当前线" "当前 k8s: v1.35.8" "${out}"

out="$(run_check v2.32.1 "${T}" --line 1.35)"
chk_contains "--line 1.35" "目标 k8s: 1.35.8" "${out}"
out="$(run_check v2.32.1 "${T}" --keep-k8s-line)"
chk_contains "--keep-k8s-line" "目标 k8s: 1.35.8" "${out}"
out="$(run_check v2.32.1 "${T}" --k8s-version v1.35.8)"
chk_contains "--k8s-version" "目标 k8s: 1.35.8" "${out}"

run_check v2.32.1 "${T}" --k8s-version v9.9.9 >/dev/null 2>&1; rc=$?
chk "非法 k8s 版本 rc" "2" "${rc}"

T2="$(mktemp -d)"; mk_galaxy "${T2}" 2.33.0
mkdir -p "${T2}/roles/kubespray_defaults/vars/main"
cp "${REAL_CHK}" "${T2}/roles/kubespray_defaults/vars/main/checksums.yml"
out="$(run_check v2.33.0 "${T2}")"
chk_contains "--check line-upgrade 判定" "升级类型: line-upgrade" "${out}"
run_check v2.33.0 "${T2}" --refresh >/dev/null 2>&1; rc=$?
chk "强制 refresh 与跨线冲突 rc" "2" "${rc}"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ kubespray 升级模式回归通过"
    exit 0
fi
echo "❌ kubespray 升级模式回归失败"
exit 1

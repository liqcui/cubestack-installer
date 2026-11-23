#!/bin/bash
set -euo pipefail

# HAMi 模块回归测试(不接触集群):
#   · hami-values.sh 生成的 values 经 helm template 渲染后, 镜像必须全部指向
#     集群内置 registry 的 mirrors/ 路径, devicePlugin 必须关闭, metaX 资源名与
#     topology-aware 开关必须进入 device-config, webhook 必须存在且跳过 kube-system;
#   · 模块的镜像清单模式(HAMI_LIST_IMAGES=true)必须输出 3 个待推送镜像;
#   · 模块的卸载分支必须声明在 TOGGLE 判断之前(check-modules ⑲ 同口径)。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MODULE="${ROOT}/deployments/scripts/modules/03_addon/15_hami.sh"
HELPER="${ROOT}/deployments/scripts/tools/k8s/hami-values.sh"
CHART="${ROOT}/deployments/cubestack-addon/hami/hami-2.11.0.tgz"
TMP="$(mktemp -d -t cubestack-hami-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

REG="registry.cubestack.io:5000"

[ -f "${CHART}" ] || fail "vendored chart missing: ${CHART}"
[ -f "${CHART}.digest" ] || fail "chart digest sidecar missing: ${CHART}.digest"
[ -x "${HELPER}" ] || fail "helper missing or not executable: ${HELPER}"
[ -f "${MODULE}" ] || fail "module missing: ${MODULE}"

# ---------- values → helm template ----------
"${HELPER}" --chart "${CHART}" --registry "${REG}" \
    --image-tag v2.11.0 --scheduler-version v1.35.8 --topology-aware true \
    > "${TMP}/values.yaml" || fail "hami-values.sh failed"

helm template hami "${CHART}" --namespace kube-system \
    -f "${TMP}/values.yaml" > "${TMP}/render.yaml" 2>"${TMP}/render.err" \
    || { cat "${TMP}/render.err" >&2; fail "helm template failed"; }

grep -q "image: ${REG}/mirrors/docker.io/projecthami/hami:v2.11.0" "${TMP}/render.yaml" \
    || fail "HAMi extender image not redirected to cluster registry"
pass "HAMi extender image points at mirrors/docker.io"

grep -q "image: ${REG}/mirrors/registry.k8s.io/kube-scheduler:v1.35.8" "${TMP}/render.yaml" \
    || fail "kube-scheduler image not redirected/pinned"
pass "kube-scheduler image redirected and version-pinned"

grep -qE "image: ${REG}/mirrors/registry\.k8s\.io/ingress-nginx/kube-webhook-certgen:v1\.6\.9@sha256:" "${TMP}/render.yaml" \
    || fail "certgen image not redirected with digest pin"
pass "certgen image redirected with digest pin"

grep -q "name: metax-tech.com/gpu" "${TMP}/render.yaml" \
    && grep -q "name: metax-tech.com/sgpu" "${TMP}/render.yaml" \
    && grep -q "name: metax-tech.com/vcore" "${TMP}/render.yaml" \
    && grep -q "name: metax-tech.com/vmemory" "${TMP}/render.yaml" \
    || fail "MetaX resource names missing from rendered device config"
pass "MetaX device resources rendered"

grep -q "sgpuTopologyAware: true" "${TMP}/render.yaml" \
    || fail "topology-aware flag not rendered"
pass "MetaX sGPU topology-aware flag rendered"

if grep -q "^kind: DaemonSet" "${TMP}/render.yaml"; then
    fail "device plugin DaemonSet must be disabled for MetaX (vendor plugin owns devices)"
fi
pass "HAMi device plugin DaemonSet disabled"

grep -q "name: hami-webhook" "${TMP}/render.yaml" \
    || fail "mutating webhook not rendered"
grep -q "kubernetes.io/metadata.name" "${TMP}/render.yaml" \
    && grep -q "kube-system" "${TMP}/render.yaml" \
    || fail "webhook whitelist kube-system not rendered"
pass "admission webhook rendered with kube-system whitelist"

# 离线单架构 tar 推送时 digest 钉子无法保留 → 模块必须能降级为 tag 引用
"${HELPER}" --chart "${CHART}" --registry "${REG}" \
    --image-tag v2.11.0 --scheduler-version v1.35.8 --certgen-tag v1.6.9 \
    > "${TMP}/values-certgen-tag.yaml" || fail "hami-values.sh --certgen-tag failed"
helm template hami "${CHART}" --namespace kube-system \
    -f "${TMP}/values-certgen-tag.yaml" > "${TMP}/render-certgen-tag.yaml" \
    || fail "helm template (certgen tag mode) failed"
grep -q "image: ${REG}/mirrors/registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9$" "${TMP}/render-certgen-tag.yaml" \
    || fail "certgen tag override not rendered"
if grep -q "kube-webhook-certgen:v1.6.9@sha256:" "${TMP}/render-certgen-tag.yaml"; then
    fail "certgen tag override must drop the digest pin"
fi
pass "certgen tag-mode override (offline single-arch) works"

# ---------- image plan ----------
# 默认国内镜像源 m.daocloud.io(docker.io/registry.k8s.io 在国内常不可达);
# 第 5 列 = 实际 pull 引用, 前 4 列 = 源/目标元数据。
"${HELPER}" --chart "${CHART}" --registry "${REG}" \
    --image-tag v2.11.0 --scheduler-version v1.35.8 --print-images \
    > "${TMP}/images.tsv" || fail "hami-values.sh --print-images failed"
[ "$(wc -l < "${TMP}/images.tsv")" -eq 3 ] || fail "image plan must contain 3 images"
grep -qP '^docker\.io/projecthami/hami\tv2\.11\.0\tmirrors/docker\.io/projecthami/hami\tv2\.11\.0\tm\.daocloud\.io/docker\.io/projecthami/hami:v2\.11\.0$' "${TMP}/images.tsv" \
    || fail "HAMi image plan entry wrong"
grep -qP '^registry\.k8s\.io/kube-scheduler\tv1\.35\.8\tmirrors/registry\.k8s\.io/kube-scheduler\tv1\.35\.8\tm\.daocloud\.io/registry\.k8s\.io/kube-scheduler:v1\.35\.8$' "${TMP}/images.tsv" \
    || fail "kube-scheduler image plan entry wrong"
grep -qP '^registry\.k8s\.io/ingress-nginx/kube-webhook-certgen\tv1\.6\.9@sha256:[0-9a-f]+\tmirrors/registry\.k8s\.io/ingress-nginx/kube-webhook-certgen\tv1\.6\.9\tm\.daocloud\.io/registry\.k8s\.io/ingress-nginx/kube-webhook-certgen@sha256:[0-9a-f]+$' "${TMP}/images.tsv" \
    || fail "certgen image plan entry wrong (skopeo 不支持 tag@digest 源, pull_ref 必须纯 digest)"
pass "image plan lists exactly the 3 expected pushes via m.daocloud.io"

# 显式 upstream 时 pull 引用不得带镜像前缀(供能直连上游的环境使用)
"${HELPER}" --chart "${CHART}" --registry "${REG}" \
    --image-tag v2.11.0 --scheduler-version v1.35.8 --image-source upstream --print-images \
    > "${TMP}/images-upstream.tsv" || fail "hami-values.sh --image-source upstream failed"
grep -qP '^docker\.io/projecthami/hami\tv2\.11\.0\tmirrors/docker\.io/projecthami/hami\tv2\.11\.0\tdocker\.io/projecthami/hami:v2\.11\.0$' "${TMP}/images-upstream.tsv" \
    || fail "upstream image source should not be prefixed"
pass "upstream image source override works"

# ---------- module list mode ----------
( cd "${ROOT}" && HAMI_LIST_IMAGES=true HAMI_IMAGE_MODE=online bash "${MODULE}" ) \
    > "${TMP}/module-list.txt" 2>&1 || { tail -20 "${TMP}/module-list.txt" >&2; fail "module list mode failed"; }
grep -q "m.daocloud.io/docker.io/projecthami/hami:v2.11.0" "${TMP}/module-list.txt" \
    && grep -q "m.daocloud.io/registry.k8s.io/kube-scheduler:" "${TMP}/module-list.txt" \
    && grep -q "m.daocloud.io/registry.k8s.io/ingress-nginx/kube-webhook-certgen@sha256:" "${TMP}/module-list.txt" \
    || fail "module list mode missing daocloud pull refs"
pass "module image list mode uses m.daocloud.io without cluster access"

# ---------- uninstall branch position ----------
act_line="$(grep -n 'CUBESTACK_MODULE_ACTION:-install' "${MODULE}" | head -1 | cut -d: -f1 || true)"
toggle_line="$(grep -n 'HAMI_ENABLED:-false' "${MODULE}" | head -1 | cut -d: -f1 || true)"
[ -n "${act_line}" ] || fail "module has no uninstall branch"
[ -n "${toggle_line}" ] || fail "module has no HAMI_ENABLED toggle check"
[ "${act_line}" -lt "${toggle_line}" ] || fail "uninstall branch must precede TOGGLE check"
grep -q '^# UNINSTALL: 1$' "${MODULE}" || fail "module must declare '# UNINSTALL: 1'"
pass "uninstall branch declared before TOGGLE check"

echo "all hami module tests passed"

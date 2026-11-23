#!/bin/bash
set -euo pipefail

# Volcano 模块回归测试(不接触集群):
#   · volcano-values.sh 生成的 values 经 helm template 渲染后, 3 个组件镜像必须
#     全部指向集群内置 registry 的 mirrors/ 路径, pullPolicy=IfNotPresent,
#     且渲染出 controller/scheduler/admission 3 个 Deployment 与 jobs CRD;
#   · 镜像清单输出 daocloud pull_ref(3 个);
#   · 模块的卸载分支必须在 TOGGLE 判断之前;
#   · verify 模块必须用 Volcano Job + schedulerName=hami-scheduler 验证 HAMi 集成。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MODULE="${ROOT}/deployments/scripts/modules/03_addon/16_volcano.sh"
VERIFY="${ROOT}/deployments/scripts/modules/03_addon/25_verify_volcano.sh"
HELPER="${ROOT}/deployments/scripts/tools/k8s/volcano-values.sh"
CHART="${ROOT}/deployments/cubestack-addon/volcano/volcano-1.16.0.tgz"
TMP="$(mktemp -d -t cubestack-volcano-test.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

REG="registry.cubestack.io:5000"
[ -f "${CHART}" ] || fail "vendored chart missing: ${CHART}"
[ -f "${CHART}.digest" ] || fail "chart digest sidecar missing: ${CHART}.digest"
[ -x "${HELPER}" ] || fail "helper missing: ${HELPER}"
[ -f "${MODULE}" ] || fail "module missing: ${MODULE}"
[ -f "${VERIFY}" ] || fail "verify module missing: ${VERIFY}"

# ---------- values -> helm template ----------
"${HELPER}" --chart "${CHART}" --registry "${REG}" --image-tag v1.16.0 \
    > "${TMP}/values.yaml" || fail "volcano-values.sh failed"
helm template volcano "${CHART}" --namespace volcano-system -f "${TMP}/values.yaml" \
    > "${TMP}/render.yaml" 2>"${TMP}/render.err" \
    || { cat "${TMP}/render.err" >&2; fail "helm template failed"; }

for comp in vc-controller-manager vc-scheduler vc-webhook-manager; do
    grep -q "image: ${REG}/mirrors/docker.io/volcanosh/${comp}:v1.16.0" "${TMP}/render.yaml" \
        || fail "${comp} image not redirected to cluster registry"
done
pass "Volcano 3 component images point at mirrors/docker.io"

grep -q 'imagePullPolicy: IfNotPresent' "${TMP}/render.yaml" \
    || fail "imagePullPolicy not set to IfNotPresent"
pass "imagePullPolicy=IfNotPresent"

for dep in volcano-controllers volcano-scheduler volcano-admission; do
    grep -q "name: ${dep}" "${TMP}/render.yaml" \
        || fail "Deployment ${dep} not rendered"
done
pass "controller/scheduler/admission Deployments rendered"

grep -q 'name: jobs.batch.volcano.sh' "${TMP}/render.yaml" \
    || fail "Volcano Job CRD not rendered"
pass "Volcano Job CRD rendered"

if grep -q -- '--scheduler-name=' "${TMP}/render.yaml"; then
    fail "values must not globally override custom.scheduler_name (per-job hami-scheduler)"
fi
pass "no global scheduler-name override"

# ---------- image plan ----------
"${HELPER}" --chart "${CHART}" --registry "${REG}" --image-tag v1.16.0 --print-images \
    > "${TMP}/images.tsv" || fail "volcano-values.sh --print-images failed"
[ "$(wc -l < "${TMP}/images.tsv")" -eq 3 ] || fail "image plan must contain 3 images"
grep -qP '^docker\.io/volcanosh/vc-controller-manager\tv1\.16\.0\tmirrors/docker\.io/volcanosh/vc-controller-manager\tv1\.16\.0\tm\.daocloud\.io/docker\.io/volcanosh/vc-controller-manager:v1\.16\.0$' "${TMP}/images.tsv" \
    || fail "controller image plan entry wrong"
grep -qP '^docker\.io/volcanosh/vc-scheduler\tv1\.16\.0\tmirrors/docker\.io/volcanosh/vc-scheduler\tv1\.16\.0\tm\.daocloud\.io/docker\.io/volcanosh/vc-scheduler:v1\.16\.0$' "${TMP}/images.tsv" \
    || fail "scheduler image plan entry wrong"
grep -qP '^docker\.io/volcanosh/vc-webhook-manager\tv1\.16\.0\tmirrors/docker\.io/volcanosh/vc-webhook-manager\tv1\.16\.0\tm\.daocloud\.io/docker\.io/volcanosh/vc-webhook-manager:v1\.16\.0$' "${TMP}/images.tsv" \
    || fail "admission image plan entry wrong"
pass "image plan lists exactly the 3 expected pushes via m.daocloud.io"

"${HELPER}" --chart "${CHART}" --registry "${REG}" --image-tag v1.16.0 \
    --image-source upstream --print-images > "${TMP}/images-upstream.tsv" \
    || fail "volcano-values.sh --image-source upstream failed"
grep -qP '^docker\.io/volcanosh/vc-scheduler\tv1\.16\.0\tmirrors/docker\.io/volcanosh/vc-scheduler\tv1\.16\.0\tdocker\.io/volcanosh/vc-scheduler:v1\.16\.0$' "${TMP}/images-upstream.tsv" \
    || fail "upstream image source should not be prefixed"
pass "upstream image source override works"

# ---------- module list mode ----------
( cd "${ROOT}" && VOLCANO_LIST_IMAGES=true VOLCANO_IMAGE_MODE=online bash "${MODULE}" ) \
    > "${TMP}/module-list.txt" 2>&1 || { tail -20 "${TMP}/module-list.txt" >&2; fail "module list mode failed"; }
grep -q "m.daocloud.io/docker.io/volcanosh/vc-controller-manager:v1.16.0" "${TMP}/module-list.txt" \
    && grep -q "m.daocloud.io/docker.io/volcanosh/vc-scheduler:v1.16.0" "${TMP}/module-list.txt" \
    && grep -q "m.daocloud.io/docker.io/volcanosh/vc-webhook-manager:v1.16.0" "${TMP}/module-list.txt" \
    || fail "module list mode missing images"
pass "module image list mode works without cluster access"

# ---------- uninstall branch position ----------
act_line="$(grep -n 'CUBESTACK_MODULE_ACTION:-install' "${MODULE}" | head -1 | cut -d: -f1 || true)"
toggle_line="$(grep -n 'VOLCANO_ENABLED:-false' "${MODULE}" | head -1 | cut -d: -f1 || true)"
[ -n "${act_line}" ] || fail "module has no uninstall branch"
[ -n "${toggle_line}" ] || fail "module has no VOLCANO_ENABLED toggle check"
[ "${act_line}" -lt "${toggle_line}" ] || fail "uninstall branch must precede TOGGLE check"
grep -q '^# UNINSTALL: 1$' "${MODULE}" || fail "module must declare '# UNINSTALL: 1'"
if grep -qF '${FULL}' "${MODULE}"; then
    fail "module uses undefined \${FULL} (should be \${_FULL})"
fi
pass "uninstall branch declared before TOGGLE check"

# ---------- verify module uses Volcano Job + HAMi scheduler ----------
grep -q 'batch.volcano.sh/v1alpha1' "${VERIFY}" || fail "verify module must create Volcano Job"
grep -q 'schedulerName: hami-scheduler' "${VERIFY}" || fail "verify module must use hami-scheduler"
grep -q 'volcano.sh/job-name' "${VERIFY}" || fail "verify module must wait for Volcano-created pods"
grep -q '_pod_seen' "${VERIFY}" || fail "verify module must wait for Pod creation before Ready"
grep -q 'st.get("phase")' "${VERIFY}" || fail "verify module must read Volcano Job status.state.phase"
pass "verify module uses Volcano Job with hami-scheduler"

echo "all volcano module tests passed"

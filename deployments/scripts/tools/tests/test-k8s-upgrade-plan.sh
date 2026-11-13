#!/bin/bash
# ============================================================
# test-k8s-upgrade-plan.sh — 原地升级纯函数回归
#   · upgrade_plan: patch/one-minor OK; multi-minor/downgrade/major 拒绝
#   · upgrade_etcd_requires_bridge: 3.5(<3.5.26)->3.6 需要桥; 3.6 patch 不需要
# 只用仓库内库函数, 不联网/不碰集群。
# ============================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../../../.." && pwd)"
# shellcheck source=../../kubespray/lib-k8s-upgrade.sh
source "${REPO_ROOT}/deployments/kubespray/lib-k8s-upgrade.sh"

fail=0
chk() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s: expected=[%s] actual=[%s]\n' "$1" "$2" "$3"
        fail=1
    fi
}

chk "1.35.8 -> 1.36.5 (one minor)" "OK:1" "$(upgrade_plan 1.35.8 1.36.5)"
chk "1.35.8 -> 1.35.9 (patch)"     "OK:0" "$(upgrade_plan 1.35.8 1.35.9)"
chk "1.36.5 -> 1.36.5 (same)"      "SAME" "$(upgrade_plan 1.36.5 1.36.5)"
chk "1.34.0 -> 1.36.5 (multi)"     "ERR:multi-minor 2 (1.34.0 -> 1.36.5)" "$(upgrade_plan 1.34.0 1.36.5)"
chk "1.36.5 -> 1.35.8 (downgrade)" "ERR:downgrade 1.36.5 -> 1.35.8" "$(upgrade_plan 1.36.5 1.35.8)"
chk "2.0.0 -> 1.36.5 (major)"      "ERR:major 2.0.0 -> 1.36.5" "$(upgrade_plan 2.0.0 1.36.5)"
chk "empty"                        "ERR:empty" "$(upgrade_plan "" 1.36.5)"
chk "v-prefixed one minor"         "OK:1" "$(upgrade_plan v1.35.8 v1.36.5)"

chk "etcd bridge 3.5.16 -> 3.6.15" "1" "$(upgrade_etcd_requires_bridge 3.5.16 3.6.15)"
chk "etcd bridge 3.5.25 -> 3.6.15" "1" "$(upgrade_etcd_requires_bridge 3.5.25 3.6.15)"
chk "etcd bridge 3.5.26 -> 3.6.0"  "0" "$(upgrade_etcd_requires_bridge 3.5.26 3.6.0)"
chk "etcd bridge 3.6.14 -> 3.6.15" "0" "$(upgrade_etcd_requires_bridge 3.6.14 3.6.15)"
chk "etcd bridge unknown"          "0" "$(upgrade_etcd_requires_bridge "" 3.6.15)"

echo "---------------------------------------------"
if [ "${fail}" = "0" ]; then
    echo "✅ k8s 升级计划回归通过"
    exit 0
fi
echo "❌ k8s 升级计划回归失败"
exit 1

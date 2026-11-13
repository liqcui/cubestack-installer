#!/bin/bash
# ============================================================
# lib-k8s-upgrade.sh — 原地升级的纯函数(无 SSH / 无 ansible, 可单测)
#
# 约束(与 kubespray upgrade-cluster.yml 一致):
#   · 一次只允许升一个小版本(1.35 -> 1.36); patch 升级同一小版本内允许
#   · 不允许降级、不允许跨大版本
#   · etcd 3.5(<3.5.26) -> 3.6 需要桥接; 本库只做判定, 不执行桥接
#
# 被 cubestack-offline.sh source; 也被 tests/test-k8s-upgrade-plan.sh 单测。
# ============================================================

upgrade_ver_lt() {   # <a> <b> -> 0 表示 a < b
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

upgrade_minor() {    # 1.35.8 -> 35
    local v="${1#v}"
    printf '%s' "${v}" | cut -d. -f2
}

upgrade_plan() {     # <current> <target> -> OK:<delta> | SAME | ERR:<reason>
    local cur="${1#v}" tgt="${2#v}"
    [ -n "${cur}" ] && [ -n "${tgt}" ] || { echo "ERR:empty"; return 1; }
    local cmaj tmaj cmin tmin
    cmaj="${cur%%.*}"; tmaj="${tgt%%.*}"
    cmin="$(upgrade_minor "${cur}")"; tmin="$(upgrade_minor "${tgt}")"
    [ "${cmaj}" = "${tmaj}" ] || { echo "ERR:major ${cur} -> ${tgt}"; return 1; }
    if [ "${cmin}" -gt "${tmin}" ]; then
        echo "ERR:downgrade ${cur} -> ${tgt}"; return 1
    fi
    local delta=$((tmin - cmin))
    if [ "${delta}" -gt 1 ]; then
        echo "ERR:multi-minor ${delta} (${cur} -> ${tgt})"; return 1
    fi
    if [ "${delta}" -eq 0 ] && [ "${cur}" = "${tgt}" ]; then
        echo "SAME"; return 0
    fi
    echo "OK:${delta}"
    return 0
}

upgrade_etcd_requires_bridge() {   # <current_etcd> <target_etcd> -> 1/0
    local cur="$1" tgt="$2"
    [ -n "${cur}" ] && [ -n "${tgt}" ] || { echo 0; return 0; }
    if upgrade_ver_lt "${cur}" "3.5.26" && ! upgrade_ver_lt "${tgt}" "3.6.0"; then
        echo 1
    else
        echo 0
    fi
}

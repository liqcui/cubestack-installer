#!/bin/bash
# CubeStack: kubespray 通用升级入口 —— 取树 / 备份 / 换树 / 退休判定 / 重放补丁层。
# 设计: docs/kubespray-v2.32/design.md §3.4 的 9 步 SOP 里, 机械步骤由本脚本执行, 判断处停下交人。
#
# 用法: cubestack-kubespray-upgrade.sh <tag> [选项]
#   <tag>                 目标 kubespray tag, 如 v2.32.1 / v2.33.0
#   --root DIR            部署根, 树在 DIR/kubespray(默认 = 本脚本所在目录, 即仓库内真树)
#   --tree-src DIR        直接用本机已备好的**纯净树**(离线/演练路径), 不联网
#   --no-fetch            禁止联网 clone(必须同时给 --tree-src)
#   --k8s-version V       显式指定目标 Kubernetes(必须在目标树 kubelet_checksums 表内)
#   --line X.Y            取该 minor 线的最高 patch(如 --line 1.35)
#   --keep-k8s-line       保留当前 k8s 线, 取该线最高 patch
#   --refresh             强制按"同线刷新"处理(major.minor 相同)
#   --line-upgrade        强制按"跨线升级"处理(major.minor 变化)
#   --check               只打印计划(mode/目标 k8s/版本面), 不换树、不写文件
#   --set-default         成功后同步更新 cluster.defaults.conf 与 inventory 钉子
#   --force-version-dir   版本目录已存在时删除重建
#   --profile-dir DIR     覆盖 profile 输出目录(默认 <root>/../config/profiles)
#   --defaults-conf FILE  覆盖 cluster.defaults.conf 路径
#
# 默认 Kubernetes 选择(阶段 1): 取目标树 kubelet_checksums 表首 = 该 kubespray
#   版本支持的最高 Kubernetes。--line / --keep-k8s-line / --k8s-version 可覆盖。
#   ⚠ 环境变量 K8S_VERSION 不再作为目标版本(仅在 --keep-k8s-line 时用于识别当前线)。
#
# 退出码: 0 = 换树 + 退休判定 + 重放全部成功
#         1 = 重放有 CONFLICT(停下点名文件; 人工处置后重跑)
#         2 = 参数/环境/前置错误(工作区脏、取树失败、核验不过、rsync 失败…)
#
# 步骤(括号内是 SOP 步号):
#   [1/8] 前置: 工作区干净?(SOP 0)          [2/8] 备份: 旧树 tag + 指纹(SOP 2)
#   [3/8] 取树(SOP 1)                       [4/8] 核验: galaxy 版本 + k8s 钉子(SOP 1)
#   [5/8] 换树, 保留 inventory/local + .venv/ + patch-playbooks/ + ansible 版本自检(SOP 3)
#   [6/8] 退休判定 --check-retired(SOP 6)   [7/8] 重放 --apply(SOP 4)
#   [8/8] 打印后续人工步骤(SOP 5/7/8/9)
#
# ⚠ 时机语义(重要, 不要调换 [6] 与 [7]): --check-retired 的判据是"这棵树已经等于打过之后
#   的样子", 只有**刚换完的纯净树**上跑才有意义。先 --apply 再跑 → 刚打进去的补丁也会报
#   RETIRE(假信号, 分不清"上游吸收了"与"我们刚打的")。详见 cubestack-patch-apply.sh 头部。
# ⚠ 破坏性: [5] 会删除 <root>/kubespray 下除 **inventory/local、patch-playbooks 与 .venv/** 之外的**全部**内容。
#   保留 .venv 的理由: 它是**裸机路径的 ansible 运行环境**(cubestack-offline.sh 的 ensure_venv
#   在没有预装 ansible 时靠它跑), 删了裸机升级后跑不起来。
#   ⚠ 保留 ≠ 不管: 换树后 [5/8] 会拿新树 playbooks/ansible_version.yml 的 minimal_ansible_version
#   与 .venv 实测值比对, 过旧即**停住**(rc=2)—— ansible 大版本换了(如 2.16 → 2.19), 必须依新
#   requirements.txt 重建 venv, 否则陈旧 venv 会顶掉 CLI 镜像的新 ansible, 部署第一个 play 硬失败。
#   保留 patch-playbooks 的理由: 它是**我们自持的注入 play**(cubestack-registry / single-node /
#   cni-restart / preload / install-packages), **不是上游文件** —— 上游任何版本都不带它。
#   cubestack-offline.sh 的 ensure_*_play 只在**文件缺失时**从内置副本重建(且 registry /
#   single-node 两个 play 连内置副本都没有, 见 ensure_registry_play), 故换树丢掉它 = 注入内容
#   退化为脚本内置的旧版(实测 install-packages.yml 的内置副本比树内副本旧), 必须原样保留。
#   保留粒度 = 只保 `inventory/local`(Ruling 15): 树内 `inventory/sample` 是**上游模板**
#   (新集群种子, 见 cubestack-offline.sh:191-192 的 cp -rn), 必须随新树刷新; 本仓库的实盘
#   inventory 在**树外** `deployments/kubespray/inventory/cubestack-cluster`, 不在这里。
#   顺带避开一个真冲突: 上游 `inventory/local/group_vars` 是指向 sample 的**符号链接**, 与本树
#   被物化的真实目录相撞会让 rsync 报 "could not make way for new symlink" 而中止(演练实测)。
# ⚠ 演练安全: tag 只打在"包含 <root> 的那个 git 仓库"里。--root /tmp/xxx 之类的演练根不在
#   任何 git 仓库内 → 打 tag 会**安全跳过**并打印说明, 绝不会动真仓库的 tag。
# ⚠ 只信任 .patch: 换树会丢弃树内的一切手工改动。冲突处置要落到 cubestack-patches/*.patch
#   (重跑本脚本会重新换树)。⚠ 重跑前先落盘(Ruling 14): 换树改写成千上万个**已跟踪**文件,
#   会被 [1] 的全仓库工作区门挡住 → 已换过树就先 `git add` + `git commit` 再重跑。
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SELF_DIR}"
TREE_SRC=""
NO_FETCH=0
CONF="${SELF_DIR}/../config/cluster.conf"
APPLIER="${SELF_DIR}/cubestack-patch-apply.sh"
PATCH_DIR="${SELF_DIR}/cubestack-patches"
CHK_REL="roles/kubespray_defaults/vars/main/checksums.yml"
CONFIG_DIR="${SELF_DIR}/../config"
PROFILE_DIR="${CONFIG_DIR}/profiles"
DEFAULTS_CONF="${CONFIG_DIR}/cluster.defaults.conf"
OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${SELF_DIR}/../offline-files}"
PROFILE_DIR_ARG=""; DEFAULTS_CONF_ARG=""
# 版本选择 / 模式开关(阶段 1)
K8S_ARG=""; K8S_LINE=""; K8S_KEEP_LINE=0; MODE_FORCE=""
CHECK_ONLY=0; SET_DEFAULT=0; FORCE_VERSION_DIR=0

# 树内版本表解析(最高 k8s / 指定线最高 patch)
# shellcheck source=lib-kubespray-tables.sh
source "${SELF_DIR}/lib-kubespray-tables.sh"

say()  { printf '\n=== %s\n' "$*"; }
log()  { printf '  %s\n' "$*"; }
warn() { printf '  !! %s\n' "$*" >&2; }
die()  { printf '\n!! 中止: %s\n' "$*" >&2; exit 2; }

# Ruling 14: "重跑"指引必须**可执行**。换树会改写成千上万个**已跟踪**文件, 直接重跑会被 [1/8] 的
# 全仓库工作区门(`git status --porcelain --untracked-files=no`)挡住 —— 正确姿势是先把换树结果落盘。
rerun_hint() {
    printf '  %s\n' "重跑方式: 更新对应 .patch → **若已换过树, 先 git add + git commit(把换树结果落盘)再重跑**;"
    printf '  %s\n' "          落盘范围 = 整个部署根(如仓库内 deployments/kubespray), **不只是树** —— 冲突处置改的"
    printf '  %s\n' "          cubestack-patches/*.patch 在树外, 漏了就白改(下次换树又丢)。"
    printf '  %s\n' "          未换树的场景(失败发生在 [5/8] 之前)直接重跑本脚本。"
}

usage() {
    cat <<'USAGE'
用法: cubestack-kubespray-upgrade.sh <tag> [选项]
  <tag>                 目标 kubespray tag, 如 v2.32.1 / v2.33.0
  --root DIR            部署根, 树在 DIR/kubespray(默认 = 本脚本所在目录)
  --tree-src DIR        直接用本机已备好的纯净树(离线/演练路径), 不联网
  --no-fetch            禁止联网 clone(必须同时给 --tree-src)
  --k8s-version V       显式指定目标 Kubernetes(必须在目标树表内)
  --line X.Y            取该 minor 线的最高 patch(如 --line 1.35)
  --keep-k8s-line       保留当前 k8s 线, 取该线最高 patch
  --refresh             强制按同线刷新处理(major.minor 相同)
  --line-upgrade        强制按跨线升级处理(major.minor 变化)
  --check               只打印计划, 不换树、不写文件
  --set-default         成功后更新 cluster.defaults.conf 与 inventory 钉子
  --force-version-dir   版本目录已存在时删除重建
  --profile-dir DIR     覆盖 profile 输出目录(默认 <root>/../config/profiles)
  --defaults-conf FILE  覆盖 cluster.defaults.conf 路径
默认 Kubernetes = 目标树 kubelet_checksums 表首(该 kubespray 支持的最高版本)。
退出码: 0 = 成功; 1 = 重放有 CONFLICT; 2 = 参数/环境/前置错误
USAGE
}

# 树内容指纹: 相对路径 + md5 汇总(排除 .venv 大文件与 .git), 用于跨根比较/事后核对
tree_fingerprint() (
    cd "$1" 2>/dev/null || return 2
    find . -path ./.venv -prune -o -path ./.git -prune -o -type f -print0 \
        | sort -z | xargs -0 -r md5sum 2>/dev/null | md5sum | awk '{print $1}'
)

# 取 tag 形参
TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --root)      [ $# -ge 2 ] || die "--root 需要一个目录参数";      ROOT="$2";      shift 2;;
        --tree-src)  [ $# -ge 2 ] || die "--tree-src 需要一个目录参数";  TREE_SRC="$2";  shift 2;;
        --no-fetch)  NO_FETCH=1; shift;;
        --k8s-version) [ $# -ge 2 ] || die "--k8s-version 需要一个版本号"; K8S_ARG="$2"; shift 2;;
        --line)      [ $# -ge 2 ] || die "--line 需要 X.Y";              K8S_LINE="$2";   shift 2;;
        --keep-k8s-line) K8S_KEEP_LINE=1; shift;;
        --refresh)   MODE_FORCE="refresh"; shift;;
        --line-upgrade) MODE_FORCE="line-upgrade"; shift;;
        --check)     CHECK_ONLY=1; shift;;
        --set-default) SET_DEFAULT=1; shift;;
        --force-version-dir) FORCE_VERSION_DIR=1; shift;;
        --profile-dir) [ $# -ge 2 ] || die "--profile-dir 需要一个目录"; PROFILE_DIR_ARG="$2"; shift 2;;
        --defaults-conf) [ $# -ge 2 ] || die "--defaults-conf 需要一个文件"; DEFAULTS_CONF_ARG="$2"; shift 2;;
        -h|--help)   usage; exit 0;;
        -*)          usage >&2; die "未知参数: $1";;
        *)           [ -z "${TAG}" ] || die "多余参数: $1(只接受一个 <tag>)"; TAG="$1"; shift;;
    esac
done
[ -n "${TAG}" ] || { usage >&2; exit 2; }
RAW_ROOT="${ROOT}"
ROOT="$(cd "${ROOT}" 2>/dev/null && pwd)" || die "--root 目录不存在: ${RAW_ROOT}"
TREE="${ROOT}/kubespray"
# profile/defaults/offline 路径跟随 --root(演练根不写仓库；真实部署根 = deployments/kubespray)
BASE_DEPLOY_DIR="$(cd "${ROOT}/.." 2>/dev/null && pwd)" || BASE_DEPLOY_DIR="$(dirname "${ROOT}")"
CONFIG_DIR="${BASE_DEPLOY_DIR}/config"
PROFILE_DIR="${PROFILE_DIR_ARG:-${CONFIG_DIR}/profiles}"
DEFAULTS_CONF="${DEFAULTS_CONF_ARG:-${CONFIG_DIR}/cluster.defaults.conf}"
OFFLINE_ROOT="${OFFLINE_FILES_ROOT:-${BASE_DEPLOY_DIR}/offline-files}"

printf '=== CubeStack kubespray 升级入口 ===\n'
printf '  目标 tag : %s\n' "${TAG}"
printf '  部署根   : %s(树: %s)\n' "${ROOT}" "${TREE}"
printf '  补丁层   : %s\n' "${PATCH_DIR}"
printf '  树改动只认补丁层: 换树会丢弃树内手工改动\n'

# ---------------------------------------------------------------- [1/8] 前置
say "[1/8] 前置检查(SOP 0: 工作区干净?)"
[ -d "${TREE}" ]              || die "树不存在: ${TREE}(用 --root 指定部署根; 演练: --root /tmp/up-rehearsal)"
[ -f "${TREE}/galaxy.yml" ]   || die "不是 kubespray 树(缺 galaxy.yml): ${TREE}"
[ -x "${APPLIER}" ]           || die "缺少重放器: ${APPLIER}"
[ -d "${PATCH_DIR}" ]         || die "缺少补丁目录: ${PATCH_DIR}"
command -v rsync >/dev/null   || die "缺少 rsync"
command -v patch >/dev/null   || die "缺少 patch"
N_PATCH="$(find "${PATCH_DIR}" -maxdepth 1 -name '*.patch' | wc -l)"
log "补丁层: ${N_PATCH} 个 .patch"

# tag 打在"包含 --root 的那个仓库"里 —— 演练根不在仓库内时自然跳过(不动真仓库)
REPO="$(git -C "${TREE}" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "${REPO}" ]; then
    dirty="$(git -C "${REPO}" status --porcelain --untracked-files=no 2>/dev/null)"
    if [ -n "${dirty}" ] && [ "${CHECK_ONLY}" = "1" ]; then
        log "--check: 工作区不干净, 跳过干净门(只读, 不换树)"
    elif [ -n "${dirty}" ]; then
        printf '%s\n' "${dirty}" | head -10 >&2
        printf '  %s\n' "若这些改动正是上一轮换树的产物(成批的树内文件): 那是预期结果 —— git add + git commit 落盘后重跑即可。" >&2
        rerun_hint >&2
        die "git 工作区不干净(上面是前 10 条): 先提交/暂存再升级 —— 换树后未提交的树改动无法找回"
    else
        log "git 工作区干净(仓库: ${REPO})"
    fi
    stray="$(git -C "${REPO}" ls-files --others --exclude-standard -- "${TREE}" 2>/dev/null | head -20)"
    if [ -n "${stray}" ]; then
        warn "树内有未跟踪文件(换树会删除; 备份 tag 只含已提交内容):"
        printf '%s\n' "${stray}" | sed 's/^/     /' >&2
    fi
else
    warn "树不在 git 仓库内(演练路径): 跳过'工作区干净'检查与 tag 备份"
fi

# ---------------------------------------------------------------- [2/8] 备份
say "[2/8] 备份: 旧树 tag + 指纹(SOP 2)"
[ -f "${TREE}/galaxy.yml" ] || die "缺 ${TREE}/galaxy.yml, 无法取旧树版本"
OLD_VER="$(grep -m1 '^version:' "${TREE}/galaxy.yml" | awk '{print $2}')"
[ -n "${OLD_VER}" ] || die "读不出旧树版本: ${TREE}/galaxy.yml"
OLD_FP="$(tree_fingerprint "${TREE}")"
log "旧树版本: ${OLD_VER}"
log "旧树指纹: ${OLD_FP}(相对路径内容摘要, 排除 .venv/.git)"
if [ -n "${REPO}" ] && [ "${CHECK_ONLY}" != "1" ]; then
    BACKUP_TAG="kubespray-${OLD_VER}-cubestack"
    if git -C "${REPO}" rev-parse -q --verify "refs/tags/${BACKUP_TAG}" >/dev/null 2>&1; then
        log "备份 tag 已存在, 跳过: ${BACKUP_TAG}"
    elif git -C "${REPO}" tag "${BACKUP_TAG}"; then
        log "已打备份 tag(在 ${REPO} 内): ${BACKUP_TAG}"
    else
        die "打备份 tag 失败: ${BACKUP_TAG}(回退点缺失, 不继续)"
    fi
    GTREE="$(git -C "${REPO}" rev-parse --verify -q "HEAD:$(realpath --relative-to="${REPO}" "${TREE}")" 2>/dev/null || true)"
    [ -n "${GTREE}" ] && log "旧树 git tree 对象: ${GTREE}(回退: git -C ${REPO} checkout ${BACKUP_TAG} -- <路径>)"
elif [ -n "${REPO}" ]; then
    log "--check: 跳过备份 tag 创建(只读)"
else
    log "无 git 仓库 → 跳过 tag 备份(演练路径); 回退只能靠上面的指纹 + 源树副本"
fi

# ---------------------------------------------------------------- [3/8] 取树
say "[3/8] 取目标树(SOP 1)"
CLONE_DIR=""
cleanup() { [ -z "${CLONE_DIR}" ] || rm -rf "${CLONE_DIR}"; }   # 返回 0: 别让 EXIT trap 的返回值盖掉脚本退出码
trap cleanup EXIT
if [ -n "${TREE_SRC}" ]; then
    RAW_TREE_SRC="${TREE_SRC}"
    TREE_SRC="$(cd "${TREE_SRC}" 2>/dev/null && pwd)" || die "--tree-src 目录不存在: ${RAW_TREE_SRC}"
    [ -f "${TREE_SRC}/galaxy.yml" ] || die "--tree-src 不是 kubespray 树(缺 galaxy.yml): ${TREE_SRC}"
    [ "${TREE_SRC}" != "${TREE}" ] || die "--tree-src 与目标树是同一个目录: ${TREE}"
    log "树来源: ${TREE_SRC}(本地, 不联网)"
elif [ "${NO_FETCH}" = 1 ]; then
    die "--no-fetch 要求同时给 --tree-src(本机不可达时: 在联网机 git clone --depth 1 --branch ${TAG} https://github.com/kubernetes-sigs/kubespray.git /tmp/kubespray-${TAG#v}, 拷入后 --tree-src)"
else
    CLONE_DIR="$(mktemp -d "/tmp/cubestack-kubespray-${TAG//\//-}.XXXXXX")" || die "mktemp 失败"
    log "树来源: 联网 git clone --depth 1 --branch ${TAG} → ${CLONE_DIR}"
    if ! git clone --depth 1 --branch "${TAG}" https://github.com/kubernetes-sigs/kubespray.git "${CLONE_DIR}" >/dev/null 2>&1; then
        die "clone 失败(本机不可达?): 改用 --tree-src 由联网机取后拷入 —— 联网机: git clone --depth 1 --branch ${TAG} https://github.com/kubernetes-sigs/kubespray.git /tmp/kubespray-${TAG#v}; 本机: --tree-src /tmp/kubespray-${TAG#v}"
    fi
    TREE_SRC="${CLONE_DIR}"
fi

# ---------------------------------------------------------------- [4/8] 核验
say "[4/8] 核验目标树(SOP 1)"
NEW_VER="$(grep -m1 '^version:' "${TREE_SRC}/galaxy.yml" | awk '{print $2}')"
[ "${NEW_VER}" = "${TAG#v}" ] || die "galaxy.yml 版本(${NEW_VER}) != 目标 tag(${TAG}) —— 拿错树了"
log "galaxy.yml 版本: ${NEW_VER} == ${TAG}"

# ---- 升级类型: 同线刷新 vs 跨线升级 ----
OLD_LINE="${OLD_VER%.*}"
NEW_LINE="${NEW_VER%.*}"
MODE="refresh"
[ "${OLD_LINE}" = "${NEW_LINE}" ] || MODE="line-upgrade"
if [ -n "${MODE_FORCE}" ] && [ "${MODE_FORCE}" != "${MODE}" ]; then
    die "强制模式 ${MODE_FORCE} 与版本线不符: ${OLD_VER} -> ${NEW_VER} 是 ${MODE}(kubespray ${OLD_LINE} -> ${NEW_LINE})"
fi
log "升级类型: ${MODE}(kubespray ${OLD_LINE} -> ${NEW_LINE})"

# ---- 当前 k8s(用于 --keep-k8s-line 与版本面 diff) ----
CUR_K8S=""
CUR_K8S_FROM=""
if [ -n "${K8S_VERSION:-}" ]; then
    CUR_K8S="${K8S_VERSION}"; CUR_K8S_FROM="环境变量 K8S_VERSION"
elif [ -f "${PROFILE_DIR}/v${OLD_VER}.profile" ]; then
    CUR_K8S="$(grep -m1 -E '^K8S_VERSION=' "${PROFILE_DIR}/v${OLD_VER}.profile" | cut -d= -f2-)"
    [ -n "${CUR_K8S}" ] && CUR_K8S_FROM="当前 profile v${OLD_VER}.profile"
elif [ -f "${CONF}" ]; then
    CUR_K8S="$( ( set +u; . "${CONF}" >/dev/null 2>&1 || true; printf '%s' "${K8S_VERSION:-}" ) )"
    [ -n "${CUR_K8S}" ] && CUR_K8S_FROM="cluster.conf(${CONF})"
fi
CUR_K8S_BARE="${CUR_K8S#v}"
CUR_K8S_LINE="${CUR_K8S_BARE%.*}"

CHK="${TREE_SRC}/${CHK_REL}"
[ -f "${CHK}" ] || die "目标树缺 ${CHK_REL}(版本表), 无法核验"
KUBE_MAX="$(kb_tables_kubelet_max "${CHK}")"
KUBE_LINES="$(kb_tables_kubelet_lines "${CHK}" | tr '\n' ' ')"
[ -n "${KUBE_MAX}" ] || die "解析不出 kubelet_checksums 的版本表: ${CHK}"
V_MIN="$(kb_tables_kubelet_list "${CHK}" | tail -1)"
V_MAX="${KUBE_MAX}"

# ---- 目标 k8s 选择(优先级: --k8s-version > --line > --keep-k8s-line > 表首) ----
K8S_TARGET=""; K8S_FROM=""
if [ -n "${K8S_ARG}" ]; then
    K8S_TARGET="${K8S_ARG#v}"; K8S_FROM="--k8s-version"
elif [ -n "${K8S_LINE}" ]; then
    K8S_TARGET="$(kb_tables_kubelet_max_in_line "${CHK}" "${K8S_LINE}")"
    [ -n "${K8S_TARGET}" ] || die "目标树没有 k8s 线 ${K8S_LINE}; 可用线: ${KUBE_LINES}"
    K8S_FROM="--line ${K8S_LINE}"
elif [ "${K8S_KEEP_LINE}" = "1" ]; then
    [ -n "${CUR_K8S_LINE}" ] || die "--keep-k8s-line 需要当前 k8s 版本(设置 K8S_VERSION 或先有 profile)"
    K8S_TARGET="$(kb_tables_kubelet_max_in_line "${CHK}" "${CUR_K8S_LINE}")"
    [ -n "${K8S_TARGET}" ] || die "当前线 ${CUR_K8S_LINE} 不在新树表内; 可用线: ${KUBE_LINES}"
    K8S_FROM="--keep-k8s-line(${CUR_K8S_LINE})"
else
    K8S_TARGET="${KUBE_MAX}"; K8S_FROM="默认: 新树表首"
fi

if [ "$(kb_tables_kubelet_has "${CHK}" "${K8S_TARGET}")" != "1" ]; then
    die "K8S_VERSION=${K8S_TARGET} 不在 ${TAG} 的 kubelet 表内; 可用: $(kb_tables_kubelet_list "${CHK}" | tr '\n' ' ')"
fi
log "目标 k8s: ${K8S_TARGET}(来源: ${K8S_FROM}; 表范围 ${V_MIN} – ${V_MAX})"
log "当前 k8s: ${CUR_K8S:-未知}(${CUR_K8S_FROM:-无})"

# 环境变量 K8S_VERSION 不再作为目标版本；只在 --keep-k8s-line 时用于识别当前线。
if [ -n "${K8S_VERSION:-}" ] && [ -z "${K8S_ARG}" ] && [ "${K8S_KEEP_LINE}" = "0" ]; then
    warn "环境变量 K8S_VERSION=${K8S_VERSION} 未作为目标版本；默认取新树表首 ${KUBE_MAX}。"
    warn "  要保留当前线: --keep-k8s-line；要指定版本: --k8s-version ${K8S_VERSION}"
fi

if [ "${CHECK_ONLY}" = "1" ]; then
    say "[4/8] --check: 只打印计划, 不换树、不写文件"
    log "升级类型 : ${MODE}"
    log "kubespray: ${OLD_VER} -> ${NEW_VER}"
    log "k8s      : ${CUR_K8S:-未知} -> ${K8S_TARGET}"
    log "可用线   : ${KUBE_LINES}"
    log "将生成   : ${PROFILE_DIR}/${TAG}.profile"
    log "版本目录 : ${OFFLINE_ROOT}/kubespray/${TAG}"
    log "集群动作 : 无(本步骤只准备版本面；原地升级需 cubestack-offline.sh upgrade)"
    exit 0
fi

# ---------------------------------------------------------------- [5/8] 换树
say "[5/8] 换树(SOP 3: 保留 inventory/local + .venv/ + patch-playbooks/)"
warn "破坏性: 将删除 ${TREE} 下除 inventory/local、patch-playbooks 与 .venv/ 之外的全部内容"
KEEP_LIST=""
[ -d "${TREE}/inventory/local" ] && KEEP_LIST="${KEEP_LIST} inventory/local(实盘 inventory 若在树内, 通常在 local/)"
[ -d "${TREE}/patch-playbooks" ] && KEEP_LIST="${KEEP_LIST} patch-playbooks(我们自持的注入 play, 非上游文件)"
[ -d "${TREE}/.venv" ]           && KEEP_LIST="${KEEP_LIST} .venv(ansible 运行环境)"
log "保留:${KEEP_LIST:- (无 —— 该树里没有 inventory/local、patch-playbooks 与 .venv/)}"
[ -d "${TREE}/.venv" ] || warn "该树没有 .venv/: 裸机(ansible 未预装)环境升级后可能需要重建 venv"

# 保留粒度 = inventory/local(Ruling 15): 树内 inventory/sample 是**上游模板**(新集群种子, 见
# cubestack-offline.sh:191-192 的 cp -rn), 必须随新树刷新; 本仓库的实盘 inventory 在树外
# (deployments/kubespray/inventory/cubestack-cluster), 不在这里。
# 顺带避开 F1: 上游 inventory/local/group_vars 是指向 sample 的**符号链接**, 与本树被物化的
# 真实目录相撞会让 rsync 报 "could not make way for new symlink" 而中止 —— 排除 local 后
# 上游那份根本不进来。
# patch-playbooks/ 是**我们的**目录(上游不带同名目录), 换树必须原样保留:
# 它是 cubestack-offline.sh 的 ensure_*_play 注入的 5 个 play 的载体, 而机制**只在文件缺失时**
# 才从内置副本重建(registry / single-node 两个 play 连内置副本都没有) → 丢了就退化为旧版注入内容。
KEPT_INV=0
[ -d "${TREE}/inventory/local" ] && KEPT_INV=1
KEPT_PP=0
[ -d "${TREE}/patch-playbooks" ] && KEPT_PP=1
# 换树前记录 patch-playbooks 指纹, 换树后逐字节复核(保住与否必须**可验证**, 不靠人看)
PP_BEFORE=""
if [ "${KEPT_PP}" = 1 ]; then
    PP_BEFORE="$( (cd "${TREE}/patch-playbooks" && find . -type f -print0 | sort -z | xargs -0 -r md5sum) | md5sum | awk '{print $1}')"
    PP_FILES="$(find "${TREE}/patch-playbooks" -type f | wc -l)"
fi
find "${TREE}" -mindepth 1 -maxdepth 1 ! -name inventory ! -name .venv ! -name patch-playbooks -exec rm -rf {} + \
    || die "删除旧树内容失败: ${TREE}"
[ "${KEPT_INV}" = 1 ] && { find "${TREE}/inventory" -mindepth 1 -maxdepth 1 ! -name local -exec rm -rf {} + \
    || die "清理旧 inventory/(只留 local)失败: ${TREE}/inventory"; }
# ⚠ 排除项一律用**前导 / 锚定到树根**: 不锚定会连 `contrib/terraform/aws/.gitignore` 这类
#   **树内被 git 跟踪的同名文件**一起丢掉(演练实测: 少 4 个, 树 diff 会多出 4 处无谓删除)。
RSYNC_EXCLUDES=(--exclude='/.git' --exclude='/.github' --exclude='/.gitlab-ci' --exclude='/.gitlab-ci.yml'
                --exclude='/.gitattributes' --exclude='/.gitignore' --exclude='/.gitmodules'
                --exclude='/.venv')
[ "${KEPT_INV}" = 1 ] && RSYNC_EXCLUDES+=(--exclude='/inventory/local')
# 上游任何 tag 都不带 patch-playbooks/ → 无条件排除即可(不需要 KEPT_PP 条件)
RSYNC_EXCLUDES+=(--exclude='/patch-playbooks')
rsync -a "${RSYNC_EXCLUDES[@]}" "${TREE_SRC}/" "${TREE}/" \
    || die "rsync 失败(树可能不完整; 用备份 tag / 指纹回退)"
rm -rf "${TREE}/contrib/offline/temp"   # 上游离线脚本的临时目录, 属残留, 不清会跟着树漂移
[ -d "${TREE}/.venv" ]     || warn ".venv/ 不见了: 裸机路径需重建(ansible 未预装时跑不起来)"
for dot in .git .github .gitlab-ci .gitattributes .gitignore .gitmodules; do
    [ -e "${TREE}/${dot}" ] && warn "点文件未被排除干净: ${TREE}/${dot}(检查 rsync excludes)"
done
NEW_FP="$(tree_fingerprint "${TREE}")"
log "换树完成: ${OLD_VER} → ${NEW_VER}(指纹 ${NEW_FP})"
if [ "${KEPT_INV}" = 1 ]; then
    log "树内 inventory/local 原样保留(实盘 inventory 若在树内通常在此; 其余 inventory/ 已被新树替换)"
fi
# 自检(patch-playbooks 保留的直接判据): 文件数 + 逐字节指纹都不能变
if [ "${KEPT_PP}" = 1 ]; then
    PP_AFTER="$( (cd "${TREE}/patch-playbooks" && find . -type f -print0 | sort -z | xargs -0 -r md5sum) | md5sum | awk '{print $1}')"
    PP_FILES_AFTER="$(find "${TREE}/patch-playbooks" -type f | wc -l)"
    if [ "${PP_BEFORE}" = "${PP_AFTER}" ]; then
        log "patch-playbooks/ 原样保留(${PP_FILES} → ${PP_FILES_AFTER} 个文件, 指纹 ${PP_AFTER} 未变)"
    else
        warn "patch-playbooks/ 内容变了(换树没保住?): 指纹 ${PP_BEFORE} → ${PP_AFTER}; 回退见 [2/8] 的备份 tag"
    fi
else
    warn "该树没有 patch-playbooks/: 换树后注入 play 将由 cubestack-offline.sh 的内置副本重建(可能不是最新版)"
fi
# 自检(换树正确性的直接判据): 上游模板 sample 必须已随新树刷新
if [ -d "${TREE_SRC}/inventory/sample" ]; then
    if diff -rq --no-dereference "${TREE}/inventory/sample" "${TREE_SRC}/inventory/sample" >/dev/null 2>&1; then
        log "inventory/sample 已随新树刷新(与 ${TAG} 的模板逐文件一致)"
    else
        warn "inventory/sample 与新树模板不一致(换树未刷干净?): diff -rq --no-dereference ${TREE}/inventory/sample ${TREE_SRC}/inventory/sample"
    fi
fi

# 自检(ansible 大版本, 2026-09-28 评审 I1): 换树**有意保留** .venv(裸机路径的 ansible 运行环境),
#   而新树的 playbooks/ansible_version.yml 会对 ansible-core 版本**硬断言**(v2.32: ≥2.19 <2.20)。
#   陈旧 venv(实测 core 2.16.19)在部署的**第一个 play** 就硬失败; 且 cubestack-offline.sh 的
#   ensure_venv 只判"目录在不在"→ 永远重建不了它, 于是旧 venv 会一直顶掉 CLI 镜像里的新 ansible。
#   故换树后立刻把两侧读出来比一比: 过旧就**停住**(rc=2)并给出修法 —— 别让它留到部署期才炸。
#   ⚠ 判据取新树自己的 ansible_version.yml(不写死 2.19): 换树/换门后本自检自动跟随。
AV_YML="${TREE}/playbooks/ansible_version.yml"
AV_MIN=""
if [ -f "${AV_YML}" ]; then
    AV_MIN="$(sed -n 's/^[[:space:]]*minimal_ansible_version:[[:space:]]*//p' "${AV_YML}" | head -1 | tr -d "\"'")"
fi
if [ -z "${AV_MIN}" ]; then
    warn "读不出新树的 minimal_ansible_version(${AV_YML}): 无法核对 .venv 的 ansible 版本"
fi
AV_HAVE=""
if [ -x "${TREE}/.venv/bin/ansible" ]; then
    AV_LINE="$("${TREE}/.venv/bin/ansible" --version 2>/dev/null | head -1)"
    AV_HAVE="$(printf '%s' "${AV_LINE}" | sed -nE 's/.*\[core ([0-9][0-9.]*)\].*/\1/p')"
    # 老式输出(`ansible 2.9.x`, 无 [core …])也认, 免得把"没版本号"误判成"版本合格"
    [ -n "${AV_HAVE}" ] || AV_HAVE="$(printf '%s' "${AV_LINE}" | sed -nE 's/^ansible[[:space:]]+v?([0-9][0-9.]*).*/\1/p')"
    [ -n "${AV_HAVE}" ] || warn "读不出 .venv 的 ansible 版本(${TREE}/.venv/bin/ansible --version 首行: ${AV_LINE:-空})"
elif [ -d "${TREE}/.venv" ]; then
    warn ".venv/ 在, 但没有可执行的 bin/ansible: 无法核对版本(裸机路径跑不动, 部署前先重建)"
fi
# 版本比较: sort -V 取小者(与上游 assert 的语义一致: 恰好等于门也算通过)
_av_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
if [ -n "${AV_MIN}" ] && [ -n "${AV_HAVE}" ]; then
    if _av_lt "${AV_HAVE}" "${AV_MIN}"; then
        warn ".venv 的 ansible-core ${AV_HAVE} **低于**新树要求(${TAG} 要 ≥ ${AV_MIN})—— 部署第一个 play 就硬失败:"
        warn "  ${AV_YML} 断言 ${AV_MIN} <= ansible < $(sed -n 's/^[[:space:]]*maximal_ansible_version:[[:space:]]*//p' "${AV_YML}" | head -1)"
        warn "  (换树保留 .venv 是有意的 —— cubestack-offline.sh 的 ensure_venv 只判目录在不在, 不会帮你重建)"
        warn "  修法(二选一):"
        warn "    ① 依新 requirements.txt **重建** venv(需要 pip 可达, 联网机/容器内做):"
        warn "         rm -rf ${TREE}/.venv && python3 -m venv ${TREE}/.venv && ${TREE}/.venv/bin/pip install -r ${TREE}/requirements.txt"
        warn "    ② 直接删掉 .venv/: 走 CLI 镜像里预装的 ansible(容器路径就是这条; 裸机路径会在部署时另建)"
        warn "  修完重跑本脚本(会重新换树 + 重放补丁)"
        rerun_hint >&2
        die "[5/8] .venv 的 ansible-core ${AV_HAVE} 过旧(新树 ${TAG} 要求 ≥ ${AV_MIN})—— 修法见上"
    fi
    log ".venv 的 ansible-core ${AV_HAVE} 满足新树要求(≥ ${AV_MIN})"
fi

# ---------------------------------------------------------------- [6/8] 退休判定
say "[6/8] 退休判定 --check-retired(SOP 6, 必须在重放之前)"
log "判据: 反向打干净 = \"这棵树已等于我们打完的样子\" → 上游可能已吸收"
RETIRE_OUT="$(bash "${APPLIER}" --root "${TREE}" --check-retired 2>&1)"; RETIRE_RC=$?
printf '%s\n' "${RETIRE_OUT}"
[ "${RETIRE_RC}" = 0 ] || warn "退休判定退出码 ${RETIRE_RC}(非 0; 见上)"
N_RETIRE="$(printf '%s\n' "${RETIRE_OUT}" | grep -c '^  RETIRE' || true)"
N_KEEP="$(printf '%s\n' "${RETIRE_OUT}" | grep -c '^  KEEP' || true)"
log "RETIRE ${N_RETIRE} 处 / KEEP ${N_KEEP} 处(共 ${N_PATCH} 个补丁)"
if [ "${N_RETIRE}" != 0 ]; then
    log "→ 人工决定删哪些 RETIRE 项(删 = 从补丁层移除该 .patch 并在升级日志里记明); 未删的照旧重放"
fi

# ---------------------------------------------------------------- [7/8] 重放
say "[7/8] 重放补丁层 --apply(SOP 4)"
APPLY_OUT="$(bash "${APPLIER}" --root "${TREE}" --apply 2>&1)"; APPLY_RC=$?
printf '%s\n' "${APPLY_OUT}"
N_APPLY="$(printf '%s\n' "${APPLY_OUT}" | grep -c '^  APPLY' || true)"
N_SKIP="$(printf '%s\n' "${APPLY_OUT}" | grep -c '^  SKIP' || true)"
N_CONF="$(printf '%s\n' "${APPLY_OUT}" | grep -c '^  CONFLICT' || true)"
log "重放结果: APPLY ${N_APPLY} / SKIP ${N_SKIP} / CONFLICT ${N_CONF}(退出码 ${APPLY_RC})"
# patch 默认 --backup-if-mismatch: 补丁"带偏移/fuzz 命中"时会留下 <文件>.orig 备份。
# 那是垃圾文件(patch 前的旧内容), 留着会污染树 diff/被 git add -A 提交进去; 出现本身也是信号
# —— 说明该补丁的上下文行相对新树已漂移, 值得顺手刷新 .patch 的上下文。
ORIG_LIST="$(find "${TREE}" -name '*.orig' -not -path "${TREE}/.venv/*" 2>/dev/null)"
REJ_LIST="$(find "${TREE}" -name '*.rej' -not -path "${TREE}/.venv/*" 2>/dev/null)"
if [ -n "${ORIG_LIST}" ]; then
    warn "重放留下 $(printf '%s\n' "${ORIG_LIST}" | wc -l) 个 .orig 备份(= 带偏移/fuzz 命中, 上下文已漂移), 已清理:"
    printf '%s\n' "${ORIG_LIST}" | sed "s|^${TREE}/|     |" >&2
    printf '%s\n' "${ORIG_LIST}" | xargs -r rm -f
fi
if [ -n "${REJ_LIST}" ]; then
    warn "存在 .rej(有 hunk 没打上):$(printf ' %s' ${REJ_LIST})"
fi
if [ "${APPLY_RC}" != 0 ] || [ "${N_CONF}" != 0 ]; then
    say "[7/8] 停下: CONFLICT ${N_CONF} 处(SOP 5 人工处置)"
    # 区分两种冲突: 目标文件还在(上下文漂移 → 重做改动) 还是 目标文件没了(上游删除/搬迁 → 另判去向)
    printf '%s\n' "${APPLY_OUT}" | grep '^  CONFLICT' | sed 's/^  CONFLICT //' | while read -r line; do
        tgt="${line##*→ }"
        [ -e "${TREE}/${tgt}" ] || printf '  !! 目标文件在新树**不存在**(上游删除/搬迁, 不是上下文漂移): %s\n' "${tgt}"
    done
    printf '  %s\n' "人工处置: 按语义把改动重做到新树 → 更新对应的 cubestack-patches/*.patch(含元数据头)"
    printf '  %s\n' "⚠ 重跑会重新换树: 手工改在树里的内容会丢 —— 改动必须落到 .patch"
    rerun_hint
    printf '  %s\n' "注: 目标文件消失时 --check-retired 会误报 KEEP(反打不上≠上游未吸收), 以人工判断为准"
    exit 1
fi

# ---------------------------------------------------------------- [8/8] 版本面与版本目录 + 后续人工步骤
say "[8/8] 版本面与版本目录(自动; 不动物理集群)"

PROFILE_TMP="$(mktemp)"
PROFILE_OK=0
if [ -x "${ROOT}/cubestack-patch-apply.sh" ]; then
    if OFFLINE_FILES_ROOT="${OFFLINE_ROOT}" bash "${SELF_DIR}/cubestack-version-dir.sh" \
        profile "${TAG}" --from-root "${ROOT}" --k8s-version "${K8S_TARGET}" --out "${PROFILE_TMP}" \
        >/tmp/cubestack-profile.log 2>&1; then
        PROFILE_OK=1
        log "已推导版本面: ${PROFILE_TMP}"
    else
        warn "版本面推导失败(见下); 跳过自动 profile:"
        sed 's/^/     /' /tmp/cubestack-profile.log >&2 || true
    fi
else
    warn "${ROOT} 下无 cubestack-patch-apply.sh(演练根?) → 跳过自动 profile/版本目录"
fi

if [ "${PROFILE_OK}" = "1" ]; then
    # 1) 写仓库 profile
    if mkdir -p "${PROFILE_DIR}" && cp "${PROFILE_TMP}" "${PROFILE_DIR}/${TAG}.profile"; then
        log "已写 profile: ${PROFILE_DIR}/${TAG}.profile"
    else
        warn "写 profile 失败: ${PROFILE_DIR}/${TAG}.profile"
    fi

    # 2) 版本目录(阶段 2: 旧版本目录存在时复制未变资产, 只补变化项)
    VER_DIR="${OFFLINE_ROOT}/kubespray/${TAG}"
    OLD_VDIR="${OFFLINE_ROOT}/kubespray/v${OLD_VER}"
    if [ -e "${VER_DIR}" ] && [ "${FORCE_VERSION_DIR}" != "1" ]; then
        warn "版本目录已存在, 跳过创建: ${VER_DIR}(要重建加 --force-version-dir)"
        OFFLINE_FILES_ROOT="${OFFLINE_ROOT}" bash "${SELF_DIR}/cubestack-version-dir.sh" \
            check-assets "${TAG}" || warn "制品不齐(见上); 补齐后再发布"
    else
        NEW_ARGS=()
        [ "${FORCE_VERSION_DIR}" = "1" ] && NEW_ARGS+=(--force)
        VD_CMD=()
        if [ -d "${OLD_VDIR}" ]; then
            log "以旧版本目录为基线刷新(复制未变资产): ${OLD_VDIR}"
            VD_CMD=(refresh "${TAG}" --from-root "${ROOT}" --assets-from "${OLD_VDIR}" --k8s-version "${K8S_TARGET}")
        else
            VD_CMD=(new "${TAG}" --from-root "${ROOT}" --k8s-version "${K8S_TARGET}")
        fi
        if ! OFFLINE_FILES_ROOT="${OFFLINE_ROOT}" bash "${SELF_DIR}/cubestack-version-dir.sh" \
            "${VD_CMD[@]}" "${NEW_ARGS[@]}"; then
            warn "版本目录创建/刷新失败: ${VER_DIR}"
        else
            log "版本目录: ${VER_DIR}"
            if [ "${VD_CMD[0]}" = "new" ]; then
                OFFLINE_FILES_ROOT="${OFFLINE_ROOT}" bash "${SELF_DIR}/cubestack-version-dir.sh" \
                    check-assets "${TAG}" || warn "制品不齐(见上); 补齐后再发布"
            fi
        fi
    fi

    # 3) 版本面变化(便于阶段 2 备料)
    OLD_PROFILE="${PROFILE_DIR}/v${OLD_VER}.profile"
    if [ -f "${OLD_PROFILE}" ]; then
        log "版本面变化(旧 v${OLD_VER} -> 新 ${TAG}):"
        while IFS='=' read -r k v; do
            case "${k}" in ''|\#*) continue;; esac
            old="$(grep -m1 -E "^${k}=" "${OLD_PROFILE}" | cut -d= -f2- || true)"
            [ -n "${old}" ] && [ "${old}" != "${v}" ] && printf '     %-28s %s -> %s\n' "${k}" "${old}" "${v}"
        done < <(grep -E '^[A-Z][A-Z0-9_]*=' "${PROFILE_TMP}")
        printf '     %s\n' "→ 阶段 2: 按该版本目录补齐/替换镜像与二进制；本步骤不动物理集群。"
    fi

    # 4) 可选: 更新 cluster.defaults.conf + inventory 钉子
    if [ "${SET_DEFAULT}" = "1" ]; then
        if [ -f "${DEFAULTS_CONF}" ]; then
            while IFS='=' read -r k v; do
                case "${k}" in ''|\#*) continue;; esac
                grep -qE "^${k}=\"" "${DEFAULTS_CONF}" || continue
                sed -i -E "s|^(${k}=\"\\\$\\{${k}:-)[^}]*(\}\")|\1${v}\2|" "${DEFAULTS_CONF}"
            done < <(grep -E '^[A-Z][A-Z0-9_]*=' "${PROFILE_TMP}")
            log "已更新 ${DEFAULTS_CONF}(--set-default)"
            if [ "${ROOT}" != "${SELF_DIR}" ]; then
                warn "--set-default: 演练根(ROOT != SELF_DIR)不执行仓库 inventory 同步；仅更新了 ${DEFAULTS_CONF}"
            elif [ -f "${CONF}" ]; then
                if bash "${SELF_DIR}/../scripts/tools/k8s/sync-kubespray-config.sh"; then
                    log "已重新生成 inventory 钉子"
                else
                    warn "inventory 钉子同步失败；请手动跑: bash deployments/scripts/tools/k8s/sync-kubespray-config.sh"
                fi
            else
                warn "未找到 ${CONF}；跳过 inventory 钉子同步(部署前需要 cluster.conf)"
            fi
        else
            warn "未找到 ${DEFAULTS_CONF}"
        fi
    else
        log "未加 --set-default: ${DEFAULTS_CONF} 与 inventory 钉子未改"
        log "  确认后重跑: $0 ${TAG} --set-default (或手工把上面的版本面变化落进 defaults/inventory)"
    fi
fi
rm -f "${PROFILE_TMP}"

say "[8/8] 后续人工步骤(SOP 5/7/8/9)"
SET_DEFAULT_HINT="若未加 --set-default: 把上面的版本面变化写进 cluster.defaults.conf + inventory 钉子"
[ "${SET_DEFAULT}" = "1" ] && SET_DEFAULT_HINT="已按 --set-default 更新 defaults；inventory 钉子请确认"
cat <<EOF
  1) 版本面(SOP 7): 本次目标 k8s = ${K8S_TARGET}(来源: ${K8S_FROM})
     - profile: ${PROFILE_DIR}/${TAG}.profile
     - ${SET_DEFAULT_HINT}
  2) 渲染器对拍(SOP 8): 自持 manifest 渲染器 vs 新树模板(kube-vip 等)
  3) 离线缺口(SOP 8): 按版本面变化补齐/替换镜像与二进制(阶段 2)
  4) 回归(SOP 8): 静态检查 + 补丁 --check + 树 diff + 实机
     - 树 diff:  diff -rq --no-dereference ${TREE} ${TREE_SRC}
  5) 记录(SOP 9): 在 docs/kubespray-upgrade.md 追加一条(旧→新 tag、k8s/插件版本变化、
     冲突与处置、踩的坑、新增的可上游化补丁)
  6) 换树结果**落盘**(仅当树在 git 仓库内): git add -A <部署根> && git commit —— 否则下一次
     运行会被 [1/8] 的工作区门挡住(换树改写了成千上万个已跟踪文件)。⚠ 范围是**整个部署根**
     (仓库内 = deployments/kubespray), **不只是树**: 冲突处置改的 cubestack-patches/*.patch
     在树外, 漏了就白改。
  详见 docs/kubespray-upgrade.md §8
EOF
if [ -n "${REPO}" ]; then
    printf '  需要再跑一次本脚本时:\n'
    rerun_hint
fi

say "完成: ${OLD_VER} → ${NEW_VER}(${MODE}; 目标 k8s ${K8S_TARGET}; 换树 + 退休判定 + 重放全绿)"
printf '  树: %s\n  旧树指纹: %s\n  新树指纹: %s\n  备份 tag: %s\n' \
    "${TREE}" "${OLD_FP}" "$(tree_fingerprint "${TREE}")" "${BACKUP_TAG:-"(无 git 仓库, 未打)"}"
printf '  目标 k8s: %s(%s); profile: %s/%s.profile\n' \
    "${K8S_TARGET}" "${K8S_FROM}" "${PROFILE_DIR}" "${TAG}"
printf '  补丁: APPLY %s / SKIP %s / CONFLICT %s; 退休判定 RETIRE %s / KEEP %s\n' \
    "${N_APPLY}" "${N_SKIP}" "${N_CONF}" "${N_RETIRE}" "${N_KEEP}"
exit 0

# kubespray 升级机制（简化版）

- 日期: 2026-11-13
- 状态: **设计草案 v2（阶段 1 已实现于工作区；不动物理集群）**
- 用户约束:
  1. **不要过度设计**；不引入 bundle 生命周期、多版本并发、补丁快照等新模型。
  2. **v2.32.1 这类同线补丁**：统一视为对 v2.32.0 的小版本刷新，只替换变化的镜像/二进制。
  3. **重点只设计跨线升级**（如 v2.32.x → v2.33.0），并让它自动跟随新 kubespray 支持的最高 Kubernetes。

---

## 1. 现状（只列与升级相关的部分）

| 机制 | 入口 | 现状 |
|---|---|---|
| 换树 | `deployments/kubespray/cubestack-kubespray-upgrade.sh <tag>` | 换树 + 退休判定 + 重放补丁；**不选 k8s、不写 profile、不更新钉子、不造版本目录** |
| 版本目录 | `deployments/kubespray/cubestack-version-dir.sh new <tag> --k8s-version ...` | 打包已打补丁的树；**必须人给 k8s 版本**；只写版本目录内的 profile |
| 部署 | `deploy-cluster.sh` / `cubestack-offline.sh install` | 跨小版本会触发 reset；**没有原地升级** |

结论：今天“升级 kubespray”只换了脚本/角色，Kubernetes 和组件版本不会自动跟随；需要人工把三条链路粘起来。

---

## 2. 设计原则

1. **只分两类升级**，自动判定，不引入第三种模型：
   - **同线刷新**：新 tag 的 `major.minor` 与当前树相同（如 `v2.32.0 → v2.32.1`）。
   - **跨线升级**：`major.minor` 变化（如 `v2.32.x → v2.33.0`）。
2. **一个入口**：扩展现有 `cubestack-kubespray-upgrade.sh`，不再新增编排器。
3. **复用现有工具**：树替换、补丁重放、`cubestack-version-dir.sh new`、`_derive_profile`、`check-modules` ⑯/⑱。
4. **同名/同线资产复用**：同线刷新不重新准备整套制品，以旧版本目录为基线复制未变资产，只替换变化部分。
5. **Kubernetes 版本跟随策略（两类升级统一默认）**：
   - 默认取新树 `kubelet_checksums` 表首（最高 minor + 最高 patch）——**同线刷新也照此执行**。
   - `--keep-k8s-line`：同线刷新时保留当前 k8s 线（取该线最高 patch），用于不想跨 k8s minor 的场景。
   - `--line X.Y` / `--k8s-version V`：显式覆盖。

**明确不做**：bundle 生命周期、BUNDLE.json、补丁快照、staging/promote、多版本并发配置、跨多个小版本一次直跳。这些等真有需求再加。

---

## 3. 两类升级的差异

| 项 | 同线刷新（v2.32.0→v2.32.1） | 跨线升级（v2.32.x→v2.33.0） |
|---|---|---|
| 判定 | 新 tag 的 major.minor == 当前树 | major.minor 变化 |
| 树 | **只应用上游 delta**（同线通常十几~二十几个文件），不整树替换 | **整树替换** + 重放补丁 |
| 默认 K8S | **新树表首（如 1.36.5）**；`--keep-k8s-line` 可保留当前线 | 新树表首（最高线） |
| 组件版本 | 只重算会变的项（通常 etcd/containerd/gateway-api；k8s 不换线时 pause/coredns/crictl 不变） | 全部按新树重算 |
| 版本目录 | 新建 `v2.32.1/`，从 `v2.32.0/` **复制未变资产**，只替换变化项 | 新建 `v2.33.0/`，按新树准备完整制品 |
| 默认值/钉子 | 只改变化项（如 `ETCD_VERSION`） | 改 k8s 线及所有跟随变化的钉子 |
| 集群 | 可选原地升级；同线通常只是 patch | 通常需要 Kubernetes 原地升级（另立变更） |

> 同线刷新优先用 delta 而不是整树替换，是为了避免当前树“符号链接已解引用”布局带来的一次性大 diff；跨线升级本来就换树，沿用现有换树引擎。

---

## 4. 同线刷新（v2.32.0 → v2.32.1）

### 4.1 流程

1. **预检/备份**：工作区干净、树来源可用、旧树指纹、`git tag kubespray-2.32.0-cubestack`。
2. **应用上游 delta**：取 `v2.32.0..v2.32.1` 的文件差异，打到当前树；不整树替换。
3. **重放补丁**：`--check-retired`（在 delta 后的树上）→ `--apply`；有冲突就停。
4. **选择 k8s**：
   - 默认取新树表首（v2.32.1 → 1.36.5）；
   - `--keep-k8s-line`：保留当前 k8s 线，取该线最高 patch；
   - `--line X.Y` / `--k8s-version V`：显式覆盖。
5. **重算组件版本**：用 `_derive_profile` 对新树表求值；只关注变化的项。
6. **新建版本目录 `v2.32.1/`**：
   - 从 `v2.32.0/` 复制未变资产（images/binaries/packages）；
   - 替换变化项（见 4.2）；
   - `tree.tar.gz` 用 delta 后的树重打；`VERSION.profile` 重新生成。
7. **写仓库 profile / 默认值 / inventory**：只改变化项；`check-modules` ⑯/⑱ 校验。
8. **发布**：只同步变化的 tar 到 MinIO/Harbor。

### 4.2 v2.32.1 具体会换什么（默认跟随 1.36.5）

| 项 | 变化 |
|---|---|
| 树 | 22 文件 delta（版本表、etcd check_certs、静态 Pod 优先级、resolvconf、calico CIDR 等） |
| Kubernetes | 1.35.8 → **1.36.5**（kubelet/kubectl/kubeadm 3 个二进制 + 4 个控制面镜像） |
| crictl | 1.35.0 → **1.36.0**（二进制） |
| pause | 3.10.1 → **3.10.2**（镜像） |
| coredns | 1.12.4 → **1.14.2**（镜像） |
| etcd | 3.6.14 → **3.6.15**（二进制 + 镜像） |
| containerd | 2.3.5 → **2.3.7**（二进制） |
| gateway-api | 1.6.2 → **1.6.3**（CRD） |
| calico | 不变（v3.32.2，本地补丁 14/15） |
| 其他插件 | metrics-server / CPA / node-local-dns / nginx / LVP / NFD / CNI / runc / nerdctl / helm / skopeo / yq 均不变；metallb / kube-vip / ceph / rook / CSI 属项目钉子，不变 |
| 已知漂移 | 顺带补 `19-registry-3.1.2.patch`、`20-ansible-control-path.patch` |

> 如果不想跨 k8s minor：`--keep-k8s-line`，此时只换 etcd / containerd / gateway-api（以及可选的 1.35.9 三个 kube 二进制 + 4 个镜像）。
>
> **注意**：同线刷新把 k8s 从 1.35.8 换到 1.36.5，对**运行中的集群**是一次 Kubernetes minor 升级，不是普通 patch。刷新命令负责把新版本/制品准备好；真正滚动集群仍需 `cubestack-offline.sh upgrade`（§6）或 reset + 重装。

---

## 5. 跨线升级（v2.32.x → v2.33.0）

### 5.1 流程

1. **预检/备份**：同线刷新，外加确认 `.venv` 的 ansible-core 满足新树要求。
2. **整树替换**：沿用现有 `cubestack-kubespray-upgrade.sh` 的换树引擎（保留 `inventory/local`、`patch-playbooks/`、`.venv/`）。
3. **补丁**：先 `--check-retired`，再 `--apply`；冲突停下点名。
4. **选择 k8s**：
   - 默认 `tree-max`：取新树 `kubelet_checksums['amd64']` 首键；
   - `--line 1.36`：取该线最高 patch；
   - `--k8s-version v1.36.5`：显式指定（必须在表内）。
5. **推导全套组件版本**：复用 `_derive_profile`（calico/etcd/coredns/pause/ndc/metrics/cpa/nginx/lvp/nfd）。
6. **生成新版本目录 `v2.33.0/`**：`cubestack-version-dir.sh new`，并用新树全量计算需要的二进制/镜像清单。
7. **更新 profile / `cluster.defaults.conf` / inventory 钉子**：k8s 线 + 所有跟随变化的组件。
8. **校验**：补丁、树 diff、`check-modules` ⑯/⑱、版本目录指纹、制品完整性。
9. **发布**：MinIO 新版本目录 + Harbor 新 tag。
10. **集群升级**：另立变更，走原地升级（见 §6）；跨线升级本身只负责“准备好新版本”。

### 5.2 最高 k8s 选择器

在 `deployments/kubespray/lib-kubespray-tables.sh` 增加两个薄函数（复用现有 `kb_tables_kubelet_list`）：

```bash
kb_tables_kubelet_max <tree>                 # 首键 = 最高 minor + 最高 patch
kb_tables_kubelet_max_in_line <tree> <1.36>  # 该线最高 patch
```

写入 profile：

```bash
KUBESPRAY_VERSION=v2.33.0
K8S_VERSION=v1.36.5
K8S_VERSION_MODE=tree-max        # 或 line / explicit
# K8S_VERSION_MODE=explicit 时，另写一行原因
K8S_VERSION_REASON=...
```

`check-modules` ⑯ 保留“成员判定”；新增：`K8S_VERSION_MODE=tree-max` 时断言 `K8S_VERSION == kb_tables_kubelet_max`。

---

## 6. Kubernetes 原地升级（另立变更，不在本次实现）

跨线升级只负责把新版本准备好；真正把 1.35 集群滚到 1.36 需要独立的 `upgrade` 能力：

```
cubestack-offline.sh upgrade <cluster> --to <k8s-ver> [--check] [--yes]
```

最小设计：

1. **预检**：当前 apiserver 版本、目标版本、版本阶梯（一次一个小版本）、制品是否齐全、etcd 版本、集群健康、备份点。
2. **执行**：每一步跑上游 `playbooks/upgrade_cluster.yml -e kube_version=<step>`；每步后写 checkpoint。
3. **验收**：apiserver/etcd/nodes/CNI/CoreDNS/registry 健康。
4. **回滚**：kubeadm 不支持降级；依赖 etcd 快照 + 节点/VM 快照（或节点重建）。没有备份点不给 `--yes`。
5. **防误 reset**：`06_k8s_deploy.sh` / `cmd_install` 在升级模式下跳过 `reset-old-cluster.sh`。

> 1.35→1.36 是一步小版本，kubeadm 允许；etcd 3.6.14→3.6.15、containerd 2.3.5→2.3.7 属 patch，允许随行。
> etcd 3.5→3.6 的桥不在本次范围。

---

## 7. 需要改的文件（按实现阶段）

| 阶段 | 文件 | 变更 |
|---|---|---|
| 1 | `deployments/kubespray/lib-kubespray-tables.sh` | 新增 `kb_tables_kubelet_max` / `max_in_line` |
| 1 | `deployments/kubespray/cubestack-kubespray-upgrade.sh` | 增加 `--k8s-version/--line/--refresh/--line-upgrade`；自动判定两类升级；换树后自动推导 profile/版本目录/默认值 |
| 1 | `deployments/kubespray/cubestack-version-dir.sh` | `new` 的 `--k8s-version` 变为可选（默认表首）；支持“从旧版本目录复制未变资产”的刷新模式 |
| 2 | `deployments/config/profiles/v2.33.0.profile` | 新版本时生成；`check-modules` ⑱ 校验 |
| 2 | `deployments/config/cluster.defaults.conf` | k8s 线 + 跟随变化的组件钉子 |
| 2 | `deployments/kubespray/inventory/.../k8s-versions.yml` | 重新生成 |
| 2 | `deployments/scripts/tools/check-modules.sh` | 新增 `K8S_VERSION_MODE` 断言、制品完整性断言 |
| 3 | `deployments/kubespray/cubestack-offline.sh` | 新增 `upgrade` 子命令（另立变更） |
| 3 | `deployments/scripts/modules/02_k8s/06_k8s_deploy.sh`、`reset-old-cluster.sh` | 升级模式跳过 reset（另立变更） |
| 3 | `docs/cluster-upgrade-path.md` | 从“未实现”更新为实际实现后的 runbook（另立变更） |

---

## 8. 校验

- `cubestack-patch-apply.sh --check` rc=0。
- `check-modules.sh` 全绿（⑮ 补丁、⑯ 钉子、⑱ 版本目录）。
- 同线刷新：`v2.32.1/tree.tar.gz` 指纹正确；变化制品齐全；未变资产与 v2.32.0 一致。
- 跨线升级：新 profile 与树表逐项一致；`K8S_VERSION_MODE=tree-max` 时为表首；版本目录关键二进制与 k8s 版本匹配。
- 树 diff：同线刷新只应出现 delta 文件；跨线升级只应出现补丁目标文件 + 已知结构差异。

---

## 9. 实施顺序

| 阶段 | 内容 | 是否动集群 |
|---|---|---|
| **1（已实现）** | 最高版本选择器 + 两类升级判定 + 自动推导 profile/版本目录 + 默认值更新 | 否 |
| **2（已实现）** | 版本目录刷新（复制未变资产）+ 制品完整性校验 + MinIO/Harbor 变化项发布 | 否 |
| **3（已实现；待 lab 验收）** | Kubernetes 原地升级（`cubestack-offline.sh upgrade`）+ 健康检查/回滚 | 是（lab） |
| **4** | 文档/CI（可选） | 否 |

> **阶段 1 实现说明（2026-11-13）**：`lib-kubespray-tables.sh` 增加 `kb_tables_kubelet_max` /
> `max_in_line` / `lines`；`cubestack-version-dir.sh` 新增 `profile` 子命令，`new` 默认取表首；
> `cubestack-kubespray-upgrade.sh` 新增 `--k8s-version` / `--line` / `--keep-k8s-line` /
> `--refresh` / `--line-upgrade` / `--check` / `--set-default`，并在 [8/8] 自动生成 profile 与
> 版本目录骨架（tree.tar.gz + VERSION.profile）。回归：`tests/test-kubespray-upgrade-modes.sh`。
>
> **阶段 2 实现说明（2026-11-13）**：`cubestack-version-dir.sh` 新增 `refresh`（以旧版本目录为基线
> 复制未变资产，排除旧 tree/profile/README）与 `check-assets`（按树表 + `images.manifest` 列出
> 缺失/多余制品，`verify --full` 复用）；`sync-to-minio.sh --version <tag>` 只同步单个版本目录。
> 升级脚本 [8/8] 在旧版本目录存在时自动 `refresh`，并输出缺件清单与补齐/发布命令。
> 镜像工具在 `KUBESPRAY_VERSION`/`KUBESPRAY_PROFILE` 下自动加载对应 profile，避免用仓库旧
> defaults 同步出旧 tag。
>
> **阶段 3 实现说明（2026-11-13）**：`cubestack-offline.sh upgrade`（默认 dry-run；预检/阶梯/
> etcd 桥判定/健康检查/etcd 快照/状态文件/`upgrade-cluster.yml`）、`deploy-cluster.sh --upgrade`
> （直接转底层入口，跳过常规模块与 reset）、`06_k8s_deploy.sh` / `cmd_install` 的升级模式 reset
> 守卫、`lib-k8s-upgrade.sh` 纯函数与 `test-k8s-upgrade-plan.sh` 回归。限制：一次一个小版本、
> 不支持降级、etcd 3.5→3.6 桥未实现。

---

## 10. 开放问题

1. **同线刷新的版本目录命名**：是新建 `v2.32.1/`（复制 v2.32.0 未变资产，推荐，保持 tag=目录名），还是继续用 `v2.32.0/` 并在里面标 `UPSTREAM_TAG=v2.32.1`？
2. **树布局**：是否在跨线升级前做一次“符号链接归一化”？做了一次性 diff 大，但以后每次换树 diff 很小；不做就继续用 delta/现有布局。
3. **原地升级的 lab/回滚**：是否有 1.35.8 lab 集群、裸金属还是 VM、能否提供 etcd/节点快照？这决定阶段 3 的实现与验收。

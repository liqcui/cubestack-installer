# 发布方案整改清单与设计（cubestack-release 单轨发布）

- 状态：草案（2026-11-20）
- 适用：2.1+（`release-2.1` 及后续版本线）
- 关联文档：`docs/release-management.md`、`cubestack-release/docs/release-runbook.md`
- 目标：把当前“双轨 + 拼装”的发布方式收敛为**单一事实源、完整闭包、不可变、可复现、可验证**的发布流程

---

## 1. 背景与结论

2.1 起，部署模块（`modules/`）已经迁移到 `cubestack-release`，installer 只负责部署引擎。
但 operator 相关配置、旧 release 定义和旧同步流水线仍留在 `cubestack-installer` 的分支上，
形成“代码一仓、配置一仓、发布物一仓”的三方耦合。

除了“配置文件与代码分离”，本次审计还确认了以下结构性问题：

1. 双轨发布并存，同一个版本号存在两套不一致的 pin；
2. 发布锁不覆盖 operator 的 embedded catalog，运行时依赖图不完整；
3. `_SUCCESS` / `SHA256SUMS` 不绑定发布锁，交付树可能“自洽地错误”；
4. 交付树无法由发布锁复现；
5. installer、release、operator、mirror 四仓没有跨仓契约与 CI；
6. 验证只到文件/哈希层，没有真实安装闭环；
7. 不可变与原子发布不足，旧链路可以原地覆盖已发布树；
8. 分支/base 线治理混乱（同一时刻存在多条 base 线）；
9. Harbor/MinIO 双存储与凭据拓扑缺少统一前置检查。

本文给出目标流程、数据契约、整改清单、验收门禁和迁移步骤。

---

## 2. 现状证据

### 2.1 同一个 2.1.0，两套 pin

| 项目 | `cubestack-release/release-locks/2.1.0.yaml` | 当前 `/data/offline-files` 版本树 |
|---|---|---|
| 生成信息 | `frozen_at=2026-11-19`、`pins_commit=b24f248` | `release.json built_at=2026-11-18`、`git_commit=5871811` |
| operator commit | `ac48dd0` | `5d0c15c` |
| operator chart | `2.1.0-shaac48dd0` | `2.1.0-sha5d0c15c` |
| base | `base-2026.11.18` | `base-2026.10` |
| CLI image | `...cli@sha256:4e7a449...` | `...cli@sha256:dc2afae...` |
| CLI tar sha | 锁只记录 image digest | `dd426b00...` |

结论：版本号 `2.1.0` 不是不可变发布身份；锁与树之间没有双向引用。

### 2.2 发布锁缺少 operator 运行时闭包

- `release-locks/2.1.0.yaml` 的 components 只有：
  `cubepilot`、`cuberouter`、`cubestack-controller-manager`、`cubestack-operator`、
  `cubestack-portal`、`dev-lab`、`model-collection`。
- `components/cubestack-operator.yaml` 的 `artifacts.images` 只有 operator 本体和两个
  BMC exporter；没有 operator embedded catalog 管理的
  `lws`、`ai-gateway`、`envoy-gateway`、`prometheus`、`perses`、`cubestack-docs` 等组件。
- 交付树中对应目录为空：

```text
offline-files/cubestack-operator/
  ai-gateway/        0 files
  envoy-gateway/     0 files
  lws/               0 files
  perses/            0 files
  prometheus/        0 files
```

- `release.yaml` / `tree.tsv` 中也没有这些组件的镜像条目；installer 的 operator 模块只推送
  “实际存在的 tar”，因此这些镜像从未进入集群 registry。

### 2.3 交付树完整性可能“自洽地错误”

曾出现：宿主树的 operator tar 是旧 tag（`sha-ac48dd0`），而 `release.yaml` / `tree.tsv`
要求 `sha-5d0c15c`；`SIZES` / `SHA256SUMS` / `_SUCCESS` 记录的是旧 tar 的 size/digest。
容器验证只能通过 bind mount 覆盖 tar 与元数据才通过。

根因：旧 `sync-release-images.yml` 支持按组件原地覆盖 tar/chart，而 `_SUCCESS`/清单不会
随 `release.yaml`/锁一起重算，也不绑定发布锁的 digest。

### 2.4 双轨发布并存

- `deployments/releases/2.0.0|2.0.1/{release.env,release-images.tsv,components.tsv}`
  只存在于 `release-2.0` 分支；
- `main` 上仍保留 `.github/workflows/sync-release-images.yml` 与
  `.github/workflows/release-tag-bump.yml`，它们仍会写 `deployments/releases/*`；
- 同时 `cubestack-release` 已有 `release-locks/`、`components/`、`base-locks/`、
  release-store、`compose/package/fetch-offline/deliver`。

两套流程都能写同一版本前缀，没有互斥门禁。

### 2.5 跨仓无契约

- release modules 运行时 source installer 的 `lib-common.sh`；
- release lock 分别 pin `modules` tar 与 `cli` image，但没有测试“这一对组合”能一起工作；
- installer CI 的 `check-modules.sh` 只覆盖基线模块（当前 45 个），不覆盖 release modules；
- operator catalog 变化不会触发 release 仓库的任何检查；
- installer 的 `cluster.defaults.conf` / `cluster.conf.example` 仍包含
  `CUBESTACK_OPERATOR_*` 配置，operator 模块在 release 仓库，chart/catalog 在 operator 仓库。

### 2.6 验证范围不足

- `cubestack-release/src/cubestack_release/commands/verify.py` 只校验 `components/*.yaml`
  的 schema、镜像名唯一性、digest 一致性；不读取 operator catalog；
- `tools/fetch-offline.sh --verify` 只校验 `offline-files/SHA256SUMS` 与 `_SUCCESS` 绑定；
- `verify_cubestack_operator` 的冒烟 CR 显式禁用全部组件，只验证 operator/CRD/镜像来源；
- `deliver.yml` 主要跑 `--list-steps` + 离线校验，不做真实集群全量安装。

---

## 3. 设计目标与原则

1. **单一事实源**：`cubestack-release` 是发布锁、组件 pin、base pin、交付树的唯一来源；
   installer 不再维护版本定义，也不再提供第二条同步流水线。
2. **完整闭包**：发布锁必须描述运行时完整依赖，包括 operator embedded catalog 中的所有
   镜像、chart、CRD 和组件默认值。
3. **不可变**：一个发布 build id 对应唯一一组制品；已发布前缀禁止原地覆盖。
4. **可复现**：给定发布锁和 release-store，能 1:1 重建交付树并通过完整校验。
5. **原子发布**：先写 staging 前缀，完整校验后切换 stream 指针；失败不暴露半成品。
6. **契约先行**：跨仓（installer / release / operator / mirror）通过版本化数据契约和
   CI 契约测试协作，不靠人工同步。
7. **失败关闭**：缺镜像、缺 chart、缺凭据、锁/树不一致都必须让发布或安装失败，
   不能只告警后继续。
8. **可观测/可审计**：任何交付物都能回答“哪个 build、哪组 pin、哪个 lock digest、
   哪个 manifest digest、由谁在何时生成”。

---

## 4. 目标发布流程

```text
┌────────────────────┐
│ cubestack-operator │  构建 operator 镜像 + chart
│ (catalog embedded) │  ──────────────┐
└────────────────────┘                │
                                      ▼
┌────────────────────┐    ┌──────────────────────────────┐
│ container-image-   │───▶│ cubestack-release            │
│ mirror (第三方镜像) │    │ 1. 提取 operator catalog     │
└────────────────────┘    │ 2. 生成 platform 组件清单    │
                          │ 3. 合并 components / base    │
                          │ 4. 生成 release lock         │
                          │ 5. compose release.yaml      │
                          │ 6. fetch Harbor → store      │
                          │ 7. package → staging         │
                          │ 8. verify → promote/stream   │
                          └──────────────┬───────────────┘
                                         │
                                         ▼
                          ┌──────────────────────────────┐
                          │ release-store (MinIO)        │
                          │ lines/<line>/releases/<ver>  │
                          │ + snapshot/stream 指针       │
                          └──────────────┬───────────────┘
                                         │ deliver / fetch-offline
                                         ▼
                          ┌──────────────────────────────┐
                          │ 交付树                       │
                          │ offline-files/ + modules/ +   │
                          │ cli tar + release.* + tree.tsv│
                          └──────────────┬───────────────┘
                                         │
                                         ▼
                          ┌──────────────────────────────┐
                          │ cubestack-installer          │
                          │ 校验 → 部署 → 真实 CR 验证   │
                          └──────────────────────────────┘
```

### 4.1 发布身份

建议在锁和交付树中同时记录：

```yaml
build:
  id: 2.1.0+20261120T101500Z.b24f248   # 版本 + 构建时间 + pins commit
  lock_digest: sha256:...
  tree_manifest_sha256: sha256:...
  pins_commit: b24f248
  produced_by: cubestack-release@<commit>
```

- `build.id` 是唯一发布身份；同一版本号可以有多个 build，但发布物必须引用 build id。
- `_SUCCESS` 改为 JSON，至少包含 `build_id`、`lock_digest`、`tree_manifest_sha256`。
- stream 指针记录 `build_id` 与 `manifest_sha256`，deliver 只按指针组装。

### 4.2 发布锁闭包

锁中新增 `platform_catalog`（或生成等价的 `platform-images.tsv` / `platform-charts.tsv`）：

```yaml
platform_catalog:
  source:
    operator_image: <harbor>/suanova-private/cubestack-operator@sha256:...
    catalog_digest: sha256:...
  components:
    lws:
      images:
        - name: lws
          ref: <harbor>/mirrors/registry.k8s.io/lws/lws@sha256:...
          tag: v1.0.0
          dest: offline-files/cubestack-operator/lws
    ai_gateway:
      images:
        - name: ai-gateway-controller
          ref: <harbor>/mirrors/docker.io/envoyproxy/ai-gateway-controller@sha256:...
          tag: v1.2.0
          dest: offline-files/cubestack-operator/ai-gateway
    # prometheus / perses / envoy-gateway / cubestack-docs 同理
```

`compose` 把 `platform_catalog` 展开为 `release.yaml` 的 component image 条目和
`tree.tsv` 行；`fetch-offline` 按 `tree.tsv` 组装；installer 的 operator 模块按现有
`release.yaml` 名称/tag 推送，不需要改推送算法。

---

## 5. 整改清单

### P0（必须先做，当前已造成实际故障）

#### P0-1 收敛为单轨发布

- **问题**：installer 旧 release 定义 + 旧 sync/tag-bump workflow 与 cubestack-release 并存。
- **改动**：
  - `cubestack-installer`：
    - 删除或禁用 `.github/workflows/sync-release-images.yml`、
      `.github/workflows/release-tag-bump.yml`；
    - 在 `deployments/releases/` 上增加 CI 守卫（存在即失败，或只读归档）；
    - `docs/release-management.md` 明确“2.1+ 唯一发布入口是 cubestack-release”。
  - `cubestack-release`：
    - `docs/release-runbook.md` 增加“唯一事实源”声明和旧链路迁移说明。
- **验收**：
  - `rg "sync-release-images|release-tag-bump"` 不再命中活跃 workflow；
  - 任何 PR 修改 `deployments/releases/*` 都会被 CI 拒绝（2.1+ 分支）；
  - release-2.0 只保留只读历史，不再接收新发布。

#### P0-2 发布锁覆盖 operator catalog

- **问题**：锁/清单/树缺 operator 管理的组件镜像和 chart。
- **改动**：
  - 新增 `cubestack-release/tools/extract-operator-catalog.py`（或
    `src/cubestack_release/commands/operator_catalog.py`）：
    - 输入：operator 镜像 digest（从 component pin 取）；
    - 从镜像的 `assets/` / `--catalog-dir` 提取 catalog（组件名、image refs、
      chart refs、默认 version）；
    - 输出确定性的 `platform-catalog.yaml`（排序、去重、带 digest）。
  - `components/cubestack-operator.yaml`：增加 catalog 产物引用，或由 `compose` 自动合并
    生成的 `artifacts.images` / `current.images`；
  - `src/cubestack_release/commands/compose.py`：把 platform catalog 展开进
    `release.yaml` 和 `tree.tsv`；
  - `src/cubestack_release/commands/verify.py`：断言 catalog 中每一个 image/chart
    都在 components/tree 中有对应条目；
  - `release-locks/2.1.0.yaml`：重新生成（或新版本/新 build），包含
    `platform_catalog`。
- **验收**：
  - `offline-files/cubestack-operator/{lws,ai-gateway,envoy-gateway,prometheus,perses}`
    非空；
  - `release.yaml` / `tree.tsv` 覆盖 catalog 全部镜像；
  - `verify` 在缺任一 catalog 镜像时失败；
  - 容器 b 全量安装后，这些组件无 `ImagePullBackOff`。

#### P0-3 绑定发布身份，禁止原地覆盖

- **问题**：`_SUCCESS`/`SHA256SUMS` 不绑定锁；旧同步可以原地改已发布树。
- **改动**：
  - `release-locks` schema（`schema/release-manifest.schema.json` 等）增加 `build` 段；
  - `package.py`：写 `_SUCCESS` JSON（`build_id`/`lock_digest`/`tree_manifest_sha256`）；
  - `fetch-offline.sh --verify`：校验 `_SUCCESS` 中的 `lock_digest` 与 `tree.tsv`
    manifest；
  - 发布流程改为 staging 前缀 → 校验 → promote；
  - 禁止对已存在 `_SUCCESS` 的前缀做组件级覆盖；更新必须新 build id。
- **验收**：
  - 由锁 + store 组装的树与 `tree_manifest_sha256` 完全一致；
  - 尝试向已发布前缀写文件失败；
  - 篡改 `tree.tsv`/tar 后 `--verify` 失败。

### P1（发布可信度与跨仓协作）

#### P1-1 跨仓契约 CI

- **问题**：CLI image、modules tar、operator catalog、release lock 分别 pin，但没有组合测试。
- **改动**：
  - 在 `cubestack-release` 或独立 workflow 增加 contract job：
    - 输入：`cli.image` digest、`modules` digest、`operator` digest、`release lock`；
    - 启动一个 disposable 集群（kind / 单节点 VM）；
    - 执行 `fetch-offline` 组装 → `verify-offline-files` → `deploy-cluster.sh --release`；
    - 断言 `csc Ready=True`、所有组件镜像存在、无 `ImagePullBackOff`。
  - installer CI 增加 release modules 的 `bash -n` / `check-modules`（如果模块合并在
    installer 运行，需覆盖 release modules 根）。
- **验收**：任一仓的破坏性变更会在 PR 阶段失败；nightly 也运行同一 contract。

#### P1-2 真实安装 E2E 门禁

- **问题**：`deliver.yml` 只做组装/离线校验，不验证真实部署。
- **改动**：
  - `deliver.yml` 增加 `verify_level=install`（或独立 workflow）：
    - 组装交付树；
    - 在 disposable 环境全量安装；
    - 执行 `verify_cubestack_operator` 的真实 CR 版本（不能全组件禁用）；
    - 收集 `csc`、Pod、registry catalog 摘要。
- **验收**：release candidate 必须通过该门禁才能 promote 到 stable。

#### P1-3 operator 配置归属

- **问题**：operator 配置分散在 installer `cluster.defaults.conf`、release modules、operator CRD。
- **改动**：
  - 区分“部署运行期旋钮”（namespace/release/offline dir）与“组件/版本默认值”；
  - 后者从 installer 移到 release/operator 仓库，或由 operator catalog 生成；
  - `cluster.defaults.conf` 只保留部署旋钮，并加注释指向 release 锁；
  - 增加一个配置 schema/兼容性检查（installer 启动时校验 release 锁版本）。
- **验收**：installer 仓库不再出现 operator 组件版本/镜像 pin；
  `rg CUBESTACK_OPERATOR_*` 只剩运行期旋钮。

#### P1-4 凭据与双存储前置检查

- **问题**：Harbor 两组凭据 + MinIO 凭据，缺一组会导致部分组件/制品缺失。
- **改动**：
  - 定义统一凭据契约（`HARBOR_*` / `CUBESTACK_OPERATOR_HARBOR_*` / `MINIO_*`）；
  - release pipeline 启动前 preflight：逐个仓库 `skopeo inspect` + MinIO 写权限；
  - installer 在 release 模式启动时校验 CLI tar、modules、registry 凭据；
  - 失败关闭，不生成半成品。
- **验收**：缺凭据时在打包/安装开始前失败，错误信息指出具体仓库/项目。

### P2（治理与长期质量）

#### P2-1 镜像名/路径唯一性

- `verify.py` 已检查 component 内镜像名唯一；扩展到全局 `<component>:<name>` 唯一；
- `release_image_push_ref_by_name` 依赖名字全局唯一，增加显式断言；
- 对同名不同 tag、同一 tag 不同 digest 做拒绝。

#### P2-2 分支/base/版本治理

- `release-2.1` 作为 2.1 线的唯一发布分支；feature 分支不产出正式发布锁；
- base 线版本号不可回退；锁冻结后只能新建 build/版本；
- 文档化 `base-2026.x` 与 release lock 的对应关系；
- 禁止在同一版本号下重新 freeze 不同 pin。

#### P2-3 发布审计与可观测性

- `release.yaml` / `release.json` 增加 `build`、`pins_commit`、`lock_digest`、
  `catalog_digest`、`cli.digest`、`modules.digest`；
- 提供一条 `cubestack-release inspect <version>` 命令输出完整 provenance；
- 可选：对 lock/tree/SHA256SUMS 做签名（cosign/minisign）。

---

## 6. 数据契约草案

### 6.1 发布锁新增字段

```yaml
schema: 2
product: 2.1.0
line: "2.1"
build:
  id: "2.1.0+20261120T101500Z.b24f248"
  pins_commit: b24f248
  lock_digest: sha256:...
  tree_manifest_sha256: sha256:...
  produced_by: "cubestack-release@<commit>"
compat:
  installer_min: "2.1.0"
  modules_api: 1
platform_catalog:
  operator_image: "<harbor>/suanova-private/cubestack-operator@sha256:..."
  catalog_digest: sha256:...
  images: [...]
  charts: [...]
```

### 6.2 `_SUCCESS` 格式

```json
{
  "schema": 1,
  "build_id": "2.1.0+20261120T101500Z.b24f248",
  "lock_digest": "sha256:...",
  "tree_manifest_sha256": "sha256:...",
  "created_at": "2026-11-20T10:15:00Z"
}
```

### 6.3 交付树新增文件

```text
offline-files/
  release.yaml
  release.json
  release.env
  tree.tsv
  platform-catalog.yaml       # 由 operator catalog 生成
  SHA256SUMS
  _SUCCESS                    # JSON，绑定 build/lock/tree
```

---

## 7. 验收门禁矩阵

| 阶段 | 命令 | 通过标准 |
|---|---|---|
| 组件 pin | `cubestack-release verify` | schema、digest、全局镜像名唯一 |
| catalog | `extract-operator-catalog.py --check` | catalog 中每个 image/chart 在锁中有条目 |
| compose | `cubestack-release compose` | 生成 `release.yaml`/`tree.tsv`，无缺项 |
| 拉源 | `fetch-sources` | 所有 `repo@digest` 可拉取，tar 带 RepoTags |
| 打包 | `package` | `_SUCCESS` 绑定 build/lock/tree |
| 组装 | `fetch-offline.sh --verify` | SHA256SUMS + `_SUCCESS` + lock digest 全通过 |
| 安装 | `deploy-cluster.sh --release` | `DEPLOY_RC=0`、`csc Ready=True`、无 ImagePullBackOff |
| 契约 | cross-repo CI | 锁定的 CLI image + modules tar + operator catalog 组合可安装 |

---

## 8. 迁移步骤

### Phase 1：止血（当前 2.1.0 候选）

1. 从当前 operator 镜像提取 catalog，生成 `platform-catalog.yaml`；
2. 把缺失组件镜像补进 `components/cubestack-operator.yaml` / 生成的 catalog；
3. 重新 compose/package 一个新 build（**不要原地改当前树**）；
4. 在容器 b 用新树做全量覆盖安装，确认目标组件无 ImagePullBackOff；
5. 记录当前旧树的 build id，标记为 deprecated。

### Phase 2：门禁上线

1. 禁用 installer 旧 release workflows；
2. `verify.py`/`fetch-offline` 增加 catalog 完整性校验；
3. 上线 cross-repo contract job；
4. `deliver.yml` 增加真实安装门禁。

### Phase 3：清理与治理

1. 删除/归档 `deployments/releases/*`（release-2.0 保留只读）；
2. 把 operator 版本/默认值配置迁出 installer；
3. 更新 `release-management.md` / `release-runbook.md` / `components/README.md`；
4. 建立 base 线与 release 锁的版本对应表。

### 回滚

- 保留上一个 stable 的 `build_id` + lock + tree；
- stream 指针回滚到上一个 `manifest_sha256`；
- 不对已发布前缀做覆盖，回滚只切指针。

---

## 9. 任务清单

> 下列任务按 P0 → P1 → P2 顺序执行；每项完成需附验收证据。

- [ ] **T1（P0-2）** 实现 operator catalog 提取器，输出确定性的 `platform-catalog.yaml`；单测覆盖排序/去重/digest。
- [ ] **T2（P0-2）** 扩展 `compose.py`/`verify.py`，把 catalog 展开进 `release.yaml`/`tree.tsv`，缺项失败。
- [ ] **T3（P0-3）** 扩展 schema/`package.py`/`fetch-offline.sh`，实现 `build.id` 与 `_SUCCESS` 绑定。
- [ ] **T4（P0-1）** 禁用 installer 旧 release workflows，增加 `deployments/releases` 守卫。
- [ ] **T5（P0-2/P0-3）** 重新生成 2.1.0 新 build，在容器 b 全量安装验证；记录 `DEPLOY_RC`、`csc Ready`、镜像覆盖。
- [ ] **T6（P1-1）** 增加 cross-repo contract CI（CLI + modules + operator + lock）。
- [ ] **T7（P1-2）** 增加真实安装 E2E 门禁（csc Ready、无 ImagePullBackOff）。
- [ ] **T8（P1-3）** 迁移/生成 operator 配置，收敛 installer 运行期旋钮。
- [ ] **T9（P1-4）** 统一 Harbor/MinIO 凭据 preflight。
- [ ] **T10（P2）** 全局镜像名唯一性、版本/base 治理、发布 provenance 命令与文档。

---

## 10. 开放决策

1. **catalog 提取位置**：推荐从 operator 镜像的 `assets/` / `--catalog-dir` 提取，
   而不是在 release 仓库手工维护清单；若 operator 暂不提供稳定导出格式，先做
   `components/cubestack-operator.yaml` 的显式列表，并加 drift 检查。
2. **2.1.0 是否重切**：已 freeze 的锁不作为可覆盖对象；建议新 build（同版本号 + build id）
   或新版本号。需要产品侧确认发布语义。
3. **旧 2.0 线支持窗口**：legacy `deployments/releases` 保留只读多久；建议 2.1 GA 后一个
   版本周期内删除。
4. **凭据边界**：是否统一为一组 Harbor 凭据，还是保留 `HARBOR_MIRROR_*` 与
   `CUBESTACK_OPERATOR_HARBOR_*` 两组；建议统一到单一凭据源，按项目授权。
5. **build id 格式**：建议 `<version>+<UTC timestamp>.<pins-commit>`；是否同时保留
   语义化版本号，由产品发布流程决定。

---

## 11. 附录：本次审计的关键命令

```bash
# 锁 vs 树
diff <(yq '.components["cubestack-operator"]' cubestack-release/release-locks/2.1.0.yaml) \
     <(yq '.components["cubestack-operator"]' /data/offline-files/release.yaml)

# 空组件目录
for d in /data/offline-files/cubestack-operator/*/; do
  echo "$(basename "$d"): $(find "$d" -maxdepth 1 -type f | wc -l) files"
done

# 缺失镜像对应的 registry 查询
curl -s http://<registry-node>:31148/v2/<repo>/tags/list

# 节点缓存分布
ssh <node> "sudo ctr -n k8s.io images ls -q | grep -E 'lws|ai-gateway|prometheus|perses'"

# 交付树完整性
fetch-offline.sh --package-dir <tree> --dest <dest> --no-download --verify
```

> 说明：本文是整改设计与清单，不是逐行实现计划；T1–T10 落地时，每个任务需补充
> 对应的失败测试、实现和验收记录（建议使用仓库的 `docs/superpowers/plans/` 追踪）。

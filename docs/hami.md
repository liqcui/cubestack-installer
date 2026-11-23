# HAMi 部署指南(沐曦 MetaX GPU 共享 / 拓扑感知调度)

> 模块: `modules/03_addon/15_hami.sh` + `24_verify_hami.sh`(2026-11-23)
> chart: HAMi **2.11.0**(vendored:`deployments/cubestack-addon/hami/hami-2.11.0.tgz` + `.digest`)
> 依赖: `GPU_OPERATOR_ENABLED=true`(MetaX GPU Operator;**≥0.10.2**,当前 0.15.3)、MetaX Driver **≥2.32.0**、Kubernetes **≥1.23**
> 分支口径: `hami` 为临时验证分支,暂不合并 `main`;镜像登记(container-image-mirror / 离线包)后续单独做。

---

## 1. 它是什么

HAMi 在本仓库中只承担 **调度层**:

| 组件 | 作用 | 本仓口径 |
|---|---|---|
| `hami-scheduler`(kube-scheduler + extender) | 设备资源调度、sGPU 共享、拓扑打分 | ✅ |
| admission webhook | 给请求设备资源的 Pod 自动注入 `schedulerName: hami-scheduler` | ✅(跳过 `kube-system`) |
| HAMi device plugin | NVIDIA 设备插件 | ❌ **关闭** |
| MetaX 设备插件 | `metax-tech.com/gpu` / `sgpu` / `vcore` / `vmemory` | 由 `06_gpu_operator.sh`(MetaX GPU Operator)提供 |

要点: 沐曦卡的设备资源必须来自**厂商 device plugin**。HAMi 侧只读 `devices.metax.*` 资源名并做调度,
所以本模块强制 `devicePlugin.enabled=false`,不会与 MetaX Operator 抢设备。

> **vendor 插件有两种模式**(决定节点 advertise 什么资源):
> - `native`: 只 advertise `metax-tech.com/gpu`(整卡);
> - `sgpu`: advertise `metax-tech.com/sgpu`(vGPU 切片; `vcore`/`vmemory` 由 HAMi 调度器/注解管理)。
>
> **vGPU 共享必须让 vendor 插件运行在 `sgpu` 模式**(见 §2.0);整卡请求用 `native` 模式。
> 节点 allocatable 示例(sgpu 模式): `metax-tech.com/sgpu=128`(8 卡 × 16 切片),
> `metax-tech.com/gpu=0`。

## 2. 安装(单独安装)

```bash
# 只装 HAMi(不动 k8s/registry/metallb; gpu_operator 未完成时会先补齐)
sudo ./deploy-cluster.sh --steps hami

# 持久启用(下次全量部署自动包含 HAMi)
sudo ./deploy-cluster.sh --enable hami

# 验证
sudo ./deploy-cluster.sh --steps verify_hami
```

部署链: 推 3 个镜像到集群内置 registry 的 `mirrors/<上游全名>` → 用 vendored chart
`helm upgrade --install hami -n kube-system` → 等 `hami-scheduler` Ready + webhook + device-config
→ 登记组件(`cubestack-install-record`)。

### 2.0 前置: 让 MetaX vendor 插件进入 sGPU 模式

HAMi 的 vGPU 共享依赖 vendor device plugin advertise `metax-tech.com/sgpu`。
默认 `metax-device-config` 是 `mode: "native"`(只有 `metax-tech.com/gpu`), 需要改成 `sgpu`:

```bash
kubectl -n metax-operator apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: metax-device-config
  namespace: metax-operator
data:
  cluster-config: |
    mode: "sgpu"
    sgpuHybrid: null
    shareNums: 4
    deviceAllocationStrategy: "native"
  version: v1
EOF
kubectl -n metax-operator delete pod -l app=metax-gpu-device   # 让插件重载配置
kubectl get nodes -o json | jq -r '.items[] |
  select(.status.allocatable["metax-tech.com/sgpu"] != null) |
  "\(.metadata.name): sgpu=\(.status.allocatable["metax-tech.com/sgpu"])"'
# 预期: worker01: sgpu=128 / worker02: sgpu=128 (8 卡 × 16 切片)
```

> ⚠ 只改 ConfigMap 不够持久: 同时把同样的 `cluster-config` 写回 ClusterOperator CR 的
> `spec.devicePlugin.cmInit.config.cluster-config`(例如 `kubectl -n metax-operator edit
> clusteroperator cluster-operator`), 否则 ConfigMap 被删除/重建时可能回到 native。
>
> 切回整卡模式: 把 `mode` 改回 `"native"`(CM + CR) 并重启 `metax-gpu-device`。

### 2.1 镜像

| 上游镜像 | 推送到 |
|---|---|
| `docker.io/projecthami/hami:v2.11.0` | `<registry>/mirrors/docker.io/projecthami/hami:v2.11.0` |
| `registry.k8s.io/kube-scheduler:<集群 server 版本>` | `<registry>/mirrors/registry.k8s.io/kube-scheduler:<ver>` |
| `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9@sha256:…` | `<registry>/mirrors/registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9` |

- 源优先级: 离线 tar → 本地 docker → 在线拉取(`HAMI_IMAGE_MODE=auto`,默认)。
- 在线拉取默认走 **DaoCloud 镜像** `m.daocloud.io`(国内无法直连 `docker.io` / `registry.k8s.io`);
  能直连上游时设 `HAMI_IMAGE_SOURCE=upstream`。
- certgen 的 **digest 钉子保持 chart 默认值**;推入后模块会校验 registry 内 manifest digest 一致。
- kube-scheduler 优先复用版本树 `offline-files/kubespray/<ver>/images/` 里的 tar(不重复下载)。

### 2.2 离线备料(可选,已在本机就绪)

镜像 tar 搜索顺序:

1. `HAMI_OFFLINE_DIR`(默认 `offline-files/hami/`,release 正式登记后放这里,随 SHA256SUMS 封签);
2. `offline-files/base/hami/` —— **本地手工备料目录**: 校验器对 `os/`、`base/` 豁免
   `extra_file` 检查,`offline-sync` 也会保留,所以放这里不会破坏 seal 门禁;
3. `offline-files/kubespray/<ver>/images/`(kube-scheduler 复用,无需重复保存)。

文件名按 `<域>_<路径>_<tag>.tar`(与仓库其它组件一致),例如:

```text
base/hami/docker.io_projecthami_hami_v2.11.0.tar
base/hami/registry.k8s.io_ingress-nginx_kube-webhook-certgen_v1.6.9.tar
```

`HAMI_IMAGE_MODE=offline` 时只认这些 tar,不访问网络。

> certgen 说明: chart 默认用多架构 index digest 钉住 `kube-webhook-certgen`。
> 在线推送使用 `skopeo copy --all` 保留该 digest;离线 `docker-archive` 只能是单架构,
> 无法保留 index digest,模块会**自动把 chart 引用降级为 tag**(镜像内容仍来自同一 tar),
> 并在日志中明确告警。

## 3. 卸载(单独卸载)

```bash
sudo env CUBESTACK_MODULE_ACTION=uninstall \
  bash deployments/scripts/modules/03_addon/15_hami.sh
```

- 只动 HAMi 自身资源: helm release、`hami-webhook`、`hami-*` RBAC/Service/ConfigMap/Job。
- **不碰** MetaX GPU Operator、节点驱动、其他组件;不删 `kube-system`。
- 卸载后状态置 `uninstalled`,可直接再次 `--steps hami` 安装,无需 `--fresh`。
- 全量优雅覆盖时,`cluster-teardown.sh` 也会按安装登记反序自动调用该卸载段。

## 4. 配置项(`cluster.conf` / defaults §4.1b)

| 变量 | 默认 | 说明 |
|---|---|---|
| `HAMI_ENABLED` | `false` | 开关(TOGGLE);`--enable hami` 持久化 |
| `HAMI_VERSION` | `2.11.0` | chart 版本 |
| `HAMI_NAMESPACE` / `HAMI_RELEASE` | `kube-system` / `hami` | 部署位置/release 名 |
| `HAMI_IMAGE_MODE` | `auto` | `auto/online` 允许在线拉取;`offline` 只认离线 tar |
| `HAMI_IMAGE_SOURCE` | `daocloud` | 在线拉取源:`daocloud`=`m.daocloud.io`(国内默认);`upstream`=直连上游 |
| `HAMI_IMAGE_TAG` | `v${HAMI_VERSION}` | `projecthami/hami` tag |
| `HAMI_SCHEDULER_VERSION` | 空 | kube-scheduler tag;空=自动探测集群 server 版本 |
| `HAMI_METAX_SGPU_TOPOLOGY_AWARE` | `false` | 沐曦 sGPU 拓扑感知(仅 100% 算力请求;Pod annotation 可覆盖) |
| `HAMI_WEBHOOK_WHITELIST_NAMESPACES` | `kube-system` | webhook 跳过的命名空间 |
| `HAMI_CHART_SYNC` | `offline` | `online` 仅用于比对刷新 vendored chart |
| `HAMI_OFFLINE_DIR` | `offline-files/hami` | 离线 tar 目录(release 模式自动重定向到版本树) |

## 5. 沐曦作业示例

### 5.1 整卡(vendor `native` 模式)

> ⚠ 仅当 `metax-device-config` 为 `mode: native` 时可用。`mode: sgpu` 下 vendor 插件
> 只 advertise `metax-tech.com/sgpu`(本环境 128/节点),`metax-tech.com/gpu=0`,
> 本示例的 Pod 会因 `Insufficient metax-tech.com/gpu` 一直 Pending。
> sGPU 模式下要独占整卡,用 §5.2 的等价写法(100% 算力 + 整卡显存)。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: metax-whole
spec:
  containers:
    - name: ubuntu
      image: ubuntu:22.04
      command: ["sleep", "infinity"]
      resources:
        limits:
          metax-tech.com/gpu: 1
```

### 5.2 sGPU 共享(显存 + 算力比例)

> 需要 vendor 插件运行在 `mode: sgpu`(见 §2.0)。`vcore` 是算力百分比(100=整卡算力),
> `vmemory` 单位 GiB; 省略 `vcore`/`vmemory` 表示 100% / 整卡显存。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: metax-sgpu
spec:
  containers:
    - name: ubuntu
      image: ubuntu:22.04
      command: ["sleep", "infinity"]
      resources:
        limits:
          metax-tech.com/sgpu: 1      # 1 个共享 GPU(sGPU 切片)
          metax-tech.com/vcore: 60    # 60% 算力
          metax-tech.com/vmemory: 4   # 4 GiB 显存(裸整数单位 GiB)
```

说明:
- Pod 不需要手写 `schedulerName` —— admission webhook 检测到设备资源后自动注入 `hami-scheduler`;
- 多个 Pod 可以共享同一张物理 GPU: HAMi 记录每个 Pod 的 `compute`/`vRam`,
  vendor 插件创建独立 sGPU 切片(宿主 `mx-smi` 的 **Sliced GPU** 表可见);
- 资源名必须与 vendor plugin 一致(默认 `metax-tech.com/*`;改过插件资源名时同步改 chart `devices.metax.*`);
- 整卡请求(`metax-tech.com/gpu: 1`)仅在 §5.1 的 `native` 模式可用;`sgpu` 模式下该资源为 0。
- **sGPU 模式独占整卡**: `metax-tech.com/sgpu: 1` + `metax-tech.com/vcore: 100` +
  `metax-tech.com/vmemory: 64`(C550 64GB,单位 GiB);也可省略 `vcore`/`vmemory`
  (默认 100% / 整卡显存)。HAMi 不会再往这张卡上调度其他切片,效果等同整卡。

### 5.3 拓扑感知调度(vcore=100)

全局开关: 安装时 `HAMI_METAX_SGPU_TOPOLOGY_AWARE=true`(写入 chart device-config);
也可用 Pod 注解按需覆盖。**仅对 100% 算力的 sGPU 请求生效**;配合
`hami.io/node-scheduler-policy: spread|binpack` 控制分散/集中。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: metax-topo
  annotations:
    metax-tech.com/sgpu-topology-aware: "true"
    hami.io/node-scheduler-policy: "spread"   # spread=跨 GPU/NUMA 分散; binpack=尽量集中
spec:
  containers:
    - name: main
      image: <MACA 镜像, 如 registry.cubestack.io:5000/metax/maca:3.8.1.2-ubuntu22.04-amd64>
      command: ["sleep", "infinity"]
      resources:
        limits:
          metax-tech.com/sgpu: 1
          metax-tech.com/vcore: 100
          metax-tech.com/vmemory: 4
```

- `spread`: 多个 Pod 尽量分散到不同 GPU / NUMA 组; `binpack`: 集中到少数节点/GPU
  (受 vendor 的 `CardInsufficientCore` 等算力 accounting 限制);
- 拓扑信息(zone/hop scores/NUMA/linkZone)由 vendor plugin 写入 node 注解, 见 §8.3;
- 观察结果: `kubectl describe pod` 的 `FilteringSucceed` 事件会打印节点评分;
  HAMi extender 日志会打印分配到的 GPU UUID。

> **Volcano 集成**: 见 [docs/volcano.md](volcano.md)。Volcano 负责 Job/Queue 生命周期,
> Volcano Job 的 `spec.schedulerName`/task template 设为 `hami-scheduler`,由 HAMi 完成
> MetaX vGPU 分配;不需要 `volcano-hami` 或 `volcano-vgpu-device-plugin`。
>
> **完整示例文件**: [docs/hami-example-pods.yaml](hami-example-pods.yaml)
> (sGPU 共享 Pod + 拓扑感知 Pod, 可直接 `kubectl apply`)。
> **真实消费 demo**: [docs/hami-mem-demo.yaml](hami-mem-demo.yaml)(torch 分配 2GiB +
> 持续算力,配合 §8.5 的 `mx-smi` 观察)。

## 6. 验证口径(`--steps verify_hami`)

1. `hami-scheduler` Deployment Ready;
2. `hami-webhook` MutatingWebhookConfiguration 存在;
3. `hami-scheduler-device` ConfigMap 含 `metax-tech.com/{gpu,sgpu,vcore,vmemory}`;
4. 节点有 `metax-tech.com/gpu` **或** `metax-tech.com/sgpu` allocatable 时: 创建测试 Pod
   - native 模式: `metax-tech.com/gpu: 1`
   - sGPU 模式: `metax-tech.com/sgpu: 1` / `vcore=${HAMI_VERIFY_VCORE:-25}` / `vmemory=${HAMI_VERIFY_VMEMORY:-4}`
   断言 webhook 注入 `schedulerName=hami-scheduler`、Pod Ready;
5. 无沐曦卡: 组件级通过并明确告警跳过 GPU 端到端(不误报)。

> 探针默认只用 **25% 算力 / 4GiB**(避免集群已有 GPU 负载时因 `CardInsufficientCore` 误判失败);
> 可用 `HAMI_VERIFY_VCORE`、`HAMI_VERIFY_VMEMORY`、`HAMI_VERIFY_WAIT_SECONDS`(默认 180s)覆盖。
> sGPU 模式下若所有 GPU 算力已被占满, 先释放负载或降低 `HAMI_VERIFY_VCORE`。

## 7. 故障排查

| 现象 | 排查 |
|---|---|
| 测试 Pod 一直 Pending | `kubectl describe pod`;确认 MetaX device plugin 已 advertise `metax-tech.com/sgpu`;确认 `hami-scheduler` 是 Running |
| Pod 的 `schedulerName` 仍是 `default-scheduler` | webhook 是否生效:`kubectl get mutatingwebhookconfiguration hami-webhook`;命名空间是否在 `HAMI_WEBHOOK_WHITELIST_NAMESPACES` 里(被白名单跳过) |
| `hami-admission-create/patch` Job 失败 | certgen 镜像 digest 不匹配(模块会提前校验)或 registry 不可达 |
| 镜像拉取失败 | 节点 containerd 是否信任集群内置 registry(`05_k8s_registry.sh`);`HAMI_IMAGE_MODE=offline` 时 tar 是否在 `HAMI_OFFLINE_DIR` |
| `HAMI_IMAGE_MODE=auto` 时推镜像失败 | 安装机不可达拉取源: 默认 `m.daocloud.io`;可改用离线 tar(`HAMI_IMAGE_MODE=offline` 并备料)或设 `HAMI_IMAGE_SOURCE=upstream` |

## 8. 实机验证案例(2026-11-23, MetaX C550)

### 8.1 测试环境

| 项 | 值 |
|---|---|
| 节点 | 2× worker(worker01/worker02), 各 **8× MetaX C550 64GB** |
| OS / 内核 | Ubuntu 24.04.5 / 6.8.0-139-generic, 255 核 |
| 驱动 | 宿主驱动 3.9.1.33(`mx-smi` 可见 8 卡) |
| vendor 插件 | `mode: sgpu`,节点 allocatable `metax-tech.com/sgpu=128` |
| HAMi | chart 2.11.0,`HAMI_METAX_SGPU_TOPOLOGY_AWARE=true` |

### 8.2 如何查看 vGPU 资源使用情况

1. **节点 allocatable**:

   ```bash
   kubectl get nodes -o json | jq -r '.items[] |
     select(.status.allocatable["metax-tech.com/sgpu"] != null) |
     "\(.metadata.name): sgpu=\(.status.allocatable["metax-tech.com/sgpu"])"'
   ```

2. **宿主 `mx-smi` — Sliced GPU 表**(最直观的 vGPU 配额):

   ```bash
   ssh <node> mx-smi
   ```

   ```text
   | Sliced GPU                                                                    |
   |------------------------------------+---------------------+--------------------|
   | Minor    GPU    sGPU-Id    Compute | Vram Quota          | sGPU-Util          |
   |====================================+=====================+====================|
   | 006      0      0          25%     | 0/8192 MiB          | 0%                 |
   | 013      0      1          25%     | 0/8192 MiB          | 0%                 |
   | 002      1      0          25%     | 0/8192 MiB          | 0%                 |
   ...
   ```

   每行 = 一个 sGPU 切片: `Compute` 为算力配额, `Vram Quota` 为显存配额。

3. **Pod 注解**(HAMi/vendor 写入):

   ```bash
   kubectl -n hami-demo get pod hami-share-0 -o jsonpath='{.metadata.annotations}' | jq
   ```

   ```json
   "hami.io/metax-sgpu-devices-allocated": "GPU-cacd9404-...,Metax-SGPU,8192,25:;",
   "metax-tech.com/gpu-devices-allocated": "[[{\"uuid\":\"GPU-cacd9404-...\",\"compute\":25,\"vRam\":8192}]]",
   "metax-tech.com/gpu-allocated-status": "[{\"sgpus\":[{\"uuid\":\"GPU-eb3ddc7a-...\",\"bdf\":\"0000:e3:00.0\"}],\"status\":\"finished\"}]"
   ```

   - `metax-sgpu-devices-allocated`: `<物理 GPU UUID>,Metax-SGPU,<vRam MiB>,<compute%>`
   - `gpu-devices-allocated`: JSON `compute` / `vRam`
   - `gpu-allocated-status`: sGPU UUID + 物理 GPU BDF

4. **HAMi scheduler extender 日志**:

   ```bash
   kubectl -n kube-system logs deploy/hami-scheduler -c vgpu-scheduler-extender --tail=200 \
     | grep -E 'Metax-SGPU|NodeFitPod|NodeUnfitPod'
   ```

   ```text
   Encoded container Devices: GPU-cacd9404-...,Metax-SGPU,8192,25:
   "NodeFitPod" pod="hami-demo/hami-share-11" node="...worker01" score=9.609375
   "NodeUnfitPod" pod="hami-demo/hami-share-11" node="...worker02" reason="8/8 CardInsufficientCore"
   ```

5. **容器内 `mx-smi`**: 可见分配到的 vGPU(与宿主 Sliced GPU 表对应);
   显存/算力上限以宿主 Sliced GPU 表和 Pod 注解为准。

### 8.3 如何查看拓扑感知结果

1. **MetaX 拓扑注解**(vendor plugin 写到每个 node):

   ```bash
   kubectl get node cubestack-k8s-worker01 -o jsonpath='{.metadata.annotations}' | jq \
     'with_entries(select(.key|startswith("metax-tech.com/gpu.topology")))'
   kubectl get node cubestack-k8s-worker01 \
     -o jsonpath='{.metadata.annotations.metax-tech\.com/node-gpu-devices}' | jq
   ```

   - `metax-tech.com/gpu.topology.zones`: `gpu-group-0` / `DirectLink` / weight 60
   - `metax-tech.com/gpu.topology.scores|losses`: 按 hop 数的评分/代价
   - `metax-tech.com/node-gpu-devices`: 每 GPU 的 `numa`、`linkZone`、`totalCompute`、`totalVRam`

2. **`mx-smi topo -m`**(每个 GPU 节点):

   ```text
   GPU0/1 -> NUMA 0    GPU2/3 -> NUMA 2
   GPU4/5 -> NUMA 4    GPU6/7 -> NUMA 6
   所有 GPU 之间: MX1 (MetaXLink)
   ```

3. **调度事件评分**(topology-aware 的影响):

   ```bash
   kubectl -n hami-demo describe pod hami-topo-0 | grep -A2 FilteringSucceed
   ```

   ```text
   FilteringSucceed  find fit node(worker02),
     3 nodes not fit, 2 nodes fit(worker01:700000.00, worker02:600001.38)
   ```

4. **HAMi device config 确认开关**:

   ```bash
   kubectl -n kube-system get cm hami-scheduler-device -o yaml | grep -A7 'metax:'
   # sgpuTopologyAware: true
   ```

### 8.4 实测结果

**vGPU 共享**(16 Pod / 25% / 8GiB, binpack):

| 物理 GPU | Pod 数 | sGPU 切片 |
|---|---|---|
| GPU0-4(各) | 2 | 2× (25% / 8192MiB) |
| GPU5、GPU6 | 3 | 3× (25% / 8192MiB) |
| **合计** | **16 Pod / 7 GPU** | **16 切片** |

worker02 被 scheduler 拒绝: `CardInsufficientCore`(topo Pod 已占满算力);harness 正确 accounting。

**拓扑感知**(8 Pod × `vcore=100`, `spread` + `sgpu-topology-aware=true`):

| 结果 | 值 |
|---|---|
| 分布 | 8 Pod → **8 张不同 GPU**(worker02 7 张 + worker01 1 张) |
| NUMA 覆盖 | worker02 覆盖全部 **4 个 NUMA 组**(NUMA 0/2/4/6) |
| 调度评分 | `worker01:700000.00, worker02:600001.38`(普通 binpack ~9.61) |
| 验证 | 全部 Pod `schedulerName=hami-scheduler`,webhook 自动注入 |

### 8.5 清理

```bash
kubectl delete ns hami-demo
# 如需回退 vendor 插件:
#   把 metax-device-config 与 CR cmInit 的 mode 改回 "native", 再重启 metax-gpu-device
```

### 8.5 真实显存/算力消费 + worker 节点 `mx-smi` 观察

示例清单: [docs/hami-mem-demo.yaml](hami-mem-demo.yaml)
(申请 `sgpu=1 / vcore=25 / vmemory=8`,torch 实际分配 **2GiB** 并持续 matmul)。

```bash
kubectl create ns hami-demo 2>/dev/null || true
kubectl apply -f docs/hami-mem-demo.yaml
kubectl -n hami-demo wait --for=condition=Ready pod/hami-mem-demo --timeout=360s
kubectl -n hami-demo logs hami-mem-demo        # allocated_bytes 2147483648
kubectl -n hami-demo get pod hami-mem-demo -o jsonpath='{.metadata.annotations}' \
  | jq 'with_entries(select(.key|test("sgpu|devices-allocated")))'

# 在 GPU worker 节点上查看消耗(本 demo 落在 worker01)
ssh <gpu-node> mx-smi
ssh <gpu-node> mx-smi --show-process
ssh <gpu-node> mx-smi --show-usage
```

**实测输出(worker01, 2026-11-23)**:

Pod 注解:

```json
"hami.io/metax-sgpu-devices-allocated": "GPU-3d5d32e3-...,Metax-SGPU,8192,25:;"
"metax-tech.com/gpu-devices-allocated": "[[{\"uuid\":\"GPU-3d5d32e3-...\",\"compute\":25,\"vRam\":8192}]]"
```

`mx-smi` 主表(物理卡视角,GPU2 有切片在跑):

```text
| 2     MetaX C550 | 2           Off | 0000:63:00.0        | 54%          Enabled |
| 300W / 450W      | 48C          P9 | 3184/65536 MiB      | Available            |
```

`mx-smi` **Sliced GPU** 表(vGPU 切片视角):

```text
| Minor    GPU    sGPU-Id    Compute | Vram Quota          | sGPU-Util            |
| 018      2      2          25%     | 2324/8192 MiB       | 54%                  |
```

`mx-smi --show-process`(按进程):

```text
| Process:                                                                        |
|  GPU                    PID         Process Name                 GPU Memory     |
|                                                                  Usage(MiB)     |
|  2-s2                587067         python3                      2324           |
```

`mx-smi --show-usage`(按 GPU):

```text
GPU#2  MXC550  0000:63:00.0
    Utilization
        GPU                                       : 54 %
        VPUE                                      : 0 %
        VPUD                                      : 0 %
```

**如何解读**:

| 视图 | 命令 | 含义 |
|---|---|---|
| 主 GPU 表 | `mx-smi` | 物理卡整体利用率/显存(含该卡上全部 vGPU 切片) |
| Sliced GPU | `mx-smi` | 每个 vGPU 切片:`Compute` 配额、`Vram Quota 已用/配额`、`sGPU-Util` |
| 进程 | `mx-smi --show-process` | 每个 GPU 进程的 PID/名称/显存(`2-s2` = GPU2 的 sGPU-2) |
| 利用率 | `mx-smi --show-usage` | GPU / VPUE / VPUD 各类利用率 |
| 其他 | `mx-smi --show-memory`、`mx-smi -i <gpu>`、`mx-smi topo -m` | 显存/单卡/拓扑 |

说明:
- `kubectl top pod/node` 只显示 CPU/内存,**不显示 GPU**;GPU 消耗用 `mx-smi`、Pod 注解和 HAMi 日志。
- 节点 `metax-tech.com/sgpu` allocatable 是**切片容量**(本环境 128/节点),不会按 slice 递减;
  实际每片用量看 `mx-smi` Sliced GPU / `--show-process`,分配对象看 Pod 注解。
- 2GiB 分配在 Sliced GPU 表中显示为 `2324/8192 MiB`(含运行时开销),`sGPU-Util` 54%;
  主表物理显存 `3184/65536 MiB`(包含其他切片/进程)。
- 测试时为复用已缓存的 maca-pytorch 镜像固定了 worker01;通用示例可去掉 `nodeSelector`。

## 9. 常用命令速查

```bash
# ---------- 安装 / 卸载 ----------
sudo ./deploy-cluster.sh --steps hami
sudo env CUBESTACK_MODULE_ACTION=uninstall \
  bash deployments/scripts/modules/03_addon/15_hami.sh

# ---------- 状态 / 日志 ----------
kubectl -n kube-system get pods -l app.kubernetes.io/instance=hami -o wide
kubectl -n kube-system get deploy hami-scheduler
helm -n kube-system status hami
kubectl -n kube-system get cm hami-scheduler-device -o yaml
kubectl -n kube-system logs deploy/hami-scheduler -c vgpu-scheduler-extender --tail=200
kubectl -n kube-system logs deploy/hami-scheduler -c kube-scheduler --tail=200

# ---------- 消费 / 查看 vGPU ----------
kubectl create ns hami-demo 2>/dev/null || true
kubectl apply -f docs/hami-example-pods.yaml
kubectl apply -f docs/hami-mem-demo.yaml          # 真实 torch 2GiB 消费者
kubectl -n hami-demo get pods -o wide
kubectl -n hami-demo logs hami-mem-demo
kubectl -n hami-demo get pod <pod> -o jsonpath='{.spec.schedulerName}'   # hami-scheduler
kubectl -n hami-demo get pod <pod> -o jsonpath='{.metadata.annotations}' \
  | jq 'with_entries(select(.key|test("sgpu|devices-allocated")))'
kubectl get nodes -o json | jq -r '.items[] |
  select(.status.allocatable["metax-tech.com/sgpu"] != null) |
  "\(.metadata.name): sgpu=\(.status.allocatable["metax-tech.com/sgpu"])"'
ssh <gpu-node> mx-smi                 # 主表 + Sliced GPU(已用/配额)
ssh <gpu-node> mx-smi --show-process  # 进程级显存
ssh <gpu-node> mx-smi --show-usage    # GPU/VPUE/VPUD 利用率
ssh <gpu-node> mx-smi --show-memory
kubectl -n hami-demo describe pod <pod> | grep -A2 FilteringSucceed

# ---------- 拓扑感知 ----------
kubectl get node <gpu-node> -o jsonpath='{.metadata.annotations}' \
  | jq 'with_entries(select(.key|startswith("metax-tech.com/gpu.topology")))'
kubectl get node <gpu-node> \
  -o jsonpath='{.metadata.annotations.metax-tech\.com/node-gpu-devices}' | jq
ssh <gpu-node> mx-smi topo -m

# ---------- 验证 / 清理 ----------
sudo ./deploy-cluster.sh --steps verify_hami
kubectl delete ns hami-demo
bash deployments/scripts/tools/tests/test-hami-module.sh
```

> 实测结果见 §8.4：16 个 `25% / 8192MiB` 切片共享 7 张 GPU；
> 8 个 `vcore=100` 拓扑感知 Pod 分散到 8 张 GPU、覆盖 4 个 NUMA 组。

## 10. 边界(本分支)

- 只支持 **沐曦(MetaX)**;HAMi 自带 NVIDIA device plugin 固定关闭(NVIDIA 场景不在本次范围)。
- 镜像尚未登记到 `container-image-mirror` / 离线版本树(按用户口径:仅 installer 分支,验证后推送 fork)。
- chart 升级: 替换 vendored tgz + `.digest`(sha256sum),再 `HAMI_CHART_SYNC=online` 可做远端比对。

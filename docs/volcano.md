# Volcano 部署与 HAMi(MetaX vGPU)集成指南

> 模块: `modules/03_addon/16_volcano.sh` + `25_verify_volcano.sh`(2026-11-23)
> chart: Volcano **1.16.0**(vendored:`deployments/cubestack-addon/volcano/volcano-1.16.0.tgz` + `.digest`)
> 依赖: HAMi(`--steps hami`)、MetaX vendor 插件运行在 `sgpu` 模式、Kubernetes ≥1.23
> 分支: `volcano`(基于 `hami` 分支,临时验证用)

---

## 1. 集成方式(重要)

**Volcano 负责 Job/Queue 生命周期；GPU Pod 由 HAMi 调度。**

```text
Volcano Job (batch.volcano.sh/v1alpha1)
  spec.schedulerName: hami-scheduler
  tasks[].template.spec.schedulerName: hami-scheduler
  resources.limits.metax-tech.com/{sgpu,vcore,vmemory}
        ↓
Volcano controller 创建 Pod
        ↓
Pod 已带 schedulerName=hami-scheduler → 跳过 Volcano 调度器
        ↓
HAMi scheduler 分配 MetaX sGPU 切片（vcore/vmemory 由 HAMi/vendor 处理）
```

- **不需要** `volcano-hami` 这个组件（官方没有 MetaX 版本）。
- **不要**部署 `volcano-vgpu-device-plugin`：它面向 NVIDIA（NVML/NVIDIA runtime），不支持 MetaX。
- Volcano 自带 scheduler 仍保留（CPU/普通批处理 Job 可继续使用 `schedulerName: volcano`）。
- 限制：Volcano 的 **Gang / Queue / DRF 不会参与 GPU Pod 的调度**（Pod 已固定给 hami-scheduler）。
  若需要 Volcano 原生 gang + MetaX vGPU，需要等上游支持。

## 2. 安装(单独安装)

```bash
# 前置: HAMi 已部署、MetaX vendor 插件 mode=sgpu
sudo ./deploy-cluster.sh --steps hami
# 安装 Volcano
sudo ./deploy-cluster.sh --steps volcano

# 持久启用
sudo ./deploy-cluster.sh --enable volcano

# 验证(组件 + Volcano Job 端到端)
sudo ./deploy-cluster.sh --steps verify_volcano
```

部署链: 3 个镜像推入集群 registry 的 `mirrors/docker.io/volcanosh/**` → vendored chart
`helm upgrade --install volcano -n volcano-system` → 等 controller/scheduler/admission 就绪。

### 2.1 镜像

| 上游镜像 | 推送到 |
|---|---|
| `docker.io/volcanosh/vc-controller-manager:v1.16.0` | `<registry>/mirrors/docker.io/volcanosh/vc-controller-manager:v1.16.0` |
| `docker.io/volcanosh/vc-scheduler:v1.16.0` | `<registry>/mirrors/docker.io/volcanosh/vc-scheduler:v1.16.0` |
| `docker.io/volcanosh/vc-webhook-manager:v1.16.0` | `<registry>/mirrors/docker.io/volcanosh/vc-webhook-manager:v1.16.0` |

- 源优先级: 离线 tar → 本地 docker → 在线拉取(`VOLCANO_IMAGE_MODE=auto`)。
- 在线默认走 DaoCloud `m.daocloud.io`；可设 `VOLCANO_IMAGE_SOURCE=upstream`。
- 离线 tar 目录: `VOLCANO_OFFLINE_DIR`（默认 `offline-files/volcano/`）或
  `offline-files/base/volcano/`（seal 豁免、offline-sync 保留），命名
  `<域>_<路径>_<tag>.tar`，如 `docker.io_volcanosh_vc-scheduler_v1.16.0.tar`。

## 3. 卸载(单独卸载)

```bash
sudo env CUBESTACK_MODULE_ACTION=uninstall \
  bash deployments/scripts/modules/03_addon/16_volcano.sh
```

- 卸载 Volcano 自身: helm release、webhook、12 个 CRD、`volcano-system` 命名空间。
- **不影响** HAMi scheduler / MetaX GPU Operator / 节点驱动。
- 卸载后状态置 `uninstalled`，可直接再次 `--steps volcano` 重装。

## 4. 配置项(§4.1c)

| 变量 | 默认 | 说明 |
|---|---|---|
| `VOLCANO_ENABLED` | `false` | 开关；`--enable volcano` 持久化 |
| `VOLCANO_VERSION` | `1.16.0` | chart 版本 |
| `VOLCANO_NAMESPACE` / `VOLCANO_RELEASE` | `volcano-system` / `volcano` | 部署位置/release 名 |
| `VOLCANO_IMAGE_MODE` | `auto` | `auto/online` 允许在线拉取；`offline` 只认 tar |
| `VOLCANO_IMAGE_SOURCE` | `daocloud` | 在线源 `daocloud` / `upstream` |
| `VOLCANO_IMAGE_TAG` | `v${VOLCANO_VERSION}` | 组件镜像 tag |
| `VOLCANO_CHART_SYNC` | `offline` | `online` 仅用于比对刷新 vendored chart |
| `VOLCANO_OFFLINE_DIR` | `offline-files/volcano` | 离线 tar 目录 |

## 5. 示例 Volcano Job

完整文件: `docs/volcano-example-job.yaml`(2 个 task replica，每个 25% 算力 / 8GiB)。
真实消费 demo: `docs/volcano-mem-demo.yaml`(torch 分配 2GiB + 持续算力，见 §8.5)。

```yaml
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: volcano-sgpu-demo
  namespace: hami-demo
spec:
  minAvailable: 2
  schedulerName: hami-scheduler       # Job 级
  queue: default
  tasks:
    - name: sgpu
      replicas: 2
      template:
        metadata:
          annotations:
            metax-tech.com/sgpu-topology-aware: "true"
            hami.io/node-scheduler-policy: "spread"
        spec:
          schedulerName: hami-scheduler   # Pod 级
          restartPolicy: Never
          containers:
            - name: main
              image: registry.cubestack.io:5000/metax/maca:3.8.1.2-ubuntu22.04-amd64
              command: ["sh", "-c", "sleep 3600"]
              resources:
                limits:
                  metax-tech.com/sgpu: 1
                  metax-tech.com/vcore: 25
                  metax-tech.com/vmemory: 8
```

```bash
kubectl create ns hami-demo 2>/dev/null || true
kubectl apply -f docs/volcano-example-job.yaml
kubectl -n hami-demo get vcjob volcano-sgpu-demo
kubectl -n hami-demo get pods -l volcano.sh/job-name=volcano-sgpu-demo -o wide
```

## 6. 常用命令速查

```bash
# ---------- 安装 / 卸载 ----------
sudo ./deploy-cluster.sh --steps volcano
sudo env CUBESTACK_MODULE_ACTION=uninstall \
  bash deployments/scripts/modules/03_addon/16_volcano.sh

# ---------- 状态 / 日志 ----------
kubectl -n volcano-system get pods,deploy,jobs -o wide
helm -n volcano-system status volcano
kubectl get crd jobs.batch.volcano.sh
kubectl get queue
kubectl -n volcano-system logs deploy/volcano-controllers --tail=100
kubectl -n volcano-system logs deploy/volcano-scheduler --tail=100
kubectl -n volcano-system logs deploy/volcano-admission --tail=100

# ---------- 创建 / 查看 Volcano Job ----------
kubectl create ns hami-demo 2>/dev/null || true
kubectl apply -f docs/volcano-example-job.yaml
kubectl apply -f docs/volcano-mem-demo.yaml     # 真实 torch 2GiB 消费者
kubectl -n hami-demo get vcjob
kubectl -n hami-demo describe vcjob volcano-sgpu-demo
kubectl -n hami-demo get pods -l volcano.sh/job-name=volcano-sgpu-demo -o wide
kubectl -n hami-demo logs -l volcano.sh/job-name=volcano-mem-demo
kubectl -n hami-demo get pod <pod> -o jsonpath='{.spec.schedulerName}'   # hami-scheduler
kubectl -n hami-demo get pod <pod> -o jsonpath='{.metadata.annotations}' \
  | jq 'with_entries(select(.key|test("sgpu|devices-allocated")))'
ssh <gpu-node> mx-smi                 # 主表 + Sliced GPU(已用/配额)
ssh <gpu-node> mx-smi --show-process  # 进程级显存
ssh <gpu-node> mx-smi --show-usage    # GPU/VPUE/VPUD 利用率
ssh <gpu-node> mx-smi --show-memory

# ---------- 验证 / 清理 ----------
sudo ./deploy-cluster.sh --steps verify_volcano
kubectl -n hami-demo delete vcjob volcano-sgpu-demo
bash deployments/scripts/tools/tests/test-volcano-module.sh
```

## 7. 如何验证 vGPU 与 Volcano 集成

1. **Volcano 组件/Job**:

   ```bash
   kubectl -n volcano-system get deploy,pods
   kubectl get crd jobs.batch.volcano.sh
   kubectl -n hami-demo get vcjob volcano-sgpu-demo
   ```

2. **Pod 必须由 HAMi 调度**:

   ```bash
   kubectl -n hami-demo get pod <pod> -o jsonpath='{.spec.schedulerName}'   # hami-scheduler
   kubectl -n hami-demo get pod <pod> -o jsonpath='{.metadata.annotations}'
   # hami.io/metax-sgpu-devices-allocated / metax-tech.com/gpu-devices-allocated
   ```

3. **宿主 vGPU 切片**:

   ```bash
   ssh <gpu-node> mx-smi
   # Sliced GPU 表: Compute 25% / Vram Quota 8192 MiB
   ```

4. **自动验证**:

   ```bash
   sudo ./deploy-cluster.sh --steps verify_volcano
   ```

   验证模块创建 `volcano-verify-gpu` Job(schedulerName=hami-scheduler)、等待 Pod Ready、
   校验 HAMi 分配注解与 Job `status.state`，完成后自动删除。

## 8. 实测结果(2026-11-23, 容器 c)

**环境**: 5 节点 Ubuntu 24.04;worker01/02 各 8×MetaX C550;HAMi 2.11.0(sgpu 模式,
`metax-tech.com/sgpu=256`);Volcano chart 1.16.0。

### 8.1 安装

- 3 个镜像推入集群 registry(`mirrors/docker.io/volcanosh/**`)
- `helm upgrade --install volcano` STATUS=deployed
- `volcano-controllers` / `volcano-scheduler` / `volcano-admission` 均 **1/1 Ready**
- 12 个 Volcano CRD + admission webhook 已注册;模块 RC=0

### 8.2 `verify_volcano`

```text
✅ controller/scheduler/admission Ready
✅ Job CRD + admission webhook 已注册
✅ HAMi scheduler 在位
✅ MetaX 节点=2, GPU=0, sGPU=256
✅ Volcano Job Pod Ready
✅ Pod schedulerName=hami-scheduler + HAMi 分配注解
✅ Volcano Job state=Running
✅ verify_volcano 完成(组件级 + Volcano Job → HAMi sGPU 端到端)
RC=0
```

### 8.3 Sample Volcano Job(`volcano-sgpu-demo`)

```text
NAME                STATUS    MINAVAILABLE   RUNNINGS   AGE   QUEUE
volcano-sgpu-demo   Running   2              2          9s    default

NAME                       READY   STATUS    RESTARTS   AGE   NODE
volcano-sgpu-demo-sgpu-0   1/1     Running   0          9s    cubestack-k8s-worker01
volcano-sgpu-demo-sgpu-1   1/1     Running   0          9s    cubestack-k8s-worker01
```

| Pod | schedulerName | 分配 GPU UUID | compute | vRam |
|---|---|---|---|---|
| `volcano-sgpu-demo-sgpu-0` | `hami-scheduler` | `GPU-14e385b6-...` | 25 | 8192 MiB |
| `volcano-sgpu-demo-sgpu-1` | `hami-scheduler` | `GPU-3d5d32e3-...` | 25 | 8192 MiB |

宿主 `mx-smi` 的 **Sliced GPU** 表可见对应切片:`Compute 25%` / `Vram Quota 8192 MiB`。
sample Job 当前保留运行;清理:

```bash
kubectl -n hami-demo delete vcjob volcano-sgpu-demo
```

### 8.4 单独卸载 / 重装

- 单独卸载(`CUBESTACK_MODULE_ACTION=uninstall`):**RC=0**;
  `volcano-system` 命名空间、12 个 CRD、helm release 全部清理;HAMi scheduler 未受影响。
- 重新 `--steps volcano`:**RC=0**;3 个镜像已存在 → 跳过;sample Job 重建后再次 **Running**。

### 8.5 Volcano Job 真实消费 demo + worker `mx-smi`

示例清单: [docs/volcano-mem-demo.yaml](volcano-mem-demo.yaml)
(Volcano Job,1 task,`sgpu=1/vcore=25/vmemory=8`;torch 分配 2GiB 并持续 matmul)。

```bash
kubectl apply -f docs/volcano-mem-demo.yaml
kubectl -n hami-demo get vcjob volcano-mem-demo
kubectl -n hami-demo logs -l volcano.sh/job-name=volcano-mem-demo
kubectl -n hami-demo get pod -l volcano.sh/job-name=volcano-mem-demo \
  -o jsonpath='{.items[0].spec.schedulerName}'          # hami-scheduler
kubectl -n hami-demo get pod -l volcano.sh/job-name=volcano-mem-demo \
  -o jsonpath='{.items[0].metadata.annotations}' \
  | jq 'with_entries(select(.key|test("sgpu|devices-allocated")))'

# 在 GPU worker 节点查看实际消耗
ssh <gpu-node> mx-smi
ssh <gpu-node> mx-smi --show-process
ssh <gpu-node> mx-smi --show-usage
```

**实测输出(worker01, 2026-11-23)**:

```text
NAME               STATUS    MINAVAILABLE   RUNNINGS   QUEUE
volcano-mem-demo   Running   1              1          default

pod=volcano-mem-demo-mem-0  node=worker01  schedulerName=hami-scheduler
allocated_bytes 2147483648
hami.io/metax-sgpu-devices-allocated:
  GPU-096d8582-...,Metax-SGPU,8192,25
```

`mx-smi` Sliced GPU(同时有普通 Pod demo `2-s2` 与 Volcano Job demo `1-s2`):

```text
| Minor    GPU    sGPU-Id    Compute | Vram Quota          | sGPU-Util            |
| 019      1      2          25%     | 2324/8192 MiB       | 55%                  |
| 018      2      2          25%     | 2324/8192 MiB       | 54%                  |
```

`mx-smi --show-process`:

```text
|  1-s2                589137         python3                      2324           |  # Volcano Job
|  2-s2                587067         python3                      2324           |  # 普通 Pod
```

解读与 HAMi 文档一致:主表是物理卡;Sliced GPU 是每个 vGPU 切片的 **已用/配额** 与算力
利用率;`--show-process` 按 PID 显示进程显存;`kubectl top` 不显示 GPU。
详见 [docs/hami.md §8.5](hami.md#85-真实显存算力消费--worker-节点-mx-smi-观察)。

## 9. 故障排查

| 现象 | 排查 |
|---|---|
| Volcano Pod 一直 Pending | `kubectl -n <ns> describe pod`;检查 HAMi scheduler 是否 Running、sgpu allocatable、`CardInsufficientCore` |
| Pod 的 schedulerName 不是 hami-scheduler | Job `spec.schedulerName` 与 `tasks[].template.spec.schedulerName` 都要设置；Volcano 可能用其中一处 |
| Job 创建报 queue 不存在 | 确认 Volcano controller 已创建 `default` Queue(`kubectl get queue`) |
| 镜像拉取失败 | 节点 containerd 是否信任集群 registry；`VOLCANO_IMAGE_MODE=offline` 时 tar 是否在 `VOLCANO_OFFLINE_DIR` |
| 需要 Volcano gang 调度 | 当前不支持 MetaX vGPU + Volcano 原生 gang；GPU Pod 由 HAMi 单 Pod 调度 |

## 10. 边界

- 仅支持 **MetaX + HAMi** 的 Volcano Job 生命周期集成；NVIDIA 的 `volcano-vgpu-device-plugin`
  路径不适用于本环境。
- Volcano 的 Gang/Queue/DRF 不参与 GPU Pod 调度。
- 分支 `volcano` 为临时验证分支，未合并 main。

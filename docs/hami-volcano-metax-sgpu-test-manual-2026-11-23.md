# HAMi × Volcano（MetaX sGPU）部署实测手册（2026-11-23 回填版）

> 依据：`liqcui/cubestack-installer@volcano` → `docs/hami.md`、`docs/volcano.md`、`docs/*demo*.yaml`（文档日期 2026-11-23）
> 用途：把两份部署指南落成一份可执行的实测记录。**本版已用 2026-11-23 23:06–23:25 在容器 `cubestack-install-c` 的真实执行结果回填全部待补项**；原手册 §1.1 的 22:17 原始拓扑数据原样保留。
> 执行环境：容器 `cubestack-install-c`（镜像 `sha-baa5dc3`），仓库 `/opt/cubestack-installer`，release `2.1-SNAPSHOT-20261121-78a83fb`；集群 5 节点，worker01/02 各 8× MetaX C550。
> 原始日志：容器 `/root/hv-test-20261123/`，宿主 `/home/ubuntu/hv-test-20261123/`（93 个文件，约 520 KB）；其中 87 个日志已归档到仓库 `docs/test-results/2026-11-23-hami-volcano-metax-sgpu/`。2026-11-24 隔离机制实测证据归档在 `docs/test-results/2026-11-24-hami-metax-isolation/`。

约定：
- ✅ = 本次实测通过；❌ = 本次实测失败；⚠️ = 待办 / 风险 / 需 vendor 确认项。
- 【源】 = 命令取自两份文档或仓库脚本；【补】 = 原文档未列出的通用运维命令。
- 【基线】 = 源文档 §8 记录的 2026-11-23 历史值，仅供对照；【本次】 = 本次真实输出。
- 命令默认在容器 c 的 `/opt/cubestack-installer/deployments/scripts` 下执行；标注 `ssh <gpu-node>` 的在 GPU worker 节点执行。<pod> / <node> / <gpu-node> 为占位符。
- 本手册中所有 `mx-smi` 原始输出均来自 worker 节点本机；`kubectl` 均通过容器 c 内的 remote kubectl 执行。

---

## 0. 数据来源与核验说明

本手册依据 `docs/hami.md`、`docs/volcano.md` 与配套 YAML、验证脚本原文整理，并在本次执行中逐项核对。

| 文件 | 用途 | 核对结果 |
|---|---|---|
| `docs/hami.md` | HAMi 部署、§2.0 sGPU 模式切换、§5 作业示例、§6 验证口径、§8 实机案例、§9 命令速查 | ✅ 全文可用 |
| `docs/volcano.md` | Volcano 安装、§5 Job 示例、§6 命令速查、§7 集成验证、§8 实测 | ✅ 全文可用 |
| `docs/hami-example-pods.yaml` | `hami-metax-sgpu`（25% / 8GiB，binpack）、`hami-metax-topo`（100% / 4GiB，spread） | ✅ 本次直接 apply 通过 |
| `docs/hami-mem-demo.yaml` | `hami-mem-demo`，torch 分配 2GiB + 持续 matmul | ✅ 本次直接 apply 通过 |
| `docs/volcano-example-job.yaml` | `volcano-sgpu-demo`，2 replicas × 25% / 8GiB | ✅ 本次直接 apply 通过 |
| `docs/volcano-mem-demo.yaml` | `volcano-mem-demo`，1 task × 25% / 8GiB，torch 2GiB | ✅ 本次直接 apply 通过 |
| `24_verify_hami.sh` | 组件级 + GPU 端到端探针（实际默认 `vcore=25` / `vmemory=4`） | ✅ 本次实跑 RC=0 |
| `25_verify_volcano.sh` | Volcano 组件 + Volcano Job → HAMi sGPU 端到端 | ✅ 本次实跑 RC=0 |

源文档 3 个内部不一致项的本次结论：

1. `hami.md` §2.0 写 `shareNums: 4`，但节点 advertise `sgpu=128`（8 卡 × 16）。本次从 `node-gpu-devices` 注解确认：**每卡 `totalDevCount=16`，8×16=128**；`shareNums` 与“每卡切片数”不是同一口径，具体 vendor 语义仍需确认（见 §7）。
2. `24_verify_hami.sh` 头部注释写探针 `vcore=60`，脚本实际默认是 **25 / 4**；本次 verify 输出明确为 `sgpu=1 / vcore=25 / vmemory=4`。以脚本实际值为准。
3. `hami.md` 有两个 §8.5（清理 / 真实消费 demo），编号重复；本手册按内容区分，不影响执行。

---

## 1. 环境与前置

### 1.1 本次实测环境表（已回填）

| 项 | 文档 / 基线值 | 本次实测值（2026-11-23 23:06–23:25） |
|---|---|---|
| 集群节点数 / 角色 | 5 节点；worker01 / worker02 为 GPU 节点 | **5 节点：master01–03 + worker01/02；worker01/02 为 GPU 节点** |
| GPU 型号 / 单节点卡数 | 2 × 8 × MetaX C550 64GB 【基线】 | **2 节点 × 8 × MetaX C550 64GB（共 16 卡；单卡 65536 MiB）** |
| OS / 内核 | Ubuntu 24.04.5 / 6.8.0-139-generic 【基线】 | **Ubuntu 24.04.5 LTS / 6.8.0-139-generic；256 CPU / 8 NUMA 域** |
| 宿主驱动 | 3.9.1.33（≥2.32.0）【基线】 | **`metax-linux-dkms 3.10.33`；`mx-smi` Kernel Mode Driver 3.10.33；MACA 3.9.1.6；`mx-smi 2.3.4`** |
| Kubernetes | ≥1.23 | **v1.35.8（containerd 2.3.5，5 节点 Ready）** |
| MetaX GPU Operator | ≥0.10.2（当前 0.15.3） | **chart `metax-operator-0.15.3`，namespace `metax-operator`** |
| HAMi chart | 2.11.0（kube-system / release hami） | **2.11.0，`kube-system/hami`，revision 1，STATUS deployed** |
| Volcano chart | 1.16.0（volcano-system / release volcano） | **1.16.0，`volcano-system/volcano`，revision 1，STATUS deployed** |
| vendor 插件 mode | sgpu（必须；native 只 advertise 整卡） | **`mode: "sgpu"`（ConfigMap + ClusterOperator CR 双写一致）** |
| 节点 metax-tech.com/sgpu | 128 / 节点，合计 256 【基线】 | **worker01=128、worker02=128，合计 256；`metax-tech.com/gpu=0`** |
| 集群内置 registry | registry.cubestack.io:5000（示例镜像前缀） | **`registry.cubestack.io:5000` → 10.66.3.21（Service NodePort 31148）** |
| 镜像源 | HAMI_IMAGE_SOURCE=daocloud / VOLCANO_IMAGE_SOURCE=daocloud | **默认 daocloud；本次镜像已在 registry（重装时“新推 0 个 / 跳过 3 个”）** |

采集命令及真实输出：

```bash
kubectl get nodes -o wide
```

```text
NAME                     STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
cubestack-k8s-master01   Ready    control-plane   8h    v1.35.8   10.66.3.21    <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic   containerd://2.3.5
cubestack-k8s-master02   Ready    control-plane   8h    v1.35.8   10.66.3.22    <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic   containerd://2.3.5
cubestack-k8s-master03   Ready    control-plane   8h    v1.35.8   10.66.3.23    <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic   containerd://2.3.5
cubestack-k8s-worker01   Ready    <none>          8h    v1.35.8   10.66.3.39    <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic   containerd://2.3.5
cubestack-k8s-worker02   Ready    <none>          8h    v1.35.8   10.66.3.40    <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic   containerd://2.3.5
```

```bash
kubectl version
helm list -A
```

```text
Client Version: v1.35.8
Kustomize Version: v5.7.1
Server Version: v1.35.8

NAME               NAMESPACE        REVISION  UPDATED                              STATUS    CHART                            APP VERSION
cubestack-operator cubestack-system 1         2026-11-23 15:34:59 +0800 CST        deployed  cubestack-operator-chart-2.1.0...  latest
hami               kube-system      1         2026-11-23 23:23:34 +0800 CST        deployed  hami-2.11.0                      2.11.0
metax-gpu-operator metax-operator   1         2026-11-23 16:55:47 +0800 CST        deployed  metax-operator-0.15.3            0.15.3
volcano            volcano-system   1         2026-11-23 23:21:46 +0800 CST        deployed  volcano-1.16.0                   1.16.0
```

```bash
kubectl -n metax-operator get cm metax-device-config -o yaml
kubectl -n metax-operator get clusteroperator cluster-operator -o json | jq '.spec.devicePlugin.cmInit'
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) gpu=\(.status.allocatable["metax-tech.com/gpu"] // 0) sgpu=\(.status.allocatable["metax-tech.com/sgpu"] // 0)"'
```

```text
data:
  cluster-config: |
    mode: "sgpu"
    sgpuHybrid: null
    shareNums: 4
    deviceAllocationStrategy: "native"
  version: v1

（CR）"cluster-config": "mode: \"sgpu\"\nsgpuHybrid: null\nshareNums: 4\ndeviceAllocationStrategy: \"native\"\n"

cubestack-k8s-master01 gpu=0 sgpu=0
cubestack-k8s-master02 gpu=0 sgpu=0
cubestack-k8s-master03 gpu=0 sgpu=0
cubestack-k8s-worker01 gpu=0 sgpu=128
cubestack-k8s-worker02 gpu=0 sgpu=128
```

```bash
kubectl -n kube-system get cm hami-scheduler-device -o yaml | grep -A7 'metax:'
```

```yaml
    metax:
      resourceCountName: metax-tech.com/gpu
      resourceVCountName: metax-tech.com/sgpu
      resourceVMemoryName: metax-tech.com/vmemory
      resourceVCoreName: metax-tech.com/vcore
      sgpuTopologyAware: true
```

> 说明：`HAMI_METAX_SGPU_TOPOLOGY_AWARE` 在本次安装中为 true（device-config 可证），未写入 `cluster.conf` 的持久开关。

### 1.2 实机 GPU 拓扑基线（保留原始实测数据 · worker01 · 2026-11-23 22:17）

> **以下为原手册 §1.1 的原始实测数据，原样保留、未改动。** 该次采集时 worker01 上仍有 16 个 25% 的共享 Pod，因此 Sliced GPU 有 16 行、GPU0–6 为 Enabled；GPU7 当时无 25% 切片。它在本次执行前已被清理，后续 §1.3 用新数据修正其中对 `sGPU-M` 的解读。

采集方式：`mx-smi topo -m` + `mx-smi`（无业务负载，全部 0%）。

| 项 | 实测值（原始） |
|---|---|
| 节点 / 时间 | `cubestack-k8s-worker01` · Mon Nov 23 22:17:25–29 2026 |
| mx-smi / 驱动 / MACA / BIOS | 2.3.4 / Kernel Mode Driver 3.10.33 / 3.9.1.6 / 1.37.2.0 |
| GPU | 8 × MetaX C550，单卡 65536 MiB（64 GiB），全部 P0、0%、89–97 W / 450 W |
| 空闲基线占用 | 每卡 860 MiB（驱动 / 运行时保留）→ 可用 ≈ 64676 MiB |
| sGPU 模式 | GPU0–6 Enabled；GPU7 Disabled |
| 切片实例 | 16 个（每实例 25% 算力 + 8192 MiB 配额），分布 2/2/2/2/2/3/3/0 |

#### ① `mx-smi topo -m` 矩阵原文

```text
Device link type matrix
        GPU0    GPU1    GPU2    GPU3    GPU4    GPU5    GPU6    GPU7    Node Affinity  CPU Affinity
GPU0    X       MX1     MX1     MX1     MX1     MX1     MX1     MX1     0              0-15,128-143
GPU1    MX1     X       MX1     MX1     MX1     MX1     MX1     MX1     0              0-15,128-143
GPU2    MX1     MX1     X       MX1     MX1     MX1     MX1     MX1     2              32-47,160-175
GPU3    MX1     MX1     MX1     X       MX1     MX1     MX1     MX1     2              32-47,160-175
GPU4    MX1     MX1     MX1     MX1     X       MX1     MX1     MX1     4              64-79,192-207
GPU5    MX1     MX1     MX1     MX1     MX1     X       MX1     MX1     4              64-79,192-207
GPU6    MX1     MX1     MX1     MX1     MX1     MX1     X       MX1     6              96-111,224-239
GPU7    MX1     MX1     MX1     MX1     MX1     MX1     MX1     X       6              96-111,224-239

Legend:
  X    = Self
  MX#  = Connection traversing a bonded set of # MetaXLinks
```

读法：8×8 去掉对角线共 56 格，全部是 MX1（28 对 × 2），Legend 中 SYS / NODE / PHB / PXB / PIX / ETH 一次都没出现——说明这 8 张卡是一个全互联（full mesh）域，不存在「两组 4 卡、跨组走 PCIe」。

#### ② 三条对应关系（原始表）

| GPU | Bus-id（BDF） | Node Affinity | CPU Affinity | 切片数 | sGPU-Id → minor |
|---|---|---|---|---|---|
| GPU0 | 0000:23:00.0 | 0 | 0-15,128-143 | 2 | 0→006、1→013 |
| GPU1 | 0000:26:00.0 | 0 | 0-15,128-143 | 2 | 0→002、1→010 |
| GPU2 | 0000:63:00.0 | 2 | 32-47,160-175 | 2 | 0→005、1→014 |
| GPU3 | 0000:66:00.0 | 2 | 32-47,160-175 | 2 | 0→001、1→009 |
| GPU4 | 0000:a3:00.0 | 4 | 64-79,192-207 | 2 | 0→004、1→012 |
| GPU5 | 0000:a4:00.0 | 4 | 64-79,192-207 | 3 | 0→000、1→008、2→015 |
| GPU6 | 0000:e3:00.0 | 6 | 96-111,224-239 | 3 | 0→003、1→007、2→011 |
| GPU7 | 0000:e4:00.0 | 6 | 96-111,224-239 | 0 | sGPU-M: Disabled |

> 原始图 2 的说明：16 个 sGPU 实例的落位，每卡默认 2 个、GPU5/6 各 3 个、GPU7 一个没有（原文解读为“该卡 sGPU 被关闭”）。**此解读已由 §1.3 修正：Disabled 不等于该卡不能切片。**

#### ③ 三列含义（原始）

| 列 | 含义 | 在 HAMi 里的用途 |
|---|---|---|
| Node Affinity | GPU 所挂的 NUMA 域。本机只出现 0/2/4/6 四个值，每值 2 卡 | 对应节点注解 `node-gpu-devices` 的 `numa` 字段，spread 策略据此把 Pod 摊到不同 NUMA 域 |
| CPU Affinity | 该域可用的逻辑 CPU。0-15 与 128-143 是同一批 16 个物理核的两条超线程 | 4 域 × 16 核 = 64 物理核 / 128 线程；Pod 与 GPU 同域可少一次跨 NUMA 访存 |
| Bus-id（BDF） | PCIe 总线:设备.功能。总线号分四段 0x2x / 0x6x / 0xA0x / 0xE0x，与四个 NUMA 域一一对应 | 容器内 GPU 工具、`metax-tech.com/gpu-allocated-status` 注解里的物理卡位置都靠它定位 |

原始结论：① Node Affinity 不连续（0/2/4/6）说明平台 NUMA 数多于 4，GPU 只落在其中 4 个域；② 同域两卡的 PCIe 总线号同段（0x23/0x26、0x63/0x66、0xA3/0xA4、0xE3/0xE4），四段互不重叠 → 四条独立 PCIe 通路，而不是 1 个 Switch 分 4 卡。GPU 之间一律走 MX1，同 NUMA 域也不走 PCIe；NUMA 只影响 host↔device 的访存路径。

#### ④ 与文档 / 官方拓扑图的 3 处差异（原始，含本次修正标注）

| # | 文档 / 官方图说法 | 原始实测（22:17） | 本次复核结论（23:06–23:25） |
|---|---|---|---|
| 1 | 官方拓扑图：2 个 PCIe Switch × 各 4 卡，组内 MetaXLink、组间走 PCIe | 8 卡全 MX1 全互联，无 Switch 分叉 | ✅ 仍然成立；`mx-smi topo -m`（worker01/02）均为 28 对 MX1 |
| 2 | 基线「128 / 节点（8 卡 × 16 切片）」，`shareNums: 4` | mx-smi 只列出 16 个切片实例（2–3 / 卡） | **已解释**：`node-gpu-devices` 注解 `totalDevCount=16`/卡 → 8×16=128；mx-smi 的 Sliced GPU 表只列“当前已实例化”的切片，不是容量口径 |
| 3 | 未提及单卡关闭 sGPU | GPU7 `sGPU-M: Disabled`，0 切片 | **⚠️ 原始解读需修正**：`Enabled/Disabled` 是该卡当前 sGPU 运行模式，不是“该卡被关闭”；本次实测中 25% Pod 成功落到曾显示 Disabled 的 GPU7（worker02 与 worker01 均有实证） |

#### ⑤ 复核命令（原始）

```bash
ssh <gpu-node> lscpu | grep -i numa
ssh <gpu-node> numactl -H
kubectl get node cubestack-k8s-worker01 \
  -o jsonpath='{.metadata.annotations.metax-tech\.com/node-gpu-devices}' | jq
kubectl get nodes -o json | jq -r '.items[] |
  select(.status.allocatable["metax-tech.com/sgpu"] != null) |
  "\(.metadata.name): sgpu=\(.status.allocatable["metax-tech.com/sgpu"])"'
ssh <gpu-node> mx-smi --show-process
```

本次回填的 ⑤ 结果：

```text
worker01 node-gpu-devices（节选，8 卡；每卡 totalDevCount=16 / totalCompute=100 / totalVRam=65536 / linkZone=1）:
  GPU-e3980126... bdf=0000:e4:00.0 numa=6 model=native
  GPU-cacd9404... bdf=0000:e3:00.0 numa=6 model=sgpu
  ...（GPU0/1→numa 0，GPU2/3→numa 2，GPU4/5→numa 4）
worker02 node-gpu-devices（节选）:
  GPU-43110603... bdf=0000:e4:00.0 numa=6 model=sgpu
  GPU-f411dc02... bdf=0000:e3:00.0 numa=6 model=native
  ...（其余卡 model=native）

allocatable: cubestack-k8s-worker01 sgpu=128 / cubestack-k8s-worker02 sgpu=128（gpu=0）
```

> 完整 JSON 见 `/home/ubuntu/hv-test-20261123/V5-node-gpu-devices-*.txt`。

### 1.3 本次复核：`sGPU-M` 的语义与容量口径（重要修正）

本次执行前，worker01 上仍保留上一轮验证的 16 个 25% 共享 Pod（hami-share-0..15），worker02 上保留 7 个 100% 拓扑 Pod + 1 个 100% Pod。因此：

- **worker01**：`mx-smi` Sliced GPU 16 行（GPU0–6，各 25%/8192MiB），GPU7 无切片 → Disabled；这正是 §1.2 原始数据的来源。
- **worker02**：8 个 Pod 均为 100% vcore，走 **native 整卡分配**（vendor 日志 `config native gpu ...`），不产生 Sliced 行；因此 T0 采集时 worker02 为 0 行切片、多数卡 Disabled。V3 的 25% Pod 落到 GPU7 后才出现 1 行切片。

清理旧 Pod 后，本次重新创建负载并观察 `sGPU-M` 的变化：

| 场景 | 卡状态 | 证据 |
|---|---|---|
| V3：`hami-metax-sgpu`（25%）落到 worker02 GPU7（BDF `0000:e4:00.0`，物理 UUID `GPU-43110603...`） | **该卡从 Disabled → Enabled**；Sliced 行 `000 7 0 25% 0/8192 MiB` | `V4-mx-smi-worker02.txt`；Pod 注解 `metax-tech.com/gpu-allocated-status` 指向 `0000:e4:00.0` |
| V5：8 个 `vcore=100` Pod 分散到 8 张不同 GPU | 这些卡分配为 **native**（`model:native`），`mx-smi` 不显示切片；worker02 GPU6 / worker01 GPU6 显示 Disabled | `V5-8pods-alloc.txt`、`V5-extender-8pods.txt`、`V5-mx-smi-*.txt` |
| V6：`volcano-sgpu-demo`（25%）一个 Pod 落到 worker01 GPU7（BDF `0000:e4:00.0`） | **曾显示 Disabled 的 GPU7 成功创建 25% 切片**（sGPU UUID `GPU-5398938f...`） | `V6-pod-allocation.txt` |
| V7：两个 torch 2GiB demo 分别落到 worker02 GPU4/GPU5 | 两卡 Enabled；Sliced 行 `002 4 0 25% 2324/8192 56%`、`001 5 0 25% 2324/8192 57%` | `V7-mx-smi-worker02.txt` |
| V8：全部工作负载清理后 | Sliced 行归 0；曾创建过切片的卡可能保持 Enabled（worker01 GPU0–7、worker02 GPU4/5/7），从未切片的卡为 Disabled；切回 native 后全部 Disabled，恢复 sgpu 后按需再次激活 | `V8-mx-smi-*-after-all-cleanup.txt`、`V8-mx-smi-native-worker01.txt` |

**结论（修正 §1.2 原始解读）**：

1. `sGPU-M` 是**单卡当前运行模式**（是否已启用 sGPU 切片能力），不是“该卡被永久关闭”，也不能据此推断“申请 sgpu 的 Pod 永远不会落到 GPU7”。本次 V6 已在 worker01 GPU7 上成功创建 25% 切片。
2. `vcore=100` 的请求走 **native 整卡分配**（vendor 日志 `config native gpu ...`、`model:native`），不会产生 Sliced 行；`vcore<100` 才创建 sGPU 切片。这解释了为什么“8 卡拓扑 Pod 铺满”时 mx-smi 仍可能没有 Sliced 行。
3. 可调度容量看节点 `allocatable` 与 vendor `node-gpu-devices` 注解，不看 mx-smi 的“当前实例数”：`totalDevCount=16`/卡 × 8 = **128/节点**；mx-smi Sliced 表只是当前已创建的切片列表（0–16 行均属正常）。
4. `shareNums: 4` 与 `totalDevCount=16` 的换算关系仍未由 vendor 文档确认，记为 ⚠️ 待办；但“128 = 8×16”已有节点注解直接证据。

### 1.4 隔离由谁实现：vendor 设备节点 + 驱动配额（2026-11-24 00:18 实测）

**动机**：NVIDIA 路径上，HAMi 通过挂载 `libvgpu.so` + `/etc/ld.so.preload` 接管 CUDA/NVML 调用，因此常说 `vcore` 是“比例、软隔离”。MetaX 路径是否同样成立，此前只有 vcore/vmemory 注解作为间接证据。本次用两个 25% / 8GiB 的 Pod 直接验证。

**探针**：

- `iso-probe`：`sgpu=1 / vcore=25 / vmemory=8`，镜像 `metax/maca:3.8.1.2-ubuntu22.04-amd64`，`sleep 3600`。
- `iso-mem-over`：同配额，镜像 `suanova/maca-pytorch:...-78a83fb`，在容器内用 torch 尝试分配 **10 GiB**（超过 8 GiB 配额）。

**观测结果**：

| 检查项 | 命令 | 实测结果 |
|---|---|---|
| preload hook | `cat /etc/ld.so.preload` | **文件不存在**（rc=1） |
| libvgpu | `find / -maxdepth 5 -iname '*vgpu*'` | **0 个** |
| 环境变量 | `cat /proc/1/environ` | 无 `LD_PRELOAD`、无 `MX_VISIBLE_DEVICES`、无 `CUDA_VISIBLE_DEVICES` |
| Pod spec | `kubectl get pod -o json` | `env=null`；`volumeMounts` 仅 serviceaccount；HAMi 未注入任何 hook/volume |
| CRI devices | `crictl inspect <cid>` | 仅 `/dev/mxcd`、`/dev/dri/card8`、`/dev/dri/renderD135`、`/dev/sgpu000` |
| 容器内 mx-smi | `kubectl exec ... mx-smi` | `Attached GPUs: 1`；Sliced 行 `000 0 0 25% 0/8192 MiB` |
| 容器内显存容量 | torch | `GPU 0 has a total capacity of 7.59 GiB`（不是物理 64 GiB） |
| 超配额分配 | torch 10 GiB | **`torch.OutOfMemoryError`**（Tried to allocate 10.00 GiB / total capacity 7.59 GiB） |
| vendor 日志 | device plugin | `created sgpu [sched_quota=25;vram_quota=8192;alias=k8s:iso-probe:main;...] on 0000:e4:00.0#0` |
| 宿主 sysfs | worker02 | `/sys/bus/pci/devices/0000:e4:00.0/sgpu/sgpu0`；同目录有 `sched_timeslice`、`sched_class` |

**结论（重要修正）**：

1. **MetaX 路径没有 HAMi 的 LD_PRELOAD/libvgpu hook**。隔离由 **vendor device plugin + 驱动**实现：每个 Pod 只拿到自己的 sGPU 设备节点（`/dev/sgpu000` + 对应 DRM 节点），驱动向容器暴露一个 8 GiB 的虚拟 GPU。
2. **`vmemory` 是设备级硬配额，不只是记账**：容器内 GPU 容量被限制为 7.59 GiB，10 GiB 分配直接 OOM。
3. **`vcore` 以 `sched_quota=25` + `sched_timeslice` 实现**；算力隔离强度（并发延迟、利用率上限）尚未量化，列入 D 组多租户专项。
4. **HAMi 在 MetaX 上只做调度与注解**（kube-scheduler + extender + admission webhook），不做运行时拦截；NVIDIA 路径的“软隔离”因果链不能直接套用到沐曦。
5. 对多租户的含义：**显存隔离可认为强**（硬配额）；算力隔离是 vendor 的调度配额/时间片，需 D 组实测后才能给结论。

> 原始证据：`/home/ubuntu/hv-test-20261123/iso/`（容器 c 同名目录），关键文件 `ld-preload.txt`、`dev-list.txt`、`environ.txt`、`mx-smi-in-container.txt`、`cri-inspect.json`、`mem-over-run2.txt`、`device-plugin-iso-log.txt`、`sysfs-sgpu-worker02.txt`。

---

## 2. 部署与组件级实测（T0–T6）

> 顺序：驱动 / GPU Operator → vendor 切 sgpu → HAMi → Volcano。本次执行时四者已就绪；T1 的重载路径在 V8 回退/恢复中再次验证。

### T0 前置：MetaX GPU Operator 与驱动已就绪 【源 hami §1 / §2】

```bash
kubectl -n metax-operator get pods -o wide
ssh <gpu-node> mx-smi
```

实测输出（2026-11-23 23:07）：

```text
NAME                                                 READY   STATUS    RESTARTS   AGE     NODE
metax-container-runtime-trz7m                        1/1     Running   0          6h11m   cubestack-k8s-worker01
metax-container-runtime-vdhgb                        1/1     Running   0          6h11m   cubestack-k8s-worker02
metax-gpu-device-j68fb                               1/1     Running   0          5h42m   cubestack-k8s-worker01
metax-gpu-device-xhjlh                               1/1     Running   0          5h42m   cubestack-k8s-worker02
metax-gpu-label-4bl2j / 95rct / bxc2r / tgjgj / tzt2r  1/1   Running   0          6h11m   5 节点
metax-gpu-operator-metax-operator-7d6dffb99b-q6x8l   1/1     Running   0          6h11m   cubestack-k8s-master02
metax-maca-698gs / 7qt74                             1/1     Running   0          6h11m   worker02 / worker01
```

`ssh worker01 mx-smi`（节选）：

```text
Attached GPUs : 8
MX-SMI 2.3.4 / Kernel Mode Driver 3.10.33 / MACA 3.9.1.6 / BIOS 1.37.2.0
GPU0..GPU7: MetaX C550, 65536 MiB, P0, 0%, 860/65536 MiB
（其中 GPU7 sGPU-M: Disabled；其余 GPU0–6 Enabled，因当时仍有 16 个旧共享 Pod）
```

**结论：✅ 通过**。MetaX GPU Operator 全部 Pod Running；宿主 `mx-smi` 可见全部 8 张物理卡。

### T1 让 vendor 插件进入 sgpu 模式 【源 hami §2.0】

执行前实测状态（2026-11-23 23:07）：

```yaml
# kubectl -n metax-operator get cm metax-device-config -o yaml
data:
  cluster-config: |
    mode: "sgpu"
    sgpuHybrid: null
    shareNums: 4
    deviceAllocationStrategy: "native"
  version: v1
```

```json
// ClusterOperator CR spec.devicePlugin.cmInit.config.cluster-config
"mode: \"sgpu\"\nsgpuHybrid: null\nshareNums: 4\ndeviceAllocationStrategy: \"native\"\n"
```

```text
cubestack-k8s-worker01: sgpu=128
cubestack-k8s-worker02: sgpu=128
metax-gpu-device-j68fb / xhjlh: 1/1 Running
```

本次按原手册执行了 apply + 删除 device plugin Pod 的重载验证（2026-11-23 23:27）：

```text
configmap/metax-device-config configured
pod "metax-gpu-device-kgqmd" deleted from metax-operator namespace
pod "metax-gpu-device-q6q58" deleted from metax-operator namespace
Waiting for daemon set "metax-gpu-device" rollout to finish: 0 of 2 updated pods are available...
Waiting for daemon set "metax-gpu-device" rollout to finish: 1 of 2 updated pods are available...
daemon set "metax-gpu-device" successfully rolled out

# 重新注册期间约 1–15s 内可能先看到单节点 sgpu=0；等待后：
cubestack-k8s-worker01 gpu=0 sgpu=128
cubestack-k8s-worker02 gpu=0 sgpu=128
metax-gpu-device-j59pg   1/1 Running  worker01
metax-gpu-device-mhmgg   1/1 Running  worker02
```

> 操作提示：删除 `metax-gpu-device` Pod 后，kubelet 设备重新注册有短暂窗口（本次观察到 worker01 先为 `sgpu=0`，约 15s 内恢复 128）。批量脚本应轮询两个节点都达到 `sgpu=128` 再继续，不要只判断第一个匹配。

**结论：✅ 通过**。apply 返回 `configured`；DaemonSet 滚动完成；节点恢复 `metax-tech.com/sgpu=128`、`metax-tech.com/gpu=0`；与基线一致（worker01/worker02 各 128）。

### T2 安装 HAMi 【源 hami §2】

```bash
helm -n kube-system status hami
kubectl -n kube-system get pods -l app.kubernetes.io/instance=hami -o wide
kubectl -n kube-system get deploy hami-scheduler
kubectl get mutatingwebhookconfiguration hami-webhook
```

实测输出：

```text
NAME: hami
LAST DEPLOYED: Mon Nov 23 17:27:00 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1

NAME                              READY   STATUS    RESTARTS   AGE     IP              NODE
hami-scheduler-68dd79f77c-56tr8   2/2     Running   0          5h42m   10.233.119.55   cubestack-k8s-worker02

NAME             READY   UP-TO-DATE   AVAILABLE   AGE
hami-scheduler   1/1     1            1           5h42m

NAME           WEBHOOKS   AGE
hami-webhook   1          5h42m
```

> 上表为初次安装（17:27）。T6 卸载/重装后 `LAST DEPLOYED` 变为 23:23:34，STATUS 仍为 deployed，scheduler 2/2（见 T6）。

> `hami-admission-create/patch` 为 Helm hook Job，证书生成完成后按 chart 生命周期清理；本次查询时已不存在，但 `hami-webhook` 已注册，属正常。T6 重装后同样为 deployed / 2/2。

**结论：✅ 通过**。release STATUS=deployed，`hami-scheduler` Ready（2/2 容器），webhook 已注册。

### T3 verify_hami 组件级 + GPU 端到端 【源 hami §6 + 24_verify_hami.sh】

```bash
sudo ./deploy-cluster.sh --steps verify_hami
```

实测输出（2026-11-23 23:09，RC=0）：

```text
→  Verify HAMi(MetaX 模式): scheduler → webhook → device-config → sGPU Pod ...
✅     scheduler Ready=1 ✓
✅     hami-webhook 已注册 ✓
✅     metax-tech.com/{gpu,sgpu,vcore,vmemory} 均已配置 ✓
✅   检测到 2 个 MetaX 节点(GPU=0, sGPU=256; 节点数 gpu=0/sgpu=2) ✓
→    ④ 创建 sGPU 测试 Pod(sgpu=1 / vcore=25 / vmemory=4)...
✅     sGPU Pod Ready ✓
✅     admission webhook 已注入 schedulerName=hami-scheduler ✓
⚠      容器内未发现 /dev/mxcd(驱动/device plugin 版本差异; 调度与共享已通过)
✅ verify_hami 完成(组件级 + MetaX sGPU 端到端)
✅ 模块 [verify_hami] 完成
VERIFY_HAMI_RC=0
```

> `scheduler Ready=1` 指 Deployment 的 `readyReplicas=1`；该 Pod 内 2 个容器（kube-scheduler + vgpu-scheduler-extender）均 Running，因此 Pod 显示 2/2。

断言核对（与 `24_verify_hami.sh` 逐条对应）：

| # | 断言 | 本次结果 |
|---|---|---|
| 1 | `hami-scheduler` Deployment Ready | ✅ Ready=1 |
| 2 | `hami-webhook` MutatingWebhookConfiguration 存在 | ✅ 已注册 |
| 3 | `hami-scheduler-device` 含 `metax-tech.com/{gpu,sgpu,vcore,vmemory}` | ✅ 四个资源名齐全 |
| 4 | 有 MetaX 节点时创建探针 Pod（`sgpu=1 / vcore=25 / vmemory=4`） | ✅ Ready |
| 5 | 探针 Pod 的 `schedulerName` 被注入为 `hami-scheduler` | ✅ 已注入 |
| 6 | 无 GPU 节点时组件级通过并 warn 跳过 | 不适用（本集群有 2 个 MetaX 节点） |

> `/dev/mxcd` 告警为脚本的 known-warn（容器内未挂载该设备节点），不影响调度/共享断言；本次 torch demo（V7）已证明容器内 MACA 可用。

**结论：✅ 通过，RC=0**。探针 `vcore=25`（不是注释里的 60），与脚本实际默认一致。

### T4 安装 Volcano 【源 volcano §2】

```bash
helm -n volcano-system status volcano
kubectl -n volcano-system get pods,deploy,jobs -o wide
kubectl get crd jobs.batch.volcano.sh
kubectl get crd | grep -c volcano
kubectl get queue
```

实测输出（2026-11-23 23:09）：

```text
NAME: volcano
LAST DEPLOYED: Mon Nov 23 19:45:21 2026
NAMESPACE: volcano-system
STATUS: deployed
REVISION: 1

pod/volcano-admission-7c94b778d6-c2dxc     1/1 Running   3h24m  cubestack-k8s-worker01
pod/volcano-controllers-5fddc8f494-45jlf   1/1 Running   3h24m  cubestack-k8s-worker01
pod/volcano-scheduler-66666b57-28h5z       1/1 Running   3h24m  cubestack-k8s-worker02
deployment.apps/volcano-admission     1/1 1 1
deployment.apps/volcano-controllers   1/1 1 1
deployment.apps/volcano-scheduler     1/1 1 1

NAME                    CREATED AT
jobs.batch.volcano.sh   2026-11-23T11:45:28Z
crd_count=12

NAME      PARENT
default   root
root
```

> 上表为初次安装（19:45）。T6 卸载/重装后 `LAST DEPLOYED` 变为 23:21:46，3 个 Deployment 仍为 1/1（见 T6）。

**结论：✅ 通过**。release deployed；controller/scheduler/admission 均 1/1；12 个 CRD + admission webhook；`default` Queue 存在。与基线一致。

### T5 verify_volcano 端到端 【源 volcano §7.4】

```bash
sudo ./deploy-cluster.sh --steps verify_volcano
```

实测输出（2026-11-23 23:09，RC=0）：

```text
→  Verify Volcano: components → Volcano Job → HAMi vGPU ...
✅   controller/scheduler/admission Ready ✓
✅   Job CRD + admission webhook 已注册 ✓
✅   HAMi scheduler 在位(kube-system/hami-scheduler) ✓
✅   MetaX 节点=2, GPU=0, sGPU=256 ✓
→    ③ 创建 Volcano Job(sGPU: sgpu=1 / vcore=25 / vmemory=4)...
✅     Volcano Job Pod Ready ✓
✅     Pod schedulerName=hami-scheduler + HAMi 分配注解 ✓
✅     Volcano Job state=Running ✓
✅ verify_volcano 完成(组件级 + Volcano Job → HAMi sGPU 端到端)
✅ 模块 [verify_volcano] 完成
VERIFY_VOLCANO_RC=0
```

**结论：✅ 通过，RC=0**。与基线 8 项 ✅ + “MetaX 节点=2, GPU=0, sGPU=256”一致。

### T6 单独卸载 / 重装（可选）【源 hami §3 / volcano §3 / §8.4】

本次完整执行了 Volcano → HAMi 的卸载/重装，并在恢复后重新拉起 sample Job。

#### T6.1 Volcano 卸载

```bash
CUBESTACK_MODULE_ACTION=uninstall bash deployments/scripts/modules/03_addon/16_volcano.sh
```

```text
→    volcano: helm uninstall volcano(ns=volcano-system)...
→    清理残留(webhook/CRD/命名空间)...
✅   Volcano 已卸载(volcano @ volcano-system)
VOLCANO_UNINSTALL_RC=0

helm -n volcano-system list        → 空
kubectl get ns volcano-system      → NotFound
volcano_crd_count=0
kubectl -n kube-system get deploy hami-scheduler → 1/1（未受影响）
```

#### T6.2 Volcano 重装

```bash
./deploy-cluster.sh --steps volcano
```

```text
✅ HAMi scheduler 在位(kube-system/hami-scheduler)
✅ registry 10.66.3.21:31148/v2/ 可达
✅ 前置检查通过(registry=registry.cubestack.io:5000, ns=volcano-system)
✅   镜像就绪: 新推 0 个, 已在 registry 跳过 3 个
✅ Volcano 部署完成: volcano-controllers/scheduler/admission @ volcano-system
VOLCANO_REINSTALL_RC=0

helm status volcano → deployed（LAST DEPLOYED 23:21:46）
volcano-admission/controllers/scheduler → 1/1 Running
jobs.batch.volcano.sh → 2026-11-23T15:21:53Z
kubectl get queue → default/root
```

#### T6.3 HAMi 卸载 / 重装

```bash
CUBESTACK_MODULE_ACTION=uninstall bash deployments/scripts/modules/03_addon/15_hami.sh
```

```text
→    hami: helm uninstall hami(ns=kube-system)...
→    清理残留(webhook/RBAC/job/configmap/serviceaccount)...
✅   HAMi 已卸载(hami @ kube-system)
HAMI_UNINSTALL_RC=0

kubectl -n kube-system get deploy hami-scheduler        → NotFound
kubectl get mutatingwebhookconfiguration hami-webhook   → NotFound
kubectl -n kube-system get cm hami-scheduler-device     → NotFound
kubectl -n volcano-system get pods                      → 3×Running（未受影响）
```

```bash
./deploy-cluster.sh --steps hami
```

```text
✅ 前置检查通过(server=v1.35.8, registry=registry.cubestack.io:5000)
⚠    mirrors/.../kube-webhook-certgen 的离线 tar 为单架构，无法保留 chart digest 钉子
⚠    → certgen 引用降级为 tag: v1.6.9(镜像内容仍来自本次推送的同一 tar)
✅   镜像就绪: 新推 0 个, 已在 registry 跳过 3 个
✅ HAMi(MetaX 模式)部署完成: hami-scheduler @ kube-system
HAMI_REINSTALL_RC=0

helm status hami → deployed（LAST DEPLOYED 23:23:34）
hami-scheduler → 2/2 Running
hami-webhook → 1 webhook
worker01/02 allocatable → sgpu=128
```

> certgen 单架构降级是 `docs/hami.md` §2.2 已记录的已知行为（离线 docker-archive 无法保留 index digest），本次重装复现，属预期。

#### T6.4 重装后 sample Job

```bash
kubectl create ns hami-demo
kubectl apply -f docs/volcano-example-job.yaml
```

```text
volcano-sgpu-demo   Running   2   2   3m4s
volcano-sgpu-demo-sgpu-0   1/1 Running  cubestack-k8s-worker02
volcano-sgpu-demo-sgpu-1   1/1 Running  cubestack-k8s-worker01
pod-0 schedulerName=hami-scheduler  alloc=GPU-43110603...,Metax-SGPU,8192,25:;
pod-1 schedulerName=hami-scheduler  alloc=GPU-e3980126...,Metax-SGPU,8192,25:;
```

**结论：✅ 通过**。Volcano/HAMi 两次卸载均 RC=0，清理干净且互不影响；两次重装 RC=0（镜像均跳过推送）；重装后 sample Volcano Job 再次 Running，2 个 Pod 均带 HAMi 分配注解。

---

## 3. 功能实测项（V1–V8）

### V1 节点 sGPU 容量与 vendor 插件模式

```bash
kubectl -n metax-operator get cm metax-device-config -o yaml
kubectl get nodes -o json | jq -r '.items[] |
  select(.status.allocatable["metax-tech.com/sgpu"] != null) |
  "\(.metadata.name): sgpu=\(.status.allocatable["metax-tech.com/sgpu"])"'
kubectl -n metax-operator get pods -l app=metax-gpu-device -o wide
```

实测输出：

```text
mode: "sgpu"（CM + CR 一致）
cubestack-k8s-worker01: sgpu=128
cubestack-k8s-worker02: sgpu=128
metax-gpu-device-j68fb   1/1 Running  worker01
metax-gpu-device-xhjlh   1/1 Running  worker02
```

**判定：✅ 通过**。所有 GPU 节点 advertise `metax-tech.com/sgpu`，`metax-tech.com/gpu=0`；合计 256。

**⚠️ 关于“16 vs 128”的说明（本次已解释）**：`mx-smi` 的 Sliced GPU 表只列“当前已实例化的切片”，不是容量；节点注解 `node-gpu-devices` 明确每卡 `totalDevCount=16`，8×16=128。本次 worker01 上 16 个 25% Pod 对应 16 行切片；worker02 的 100% Pod 走 native 整卡分配，不产生 Sliced 行。两套口径并不矛盾。

### V2 HAMi 三件套（scheduler / webhook / device-config）

```bash
kubectl -n kube-system get deploy hami-scheduler
kubectl get mutatingwebhookconfiguration hami-webhook
kubectl -n kube-system get cm hami-scheduler-device -o yaml | grep -A7 'metax:'
kubectl -n kube-system logs deploy/hami-scheduler -c vgpu-scheduler-extender --tail=200
kubectl -n kube-system logs deploy/hami-scheduler -c kube-scheduler --tail=200
```

实测输出（节选）：

```yaml
    metax:
      resourceCountName: metax-tech.com/gpu
      resourceVCountName: metax-tech.com/sgpu
      resourceVMemoryName: metax-tech.com/vmemory
      resourceVCoreName: metax-tech.com/vcore
      sgpuTopologyAware: true
```

```text
# extender 日志（Verify Volcano 探针，25% 非拓扑请求）
Encoded container Devices: GPU-f411dc02-87bf-b501-bc7b-8496f179b7cb,Metax-SGPU,4096,25:
"Event occurred" ... reason="FilteringSucceed" message="find fit node(cubestack-k8s-worker02), 3 nodes not fit, 2 nodes fit(cubestack-k8s-worker01:0.00,cubestack-k8s-worker02:0.47)"
"Successfully bound pod to node" pod="volcano-verify-gpu-main-0" node="cubestack-k8s-worker02"

# kube-scheduler 日志
"Successfully bound pod to node" pod="volcano-verify-gpu-main-0" node="cubestack-k8s-worker02" evaluatedNodes=1 feasibleNodes=1
```

**判定：✅ 通过**。scheduler Ready；webhook 存在；四个 `metax-tech.com/*` 资源名齐全；`sgpuTopologyAware: true` 与安装值一致。普通 25% 请求的评分为 ~0.00/0.47（非拓扑加权）。

### V3 Webhook 自动注入 schedulerName + sGPU 共享

```bash
kubectl create ns hami-demo 2>/dev/null || true
kubectl apply -f docs/hami-example-pods.yaml
kubectl -n hami-demo get pods -o wide
kubectl -n hami-demo get pod hami-metax-sgpu -o jsonpath='{.spec.schedulerName}'
kubectl -n hami-demo get pod hami-metax-sgpu -o jsonpath='{.metadata.annotations}' | jq
kubectl -n hami-demo describe pod hami-metax-topo | grep -A2 FilteringSucceed
```

实测输出（2026-11-23 23:10）：

```text
NAME              READY   STATUS    RESTARTS   AGE   IP              NODE
hami-metax-sgpu   1/1     Running   0          5s    10.233.119.3    cubestack-k8s-worker02
hami-metax-topo   1/1     Running   0          5s    10.233.119.36   cubestack-k8s-worker02

hami-metax-sgpu: hami-scheduler
hami-metax-topo: hami-scheduler

# hami-metax-sgpu（25% / 8GiB）
"hami.io/metax-sgpu-devices-allocated": "GPU-43110603-2a5b-1de0-9d7b-ba5dae750f20,Metax-SGPU,8192,25:;"
"metax-tech.com/gpu-devices-allocated": "[[{\"uuid\":\"GPU-43110603-2a5b-1de0-9d7b-ba5dae750f20\",\"compute\":25,\"vRam\":8192}]]"
"metax-tech.com/gpu-allocated-status": "[{\"index\":0,\"name\":\"main\",\"sgpus\":[{\"uuid\":\"GPU-14690c89-2f6b-f7b9-9c33-741349a5e1c3\",\"bdf\":\"0000:e4:00.0\",\"index\":0}],\"status\":\"finished\"}]"

# hami-metax-topo（100% / 4GiB）
"hami.io/metax-sgpu-devices-allocated": "GPU-f411dc02-87bf-b501-bc7b-8496f179b7cb,Metax-SGPU,4096,100:;"
"metax-tech.com/gpu-devices-allocated": "[[{\"uuid\":\"GPU-f411dc02-87bf-b501-bc7b-8496f179b7cb\",\"compute\":100,\"vRam\":4096}]]"
"metax-tech.com/gpu-allocated-status": "...\"bdf\":\"0000:e3:00.0\"..."

# FilteringSucceed
find fit node(cubestack-k8s-worker02), 3 nodes not fit,
  2 nodes fit(cubestack-k8s-worker01:700000.00,cubestack-k8s-worker02:600000.56)
```

**判定：✅ 通过**。两个 Pod 均 Ready；未手写 `schedulerName` 的 Pod 被 webhook 注入 `hami-scheduler`；注解含 `Metax-SGPU,<vRam>,<compute>` 与 `gpu-devices-allocated` 的 `compute/vRam`；topo Pod 触发拓扑加权评分。

### V4 宿主 mx-smi 的 vGPU 切片视角

```bash
ssh <gpu-node> mx-smi
ssh <gpu-node> mx-smi --show-process
ssh <gpu-node> mx-smi --show-usage
ssh <gpu-node> mx-smi --show-memory
ssh <gpu-node> mx-smi topo -m
```

本次在两个时点采集：① 旧负载清理后（空载基线）；② V3 两个示例 Pod + V7 两个 torch demo 运行中（worker02）。

空载（worker01，23:09 / 23:18）：

```text
Sliced GPU 行数：0
GPU0..GPU7 全部 0% / 860 MiB；sGPU-M 视是否曾创建过切片而定（见 §1.3）
```

带负载（worker02，2026-11-23 23:11：V3 的 25% Pod 在 GPU7；V7 时 GPU4/5 各有 torch demo）：

```text
| Minor    GPU    sGPU-Id    Compute | Vram Quota          | sGPU-Util            |
| 002      4      0          25%     | 2324/8192 MiB       | 56%                  |
| 001      5      0          25%     | 2324/8192 MiB       | 57%                  |
| 000      7      0          25%     | 0/8192 MiB          | 0%                   |
```

```text
# --show-process
|  4-s0                852237         python3                      2324           |
|  5-s0                851940         python3                      2324           |

# --show-usage
GPU#4  MXC550  0000:a3:00.0   GPU: 56 % / VPUE: 0 % / VPUD: 0 %
GPU#5  MXC550  0000:a4:00.0   GPU: 57 % / VPUE: 0 % / VPUD: 0 %

# --show-memory
GPU#4: vis_vram used 3261204 KB (4.8%)；GPU#5: 3261208 KB (4.8%)
```

主表物理卡（worker02，V7 运行中）：

```text
| 4     MetaX C550 | 4  Off | 0000:a3:00.0 | 56% Enabled |
| 327W / 450W      | 64C P9 | 3184/65536 MiB | Available  |
| 5     MetaX C550 | 5  Off | 0000:a4:00.0 | 57% Enabled |
| 320W / 450W      | 54C P9 | 3184/65536 MiB | Available  |
| 6     MetaX C550 | 6  Off | 0000:e3:00.0 | 0% Disabled  |
| 7     MetaX C550 | 7  Off | 0000:e4:00.0 | 0% Enabled   |
```

**判定：✅ 通过**。Sliced GPU 表按切片显示 `Compute` 配额、`Vram Quota 已用/配额`、`sGPU-Util`；`--show-process` 的 `<gpu>-s<N>`（如 `4-s0`）与 `--show-usage`/`--show-memory` 均与切片对应。`kubectl top` 不显示 GPU；GPU 消耗只能靠 mx-smi / Pod 注解 / HAMi 日志。

### V5 拓扑感知调度（仅 vcore=100 生效）

```bash
kubectl get node <node> -o jsonpath='{.metadata.annotations}' \
  | jq 'with_entries(select(.key|startswith("metax-tech.com/gpu.topology")))'
kubectl get node <node> \
  -o jsonpath='{.metadata.annotations.metax-tech\.com/node-gpu-devices}' | jq
kubectl -n kube-system get cm hami-scheduler-device -o yaml | grep -A7 'metax:'
kubectl -n kube-system logs deploy/hami-scheduler -c vgpu-scheduler-extender \
  --tail=200 | grep -E 'Metax-SGPU|NodeFitPod|NodeUnfitPod'
kubectl -n hami-demo describe pod hami-metax-topo | grep -A2 FilteringSucceed
```

本次除 V3 的 `hami-metax-topo` 外，额外创建了 8 个 `vcore=100` + `spread` 的 Pod（`hami-topo-0..7`）验证分散效果，采集后删除。

节点注解（worker01/worker02 一致）：

```json
{
  "metax-tech.com/gpu.topology.losses": "{\"1\":530,\"2\":840,\"3\":1090,\"4\":1120,\"5\":1090,\"6\":840,\"7\":530,\"8\":0}",
  "metax-tech.com/gpu.topology.scores": "{\"1\":0,\"2\":110,\"3\":250,\"4\":500,\"5\":780,\"6\":1170,\"7\":1590,\"8\":2120}",
  "metax-tech.com/gpu.topology.zones": "{\"metadata\":{},\"zones\":[{\"name\":\"gpu-group-0\",\"type\":\"DirectLink\",\"attributes\":[{\"name\":\"topologyLinkWeight\",\"value\":\"60\"}],\"resources\":[{\"name\":\"metax-tech.com/gpu\",\"capacity\":\"8\",\"allocatable\":\"8\",\"available\":\"8\"}]}]}"
}
```

`node-gpu-devices`（节选）：每卡 `totalDevCount=16`、`totalCompute=100`、`totalVRam=65536`、`linkZone=1`，`numa` 依次 0/0/2/2/4/4/6/6。

8 个 100% Pod 的落位（2026-11-23 23:11）：

```text
hami-topo-0  worker02  0000:a4:00.0  (NUMA 4)
hami-topo-1  worker02  0000:a3:00.0  (NUMA 4)
hami-topo-2  worker02  0000:66:00.0  (NUMA 2)
hami-topo-3  worker02  0000:63:00.0  (NUMA 2)
hami-topo-4  worker02  0000:26:00.0  (NUMA 0)
hami-topo-5  worker02  0000:23:00.0  (NUMA 0)
hami-topo-6  worker01  0000:e4:00.0  (NUMA 6)
hami-topo-7  worker01  0000:e3:00.0  (NUMA 6)
→ 8 个 Pod → 8 张不同物理 GPU；覆盖 NUMA 0/2/4/6
```

```text
# FilteringSucceed（评分随 worker02 填充递减）
hami-topo-0:  2 nodes fit(worker01:700000.00, worker02:500001.94)
hami-topo-1:  2 nodes fit(worker01:700000.00, worker02:400003.38)
hami-topo-2:  2 nodes fit(worker01:700000.00, worker02:300004.75)
hami-topo-3:  2 nodes fit(worker01:700000.00, worker02:200006.17)
hami-topo-4:  2 nodes fit(worker01:700000.00, worker02:100007.58)
hami-topo-5:  2 nodes fit(worker01:700000.00, worker02:8.98)
hami-topo-6:  1 nodes fit(worker01:700000.00)
hami-topo-7:  1 nodes fit(worker01:600001.38)

# extender 日志
"NodeFitPod" pod="hami-demo/hami-topo-4" node="cubestack-k8s-worker02" score=8.984375
"NodeFitPod" pod="hami-demo/hami-topo-7" node="cubestack-k8s-worker01" score=600001.4
"NodeUnfitPod" pod="hami-demo/hami-topo-7" node="cubestack-k8s-worker02" reason="8/8 CardInsufficientCore"
"Encoded container Devices: GPU-...,Metax-SGPU,4096,100:"
```

**判定：✅ 通过**。节点注解含 `zones/scores/losses` 与 `node-gpu-devices`（numa / linkZone / totalCompute / totalVRam）；8 个 100% Pod 分散到 8 张不同 GPU、覆盖 4 个 NUMA 值；评分呈拓扑加权（700000/600001 量级），普通 binpack 为 ~0.00–9.61；`NodeUnfitPod ... CardInsufficientCore` 正常出现。与基线“8 张不同 GPU、4 个 NUMA 组”一致（本次因 V3 已占 2 卡，分布为 worker02 6 + worker01 2，仍为 8 张不同 GPU）。

### V6 Volcano Job → HAMi sGPU 端到端

```bash
kubectl apply -f docs/volcano-example-job.yaml
kubectl -n hami-demo get vcjob volcano-sgpu-demo
kubectl -n hami-demo describe vcjob volcano-sgpu-demo
kubectl -n hami-demo get pods -l volcano.sh/job-name=volcano-sgpu-demo -o wide
kubectl -n hami-demo get pod <pod> -o jsonpath='{.spec.schedulerName}'
kubectl -n hami-demo get pod <pod> -o jsonpath='{.metadata.annotations}' \
  | jq 'with_entries(select(.key|test("sgpu|devices-allocated")))'
```

实测输出（2026-11-23 23:13）：

```text
NAME                STATUS    MINAVAILABLE   RUNNINGS   AGE
volcano-sgpu-demo   Running   2              2          2m3s

NAME                       READY   STATUS    RESTARTS   AGE    NODE
volcano-sgpu-demo-sgpu-0   1/1     Running   0          2m3s   cubestack-k8s-worker01
volcano-sgpu-demo-sgpu-1   1/1     Running   0          2m3s   cubestack-k8s-worker01

Job 级 Scheduler Name: hami-scheduler
Task Pod 级 Scheduler Name: hami-scheduler
Running: 2

# Pod 0
schedulerName=hami-scheduler
hami.io/metax-sgpu-devices-allocated: GPU-cacd9404-9913-9ae3-8eff-1c2ca3edfe7d,Metax-SGPU,8192,25:;
metax-tech.com/gpu-allocated-status: [{"...sgpus":[{"uuid":"GPU-ec47ed2a-dd08-68be-54b1-9fae4f58f8b2","bdf":"0000:e3:00.0"...}]}]
metax-tech.com/gpu-devices-allocated: [[{"uuid":"GPU-cacd9404...","compute":25,"vRam":8192}]]

# Pod 1
schedulerName=hami-scheduler
hami.io/metax-sgpu-devices-allocated: GPU-e3980126-5b13-7fc1-7d68-cbda75ed398b,Metax-SGPU,8192,25:;
metax-tech.com/gpu-allocated-status: [{"...sgpus":[{"uuid":"GPU-5398938f-4bd6-dd65-2d68-6da9c54a4f47","bdf":"0000:e4:00.0"...}]}]
metax-tech.com/gpu-devices-allocated: [[{"uuid":"GPU-e3980126...","compute":25,"vRam":8192}]]
```

> Job 创建初期出现 `Warning PodGroupPending ... 1/1 tasks in gang unschedulable`（minAvailable=2 的 gang 语义，等待 2 个 Pod 都起来），随后 Running。GPU Pod 仍由 `hami-scheduler` 调度，Volcano 只负责 Job/PodGroup 生命周期。

**判定：✅ 通过**。vcjob STATUS=Running、RUNNINGS=2；Job 级与 Pod 级 `schedulerName` 均为 `hami-scheduler`；Pod 带 HAMi 分配注解；Pod 注解显示 worker01 GPU6/GPU7 各创建 25%/8192MiB 切片（vendor device plugin 日志有对应 `created sgpu ...` 记录；本次未单独在 V6 窗口抓 worker01 的 mx-smi 画面）。

### V7 真实显存 / 算力消费（torch 2GiB + 持续 matmul）

```bash
kubectl create ns hami-demo 2>/dev/null || true
kubectl apply -f docs/hami-mem-demo.yaml
kubectl -n hami-demo wait --for=condition=Ready pod/hami-mem-demo --timeout=360s
kubectl -n hami-demo logs hami-mem-demo
kubectl -n hami-demo get pod hami-mem-demo -o jsonpath='{.metadata.annotations}' \
  | jq 'with_entries(select(.key|test("sgpu|devices-allocated")))'

kubectl apply -f docs/volcano-mem-demo.yaml
kubectl -n hami-demo get vcjob volcano-mem-demo
kubectl -n hami-demo logs -l volcano.sh/job-name=volcano-mem-demo
kubectl -n hami-demo get pod -l volcano.sh/job-name=volcano-mem-demo \
  -o jsonpath='{.items[0].spec.schedulerName}'
kubectl -n hami-demo get pod -l volcano.sh/job-name=volcano-mem-demo \
  -o jsonpath='{.items[0].metadata.annotations}' \
  | jq 'with_entries(select(.key|test("sgpu|devices-allocated")))'

ssh <gpu-node> mx-smi
ssh <gpu-node> mx-smi --show-process
ssh <gpu-node> mx-smi --show-usage
ssh <gpu-node> mx-smi --show-memory
```

实测输出（2026-11-23 23:14–23:18，两个 demo 同时在 worker02）：

```text
# HAMi Pod
allocated_bytes 2147483648
schedulerName=hami-scheduler  node=cubestack-k8s-worker02
hami.io/metax-sgpu-devices-allocated: GPU-963a8bc8-9f6f-178b-8a1e-85181989c185,Metax-SGPU,8192,25:;
metax-tech.com/gpu-allocated-status: [{"...sgpus":[{"uuid":"GPU-aaedf1e7-...","bdf":"0000:a4:00.0"...}]}]

# Volcano Job
volcano-mem-demo   Running   1   1
allocated_bytes 2147483648
schedulerName=hami-scheduler  node=cubestack-k8s-worker02
hami.io/metax-sgpu-devices-allocated: GPU-a769be12-de57-a9a8-9133-b226120173b8,Metax-SGPU,8192,25:;
metax-tech.com/gpu-allocated-status: [{"...sgpus":[{"uuid":"GPU-eaa5f2b7-...","bdf":"0000:a3:00.0"...}]}]
```

```text
# mx-smi Sliced GPU（worker02，23:17:53）
| 002      4      0          25%     | 2324/8192 MiB       | 56%                  |
| 001      5      0          25%     | 2324/8192 MiB       | 57%                  |
| 000      7      0          25%     | 0/8192 MiB          | 0%                   |

# mx-smi 主表（GPU4/GPU5）
| 4  MetaX C550 | 4 Off | 0000:a3:00.0 | 56% Enabled |
| 327W / 450W   | 64C P9 | 3184/65536 MiB | Available  |
| 5  MetaX C550 | 5 Off | 0000:a4:00.0 | 57% Enabled |
| 320W / 450W   | 54C P9 | 3184/65536 MiB | Available  |

# --show-process
|  4-s0  852237  python3  2324 |
|  5-s0  851940  python3  2324 |

# --show-usage
GPU#4: GPU 56% / VPUE 0% / VPUD 0%
GPU#5: GPU 57% / VPUE 0% / VPUD 0%

# --show-memory
GPU#4: vis_vram used 3261204 KB (4.8%)
GPU#5: vis_vram used 3261208 KB (4.8%)
```

**判定：✅ 通过**。两份 demo 日志均为 `allocated_bytes 2147483648`；注解均为 `Metax-SGPU,8192,25`；Sliced GPU 显示 `2324/8192 MiB`、利用率 56–57%；`--show-process` 可见 `4-s0`/`5-s0` 的 python3 进程；主表物理显存 `3184/65536 MiB`。与基线（2324/8192、54–55%）一致，数值差异属于正常波动。

### V8 清理与回退

```bash
kubectl -n hami-demo delete vcjob volcano-sgpu-demo
kubectl delete ns hami-demo
# 回退 vendor 到 native：CM + ClusterOperator CR 的 mode 改回 "native"，再删除 metax-gpu-device Pod
```

本次完整执行了清理 → native 回退 → sgpu 恢复：

```text
# 清理
job.batch.volcano.sh "volcano-sgpu-demo" deleted
job.batch.volcano.sh "volcano-mem-demo" deleted
namespace "hami-demo" deleted（约 43s）
kubectl get ns hami-demo → NotFound
worker01/worker02 mx-smi Sliced 行数 → 0

# 回退 native（CM + CR 双写）
configmap/metax-device-config patched
clusteroperator.gpu.metax-tech.com/cluster-operator patched
daemon set "metax-gpu-device" successfully rolled out
cubestack-k8s-worker01 gpu=8 sgpu=0
cubestack-k8s-worker02 gpu=8 sgpu=0
mx-smi（worker01）Sliced 行数 → 0；全部 sGPU-M Disabled

# 恢复 sgpu
configmap/metax-device-config patched
clusteroperator.gpu.metax-tech.com/cluster-operator patched
daemon set "metax-gpu-device" successfully rolled out
cubestack-k8s-worker01 gpu=0 sgpu=128
cubestack-k8s-worker02 gpu=0 sgpu=128
```

恢复后再次执行 `./deploy-cluster.sh --steps verify_hami`：

```text
✅     scheduler Ready=1 ✓
✅     hami-webhook 已注册 ✓
✅     metax-tech.com/{gpu,sgpu,vcore,vmemory} 均已配置 ✓
✅   检测到 2 个 MetaX 节点(GPU=0, sGPU=256; 节点数 gpu=0/sgpu=2) ✓
✅     sGPU Pod Ready ✓
✅     admission webhook 已注入 schedulerName=hami-scheduler ✓
✅ verify_hami 完成(组件级 + MetaX sGPU 端到端)
VERIFY_HAMI_AFTER_RESTORE_RC=0
```

**判定：✅ 通过**。命名空间与 vcjob 清理干净，Sliced 切片消失；native 回退后节点重新 advertise `metax-tech.com/gpu=8`、`sgpu=0`；恢复 sgpu 后回到 `sgpu=128`、`gpu=0`，verify_hami 再次 RC=0。

---

## 4. 判定总表（一页速览）

| 编号 | 实测项 | 关键判定 | 结论 |
|---|---|---|---|
| G0 | 实机 GPU 拓扑（§1.2 原始 + §1.3 复核） | 4 个 NUMA 域 × 2 卡；8 卡 28 对全 MX1；`totalDevCount=16`/卡；sGPU-M 语义已修正 | ✅ 已实测 |
| G1 | 隔离实现（§1.4） | 无 LD_PRELOAD/libvgpu；仅透传 `/dev/sgpu000`；容器内 1 卡 / 7.59GiB；10GiB 分配 OOM | ✅ 已实测 |
| T0 | 驱动 / GPU Operator | 12 个 metax Pod Running；mx-smi 见 8 卡 | ✅ 通过 |
| T1 | vendor sgpu 模式 | `sgpu=128`/节点、`gpu=0`；CM+CR 一致 | ✅ 通过 |
| T2 | HAMi 安装 | helm deployed；scheduler 2/2；webhook | ✅ 通过 |
| T3 | verify_hami | RC=0；探针 vcore=25；webhook 注入 schedulerName | ✅ 通过 |
| T4 | Volcano 安装 | 3 控制器 1/1；12 CRD；default Queue | ✅ 通过 |
| T5 | verify_volcano | RC=0；Volcano Job → HAMi sGPU 端到端 | ✅ 通过 |
| T6 | 卸载 / 重装 | 两次卸载/重装 RC=0；互不影响；sample Job 再次 Running | ✅ 通过 |
| V1 | sGPU 容量 | 128/节点（8×16）；Sliced 行=当前实例数 | ✅ 通过 |
| V2 | HAMi 三件套 | scheduler / webhook / device-config；topology=true | ✅ 通过 |
| V3 | webhook + 共享 | hami-scheduler 注入；25% / 100% 注解正确 | ✅ 通过 |
| V4 | mx-smi 四视图 | Sliced/Process/Usage/Memory 全部对应 | ✅ 通过 |
| V5 | 拓扑感知 | 8 Pod → 8 GPU、覆盖 4 NUMA；拓扑评分 700000/600001 | ✅ 通过 |
| V6 | Volcano Job | Job+Pod 双 schedulerName；2 个 25% 切片 | ✅ 通过 |
| V7 | 真实消费 | allocated_bytes=2147483648；2324/8192、56–57% | ✅ 通过 |
| V8 | 清理 / 回退 | 切片归零；native gpu=8 / sgpu=0；恢复 128；verify RC=0 | ✅ 通过 |

---

## 5. 常用命令速查

> 容器 c 内实际路径：`/opt/cubestack-installer/deployments/scripts/deploy-cluster.sh`；模块脚本在 `/opt/cubestack-installer/deployments/scripts/modules/03_addon/`。下文保留原手册的相对路径写法。

### 5.1 安装 / 卸载 / 自动验证

```bash
sudo ./deploy-cluster.sh --steps hami                    # 【源】
sudo ./deploy-cluster.sh --enable hami                  # 【源】持久启用（本次未执行，保持测试态）
sudo ./deploy-cluster.sh --steps verify_hami            # 【源】
sudo ./deploy-cluster.sh --steps volcano                # 【源】
sudo ./deploy-cluster.sh --enable volcano               # 【源】持久启用（本次未执行）
sudo ./deploy-cluster.sh --steps verify_volcano         # 【源】
sudo env CUBESTACK_MODULE_ACTION=uninstall \
  bash deployments/scripts/modules/03_addon/15_hami.sh      # 【源 hami §3】
sudo env CUBESTACK_MODULE_ACTION=uninstall \
  bash deployments/scripts/modules/03_addon/16_volcano.sh   # 【源 volcano §3】
bash deployments/scripts/tools/tests/test-hami-module.sh     # 【源 hami §9】
bash deployments/scripts/tools/tests/test-volcano-module.sh  # 【源 volcano §6】
helm -n kube-system list | grep hami                  # 【补】
helm -n volcano-system list | grep volcano            # 【补】
```

### 5.2 HAMi 组件：状态 / 配置 / 日志

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/instance=hami -o wide   # 【源】
kubectl -n kube-system get deploy hami-scheduler                             # 【源】
helm -n kube-system status hami                                              # 【源】
kubectl -n kube-system get cm hami-scheduler-device -o yaml                  # 【源】
kubectl -n kube-system get cm hami-scheduler-device -o yaml | grep -A7 'metax:'   # 【源 hami §8.3】
kubectl get mutatingwebhookconfiguration hami-webhook                        # 【源 hami §7】
kubectl -n kube-system logs deploy/hami-scheduler -c vgpu-scheduler-extender --tail=200   # 【源】
kubectl -n kube-system logs deploy/hami-scheduler -c kube-scheduler --tail=200            # 【源】
kubectl -n kube-system logs deploy/hami-scheduler -c vgpu-scheduler-extender \
  --tail=200 | grep -E 'Metax-SGPU|NodeFitPod|NodeUnfitPod'                            # 【源 hami §8.2】
kubectl -n kube-system get cm hami-scheduler-device -o jsonpath='{.data}' | jq          # 【补】
```

### 5.3 Volcano 组件 / Job

```bash
kubectl -n volcano-system get pods,deploy,jobs -o wide                       # 【源】
kubectl -n volcano-system get deploy,pods                                    # 【源 volcano §7】
helm -n volcano-system status volcano                                        # 【源】
kubectl get crd jobs.batch.volcano.sh                                        # 【源】
kubectl get crd | grep volcano                                               # 【补】
kubectl get queue                                                            # 【源】
kubectl -n volcano-system logs deploy/volcano-controllers --tail=100         # 【源】
kubectl -n volcano-system logs deploy/volcano-scheduler --tail=100           # 【源】
kubectl -n volcano-system logs deploy/volcano-admission --tail=100           # 【源】
kubectl -n hami-demo get vcjob                                               # 【源】
kubectl -n hami-demo describe vcjob volcano-sgpu-demo                        # 【源】
kubectl -n hami-demo get pods -l volcano.sh/job-name=volcano-sgpu-demo -o wide   # 【源】
kubectl -n hami-demo logs -l volcano.sh/job-name=volcano-mem-demo           # 【源】
```

### 5.4 工作负载：创建 / 等待 / 查看

```bash
kubectl create ns hami-demo 2>/dev/null || true                             # 【源】
kubectl apply -f docs/hami-example-pods.yaml                                # 【源】V3
kubectl apply -f docs/hami-mem-demo.yaml                                    # 【源】V7
kubectl apply -f docs/volcano-example-job.yaml                              # 【源】V6
kubectl apply -f docs/volcano-mem-demo.yaml                                 # 【源】V7
kubectl -n hami-demo wait --for=condition=Ready pod/hami-mem-demo --timeout=360s  # 【源】
kubectl -n hami-demo get pods -o wide                                       # 【源】
kubectl -n hami-demo logs hami-mem-demo                                     # 【源】
kubectl -n hami-demo describe pod <pod>                                     # 【补】
kubectl get events -n hami-demo --sort-by=.lastTimestamp | tail -30          # 【补】
kubectl -n hami-demo get pods -o json | jq -r '.items[] |
  "\(.metadata.name)  sched=\(.spec.schedulerName)  node=\(.spec.nodeName // "-")  phase=\(.status.phase)"'  # 【补】
```

### 5.5 分配结果：schedulerName / Pod 注解

```bash
kubectl -n hami-demo get pod <pod> -o jsonpath='{.spec.schedulerName}'       # 【源】hami-scheduler
kubectl -n hami-demo get pod <pod> -o jsonpath='{.metadata.annotations}' | jq  # 【源】
kubectl -n hami-demo get pod <pod> -o jsonpath='{.metadata.annotations}' \
  | jq 'with_entries(select(.key|test("sgpu|devices-allocated")))'          # 【源 volcano §6】
kubectl -n hami-demo get pod -l volcano.sh/job-name=volcano-mem-demo \
  -o jsonpath='{.items[0].spec.schedulerName}'                              # 【源 volcano §8.5】
kubectl -n hami-demo get pod -l volcano.sh/job-name=volcano-mem-demo \
  -o jsonpath='{.items[0].metadata.annotations}' \
  | jq 'with_entries(select(.key|test("sgpu|devices-allocated")))'          # 【源 volcano §8.5】
```

三个关键注解 【源 hami §8.2】：

- `hami.io/metax-sgpu-devices-allocated`: `<物理 GPU UUID>,Metax-SGPU,<vRam MiB>,<compute%>`
- `metax-tech.com/gpu-devices-allocated`: JSON，含 `uuid / compute / vRam`
- `metax-tech.com/gpu-allocated-status`: sGPU UUID + 物理 GPU BDF

### 5.6 节点资源 / 拓扑注解

```bash
kubectl get nodes -o json | jq -r '.items[] |
  select(.status.allocatable["metax-tech.com/sgpu"] != null) |
  "\(.metadata.name): sgpu=\(.status.allocatable["metax-tech.com/sgpu"])"'  # 【源 hami §2.0 / §8.2】
kubectl get nodes -o json | jq -r '.items[] |
  "\(.metadata.name) gpu=\(.status.allocatable["metax-tech.com/gpu"] // 0) sgpu=\(.status.allocatable["metax-tech.com/sgpu"] // 0)"'  # 【补】
kubectl -n metax-operator get cm metax-device-config -o yaml                 # 【补】mode
kubectl -n metax-operator edit clusteroperator cluster-operator              # 【源 hami §2.0】持久化
kubectl get node <node> -o jsonpath='{.metadata.annotations}' \
  | jq 'with_entries(select(.key|startswith("metax-tech.com/gpu.topology")))'   # 【源 hami §8.3】
kubectl get node <node> \
  -o jsonpath='{.metadata.annotations.metax-tech\.com/node-gpu-devices}' | jq   # 【源 hami §8.3】
kubectl -n hami-demo describe pod <pod> | grep -A2 FilteringSucceed          # 【源 hami §8.3】
```

### 5.7 宿主 mx-smi（GPU worker 节点）

```bash
ssh <gpu-node> mx-smi                 # 【源】主表（物理卡）+ Sliced GPU（切片）
ssh <gpu-node> mx-smi --show-process # 【源】进程级显存，4-s0 = GPU4 的 sGPU-0
ssh <gpu-node> mx-smi --show-usage   # 【源】GPU / VPUE / VPUD 利用率
ssh <gpu-node> mx-smi --show-memory  # 【源】显存明细
ssh <gpu-node> mx-smi -i <gpu>       # 【源 hami §8.5】单卡
ssh <gpu-node> mx-smi topo -m        # 【源 hami §8.3】NUMA / MetaXLink 拓扑
```

| 视图 | 命令 | 含义 |
|---|---|---|
| 主 GPU 表 | `mx-smi` | 物理卡整体利用率 / 显存（含该卡上全部切片） |
| Sliced GPU | `mx-smi` | 每切片：Compute 配额、Vram Quota 已用/配额、sGPU-Util；**仅列当前已实例化切片** |
| 进程 | `mx-smi --show-process` | PID / 进程名 / 显存（MiB）；`<gpu>-s<N>` = 该 GPU 的第 N 个 sGPU |
| 利用率 | `mx-smi --show-usage` | GPU / VPUE / VPUD |
| 显存 / 单卡 / 拓扑 | `--show-memory` / `-i <gpu>` / `topo -m` | 明细 / 单卡 / 拓扑 |

### 5.8 离线镜像 / Chart / 清理回退

```bash
# 离线备料目录（seal 豁免）                【源 hami §2.2 / volcano §2.1】
#   offline-files/base/hami/       → docker.io_projecthami_hami_v2.11.0.tar 等
#   offline-files/base/volcano/    → docker.io_volcanosh_vc-scheduler_v1.16.0.tar 等
HAMI_IMAGE_MODE=offline      sudo ./deploy-cluster.sh --steps hami       # 【补】组合示例
VOLCANO_IMAGE_MODE=offline   sudo ./deploy-cluster.sh --steps volcano    # 【补】
HAMI_IMAGE_SOURCE=upstream   sudo ./deploy-cluster.sh --steps hami       # 【补】直连上游
HAMI_CHART_SYNC=online       sudo ./deploy-cluster.sh --steps hami       # 【源 hami §10】比对刷新 chart

kubectl -n hami-demo delete vcjob volcano-sgpu-demo                        # 【源 volcano §6】
kubectl delete ns hami-demo                                                # 【源 hami §8.5】
kubectl -n metax-operator delete pod -l app=metax-gpu-device              # 【源 hami §2.0】重载配置
```

---

## 6. 排障速查

| 现象 | 排查命令 / 处置 | 来源 |
|---|---|---|
| 测试 Pod 一直 Pending | `kubectl -n <ns> describe pod`；确认 `metax-tech.com/sgpu` 已 advertise；`hami-scheduler` Running；查 `CardInsufficientCore` | hami §7 / volcano §9 |
| `schedulerName` 仍是 `default-scheduler` | `kubectl get mutatingwebhookconfiguration hami-webhook`；命名空间是否被 `HAMI_WEBHOOK_WHITELIST_NAMESPACES`（默认 kube-system）跳过；Volcano Job 的 Job 级与 Pod 级都要设 | hami §7 / volcano §9 |
| `hami-admission-create/patch` Job 失败 | certgen 镜像 digest 不匹配或 registry 不可达；离线单架构 tar 会自动降级为 tag（本次重装已复现，属预期） | hami §7 |
| 镜像拉取失败 | 节点 containerd 是否信任内置 registry（`05_k8s_registry.sh`）；`*_IMAGE_MODE=offline` 时 tar 是否在 `*_OFFLINE_DIR` | hami §7 / volcano §9 |
| `*_IMAGE_MODE=auto` 推镜像失败 | 安装机不可达 `m.daocloud.io`；改用离线 tar 或 `*_IMAGE_SOURCE=upstream` | hami §7 / volcano §9 |
| Job 创建报 queue 不存在 | `kubectl get queue`，确认 controller 已建 `default` Queue | volcano §9 |
| sGPU 模式请求整卡一直 Pending | `metax-tech.com/gpu=0`；改用 `sgpu=1 + vcore=100 + vmemory=64` 等价独占 | hami §5.1 / §5.2 |
| `verify_hami` 探针超时 | 集群算力已被占满 → 释放负载或降低 `HAMI_VERIFY_VCORE` | hami §6 |
| 需要 Volcano 原生 gang | 当前不支持 MetaX vGPU + gang；GPU Pod 由 HAMi 单 Pod 调度（本次 sample Job 的 PodGroupPending 只是 gang 等待，不是调度失败） | volcano §9 / §1 |
| 看不到 GPU 用量 | `kubectl top` 不显示 GPU；用 `mx-smi` / Pod 注解 / extender 日志 | hami §8.5 |
| **`mx-smi` 没有 Sliced GPU 行 / 某卡 Disabled** | **不一定是故障**：只有 `vcore<100` 的 sGPU 请求才创建切片；`vcore=100` 走 native 整卡分配，不产生 Sliced 行。可调度容量看节点 `allocatable.sgpu` 与 `node-gpu-devices.totalDevCount` | 本次 V4/V5/V7 实测 |
| **allocatable sgpu=128 但 mx-smi 只有 16 行** | 两者口径不同：128=8 卡×16 切片容量；mx-smi 只列当前已实例化切片。可用 `kubectl get node ... node-gpu-devices` 看 `totalDevCount=16` | 本次 §1.3 实测 |
| **sGPU-M Disabled 的卡还能调度吗** | 能。本次 worker01/worker02 GPU7 都曾从 Disabled 状态成功创建 25% 切片；不要用 sGPU-M 推断“该卡不可用” | 本次 V3/V6 实测 |

---

## 7. 边界与 ⚠️ 待办

- ✅ 已解决：`24_verify_hami.sh` 注释 `vcore=60` vs 实际默认 25（实跑为 25/4）。
- ✅ 已解释：`sgpu=128` 与 mx-smi 16 行切片不矛盾——节点注解 `totalDevCount=16`/卡；mx-smi 只列当前实例。
- ✅ 已修正：`sGPU-M: Disabled` 不是“单卡关闭”；25% Pod 可落到曾 Disabled 的 GPU7（V6 实证）。
- ⚠️ 待确认：`shareNums: 4` 与 `totalDevCount=16` 的 vendor 语义映射；当前只确认 128 = 8×16，尚不清楚 `shareNums` 控制的具体切片维度。
- ⚠️ 待确认（本次新增）：native 整卡分配（`vcore=100`）会把该卡 `model` 置为 `native`，且不产生 Sliced 行；切回 sGPU 由 vendor 在后续 25% 分配时按需激活。该行为建议向 vendor 确认是否为设计预期。
- ✅ 已实测（2026-11-24）：**隔离由 vendor 驱动实现，不是 HAMi hook**——无 `LD_PRELOAD`/`libvgpu`；Pod 只透传 `/dev/sgpu000` + 对应 DRM 节点；容器内 `mx-smi` 只看到 1 张 8GiB 虚拟 GPU；10GiB 分配 OOM。HAMi 只做调度与注解。
- ⚠️ 待测（D 组）：`vcore` 的**算力**隔离强度（同卡两切片并发时的延迟劣化、利用率上限）尚无数字；目前只确认 vendor 以 `sched_quota=25` + `sched_timeslice` 实现。
- 拓扑与官方图不同：实测 8 卡为 MetaXLink 全互联（28 对全 MX1），不是官方示例图的「2 组 × 4 卡」；写 spread/binpack 预期时按实测拓扑算。
- ⚠️ 未合并 main：`hami` / `volcano` 均为临时验证分支；镜像登记（container-image-mirror / 版本树）后续单独做。
- 仅验证 MetaX：HAMi `devicePlugin.enabled=false`，NVIDIA 设备插件关闭；`volcano-vgpu-device-plugin` 不适用。
- 拓扑感知仅 `vcore=100` 生效；spread = 尽量跨 GPU/NUMA 分散，binpack = 尽量集中（受 `CardInsufficientCore` accounting 限制）。
- Volcano 只管 Job/Queue 生命周期；Gang / Queue / DRF 不参与 GPU Pod 调度（V6 的 PodGroupPending 是 gang 等待，非 GPU 调度）。
- 软/硬边界：节点 `metax-tech.com/sgpu` 是切片容量，不会按 slice 递减；**`vmemory` 是 vendor 设备级硬配额**（不是记账），`vcore` 是调度配额/时间片；实际用量以 mx-smi Sliced GPU / `--show-process` 为准。
- 本次未验证项：长时间稳定性（>1h）、算力隔离强度（D 组）、故障注入、升级/回滚（平台版本）等；建议后续专项补测。

---

## 8. 实测原始输出汇总

**完整原始日志**（共 93 个文件，约 520 KB；其中 87 个日志已归档到仓库）：

- 仓库归档：`docs/test-results/2026-11-23-hami-volcano-metax-sgpu/`
- 容器 c：`/root/hv-test-20261123/`
- 宿主：`/home/ubuntu/hv-test-20261123/`

按编号的主要文件：

| 范围 | 文件 |
|---|---|
| 环境 | `ENV-kubectl-version.txt`、`ENV-nodes.txt`、`ENV-helm-list.txt`、`ENV-worker01-os.txt`、`ENV-cluster-conf.txt` |
| T0–T2 | `T0-metax-pods.txt`、`T0-mx-smi-worker0{1,2}.txt`、`T1-*.txt`、`T2-*.txt` |
| T3 / T5 | `T3-verify-hami.txt`、`T5-verify-volcano.txt` |
| T4 | `T4-volcano-*.txt` |
| T6 | `T6-*-uninstall*.txt`、`T6-*-reinstall*.txt`、`T6-sample-after-reinstall.txt` |
| V1–V2 | `V1-*.txt`、`V2-*.txt` |
| V3–V5 | `V3-*.txt`、`V4-*.txt`、`V5-*.txt` |
| V6–V7 | `V6-*.txt`、`V7-*.txt` |
| V8 | `V8-*.txt` |

### 8.0 原手册 22:17 原始 mx-smi（保留原始数据）

> 以下为原手册 §8「V3–V5」段的 2026-11-23 22:17:29 worker01 原始输出，原样保留。该次采集时 16 个旧共享 Pod 仍在运行，因此有 16 行 Sliced、GPU0–6 Enabled、GPU7 Disabled。

```text
mx-smi  version: 2.3.4

=================== MetaX System Management Interface Log ===================
Timestamp                                         : Mon Nov 23 22:17:29 2026

Attached GPUs                                     : 8
+---------------------------------------------------------------------------------+
| MX-SMI 2.3.4                       Kernel Mode Driver Version: 3.10.33          |
| MACA Version: 3.9.1.6              BIOS Version: 1.37.2.0                       |
|------------------+-----------------+---------------------+----------------------|
| Board       Name | GPU   Persist-M | Bus-id              | GPU-Util      sGPU-M |
| Pwr:Usage/Cap    | Temp       Perf | Memory-Usage        | GPU-State            |
|==================+=================+=====================+======================|
| 0     MetaX C550 | 0           Off | 0000:23:00.0        | 0%           Enabled |
| 96W / 450W       | 41C          P0 | 860/65536 MiB       | Available            |
+------------------+-----------------+---------------------+----------------------+
| 1     MetaX C550 | 1           Off | 0000:26:00.0        | 0%           Enabled |
| 97W / 450W       | 40C          P0 | 860/65536 MiB       | Available            |
+------------------+-----------------+---------------------+----------------------+
| 2     MetaX C550 | 2           Off | 0000:63:00.0        | 0%           Enabled |
| 91W / 450W       | 36C          P0 | 860/65536 MiB       | Available            |
+------------------+-----------------+---------------------+----------------------+
| 3     MetaX C550 | 3           Off | 0000:66:00.0        | 0%           Enabled |
| 95W / 450W       | 39C          P0 | 860/65536 MiB       | Available            |
+------------------+-----------------+---------------------+----------------------+
| 4     MetaX C550 | 4           Off | 0000:a3:00.0        | 0%           Enabled |
| 91W / 450W       | 37C          P0 | 860/65536 MiB       | Available            |
+------------------+-----------------+---------------------+----------------------+
| 5     MetaX C550 | 5           Off | 0000:a4:00.0        | 0%           Enabled |
| 91W / 450W       | 33C          P0 | 860/65536 MiB       | Available            |
+------------------+-----------------+---------------------+----------------------+
| 6     MetaX C550 | 6           Off | 0000:e3:00.0        | 0%           Enabled |
| 89W / 450W       | 33C          P0 | 860/65536 MiB       | Available            |
+------------------+-----------------+---------------------+----------------------+
| 7     MetaX C550 | 7           Off | 0000:e4:00.0        | 0%          Disabled |
| 92W / 450W       | 37C          P0 | 860/65536 MiB       | Available            |
+------------------+-----------------+---------------------+----------------------+

+---------------------------------------------------------------------------------+
| Sliced GPU                                                                      |
|------------------------------------+---------------------+----------------------|
| Minor    GPU    sGPU-Id    Compute | Vram Quota          | sGPU-Util            |
|====================================+=====================+======================|
| 006      0      0          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 013      0      1          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 002      1      0          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 010      1      1          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 005      2      0          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 014      2      1          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 001      3      0          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 009      3      1          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 004      4      0          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 012      4      1          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 000      5      0          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 008      5      1          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 015      5      2          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 003      6      0          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 007      6      1          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
| 011      6      2          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+

+---------------------------------------------------------------------------------+
| Process:                                                                        |
|  GPU                    PID         Process Name                 GPU Memory     |
|                                                                  Usage(MiB)     |
|=================================================================================|
|  no process found                                                               |
+---------------------------------------------------------------------------------+

End of Log
```

解读要点（原始）：① 8 卡 BDF 与 `topo -m` 逐行吻合；② Sliced GPU 恰好 16 行，GPU7 无行且 `sGPU-M=Disabled`；③ 每卡 860 MiB 是驱动/运行时占用，不是业务显存；④ 空载 `sGPU-Util` 全 0、Process 段为空。**其中“GPU7 被关闭”的解读已由 §1.3 修正。**

### 8.1 T0 宿主 mx-smi（worker01，2026-11-23 23:07）

```text
Mon Nov 23 23:07:08 CST 2026
mx-smi  version: 2.3.4

=================== MetaX System Management Interface Log ===================
Timestamp                                         : Mon Nov 23 23:07:08 2026
Attached GPUs                                     : 8
+---------------------------------------------------------------------------------+
| MX-SMI 2.3.4                       Kernel Mode Driver Version: 3.10.33          |
| MACA Version: 3.9.1.6              BIOS Version: 1.37.2.0                       |
|------------------+-----------------+---------------------+----------------------|
| Board       Name | GPU   Persist-M | Bus-id              | GPU-Util      sGPU-M |
| Pwr:Usage/Cap    | Temp       Perf | Memory-Usage        | GPU-State            |
|==================+=================+=====================+======================|
| 0     MetaX C550 | 0           Off | 0000:23:00.0        | 0%           Enabled |
| 96W / 450W       | 41C          P0 | 860/65536 MiB       | Available            |
...
| 7     MetaX C550 | 7           Off | 0000:e4:00.0        | 0%          Disabled |
| 92W / 450W       | 37C          P0 | 860/65536 MiB       | Available            |
+---------------------------------------------------------------------------------+
| Sliced GPU（本次采集时旧共享 Pod 仍在，共 16 行，每行 25% / 0 of 8192 MiB）       |
+---------------------------------------------------------------------------------+
| Process:  no process found                                                      |
+---------------------------------------------------------------------------------+
End of Log
```

> 完整 8 卡表与 16 行 Sliced 表见 `T0-mx-smi-worker01.txt`；该文件与 §1.2 原始数据同源（采集时间 23:07，旧 Pod 尚未清理）。

### 8.2 V3/V4 worker02 带负载 mx-smi（2026-11-23 23:11）

```text
+---------------------------------------------------------------------------------+
| Sliced GPU                                                                      |
|------------------------------------+---------------------+----------------------|
| Minor    GPU    sGPU-Id    Compute | Vram Quota          | sGPU-Util            |
|====================================+=====================+======================|
| 000      7      0          25%     | 0/8192 MiB          | 0%                   |
+------------------------------------+---------------------+----------------------+
```

```text
GPU0..GPU6: sGPU-M Disabled
GPU7:       sGPU-M Enabled   (V3 的 hami-metax-sgpu 落在此卡，BDF 0000:e4:00.0)
```

### 8.3 V5 拓扑注解与 8 Pod 分布

```json
// worker01 / worker02 的 gpu.topology 注解
{
  "metax-tech.com/gpu.topology.losses": "{\"1\":530,\"2\":840,\"3\":1090,\"4\":1120,\"5\":1090,\"6\":840,\"7\":530,\"8\":0}",
  "metax-tech.com/gpu.topology.scores": "{\"1\":0,\"2\":110,\"3\":250,\"4\":500,\"5\":780,\"6\":1170,\"7\":1590,\"8\":2120}",
  "metax-tech.com/gpu.topology.zones": "{\"metadata\":{},\"zones\":[{\"name\":\"gpu-group-0\",\"type\":\"DirectLink\",\"attributes\":[{\"name\":\"topologyLinkWeight\",\"value\":\"60\"}],\"resources\":[{\"name\":\"metax-tech.com/gpu\",\"capacity\":\"8\",\"allocatable\":\"8\",\"available\":\"8\"}]}]}"
}
```

```text
node-gpu-devices（每卡）:
  totalDevCount=16, totalCompute=100, totalVRam=65536, linkZone=1, healthy=true
  numa: GPU0/1=0, GPU2/3=2, GPU4/5=4, GPU6/7=6
```

```text
8 个 vcore=100 Pod 的落位（全部 Running）:
  hami-topo-0 worker02 0000:a4:00.0
  hami-topo-1 worker02 0000:a3:00.0
  hami-topo-2 worker02 0000:66:00.0
  hami-topo-3 worker02 0000:63:00.0
  hami-topo-4 worker02 0000:26:00.0
  hami-topo-5 worker02 0000:23:00.0
  hami-topo-6 worker01 0000:e4:00.0
  hami-topo-7 worker01 0000:e3:00.0
```

### 8.4 V7 真实消费 mx-smi 四视图（worker02，2026-11-23 23:17:53）

```text
# mx-smi
| 002      4      0          25%     | 2324/8192 MiB       | 56%                  |
| 001      5      0          25%     | 2324/8192 MiB       | 57%                  |
| 000      7      0          25%     | 0/8192 MiB          | 0%                   |

| 4     MetaX C550 | 4  Off | 0000:a3:00.0 | 56% Enabled |
| 327W / 450W      | 64C P9 | 3184/65536 MiB | Available  |
| 5     MetaX C550 | 5  Off | 0000:a4:00.0 | 57% Enabled |
| 320W / 450W      | 54C P9 | 3184/65536 MiB | Available  |

# --show-process
|  4-s0                852237         python3                      2324           |
|  5-s0                851940         python3                      2324           |

# --show-usage
GPU#4  MXC550  0000:a3:00.0   GPU: 56 % / VPUE: 0 % / VPUD: 0 %
GPU#5  MXC550  0000:a4:00.0   GPU: 57 % / VPUE: 0 % / VPUD: 0 %

# --show-memory
GPU#4: vis_vram used 3261204 KB / 4.8 %
GPU#5: vis_vram used 3261208 KB / 4.8 %
```

### 8.5 V8 回退 / 恢复

```text
# native 回退后
cubestack-k8s-worker01 gpu=8 sgpu=0
cubestack-k8s-worker02 gpu=8 sgpu=0
mx-smi（worker01）Sliced 行数 = 0；全部 sGPU-M Disabled

# 恢复 sgpu 后
cubestack-k8s-worker01 gpu=0 sgpu=128
cubestack-k8s-worker02 gpu=0 sgpu=128
verify_hami RC=0
```

### 8.6 实测结论与遗留问题

**总体结论**：本次 T0–T6、V1–V8 全部通过（脚本类验证 RC=0；功能类断言逐项 ✅）。HAMi 2.11.0 + Volcano 1.16.0 在 MetaX C550（sgpu 模式）上完成了“安装 → 验证 → 共享/拓扑调度 → 真实显存消费 → 卸载/重装 → native 回退/恢复”的完整闭环。

**遗留问题**：

1. ⚠️ `shareNums: 4` 与 `totalDevCount=16` 的 vendor 语义映射待确认（不影响 128=8×16 的容量结论）。
2. ⚠️ native 整卡分配（vcore=100）会把卡的 `model` 置为 `native`、不产生 Sliced 行；后续 25% 分配可再次激活 sGPU。建议向 vendor 确认该切换是否设计预期。
3. ⚠️ 未验证长时间稳定性、多租户隔离强度、故障注入、平台升级/回滚；建议后续专项补测。
4. ⚠️ `hami` / `volcano` 分支为临时验证分支，未合并 main；镜像登记与正式发布流程后续单独做。

---

### 8.7 隔离机制实测原始输出（2026-11-24 00:18）

```text
# cat /etc/ld.so.preload
cat: /etc/ld.so.preload: No such file or directory
（rc=1）

# ls -l /proc/1/root/dev/
crw-rw---- 1 root video 236, 0  mxcd
crw------- 1 root root  235, 0  sgpu000
drwxr-xr-x 2 root root         dri
（其余为标准 /dev 节点；无 mxcd0..7，无 8 张整卡）
```

```text
# cat /proc/1/environ | tr '\0' '\n'（节选）
PATH=/opt/maca/bin:...
LD_LIBRARY_PATH=/opt/maca/lib:...
MACA_PATH=/opt/maca
（无 LD_PRELOAD / MX_VISIBLE_DEVICES / CUDA_VISIBLE_DEVICES）
```

```text
# 容器内 mx-smi
Attached GPUs : 1
| 000      0      0          25%     | 0/8192 MiB          | 0%                   |
```

```json
// crictl inspect <cid> → info.runtimeSpec.linux.devices
[
  {"path":"/dev/mxcd","major":236,"minor":0,"type":"c"},
  {"path":"/dev/dri/card8","major":226,"minor":8,"type":"c"},
  {"path":"/dev/dri/renderD135","major":226,"minor":135,"type":"c"},
  {"path":"/dev/sgpu000","major":235,"minor":0,"type":"c"}
]
```

```text
# vendor device plugin 日志（worker02）
allocate devices for pod iso-probe
created sgpu [sched_quota=25;vram_quota=8192;alias=k8s:iso-probe:main;annotations=id=GPU-d89b059f...:0;online=0] on 0000:e4:00.0#0
allocate devices for pod iso-mem-over
created sgpu [sched_quota=25;vram_quota=8192;alias=k8s:iso-mem-over:main;annotations=id=GPU-15d1e8bd...:14;online=0] on 0000:e3:00.0#0
```

```text
# 宿主 sysfs（worker02）
/sys/bus/pci/devices/0000:e4:00.0/sgpu/sgpu0
/sys/bus/pci/devices/0000:e3:00.0/sgpu/sgpu0
（同目录含 available_devcnt / total_devcnt / sched_timeslice / sched_class / create / remove）
```

```text
# 容器内 torch 尝试 10 GiB（配额 8 GiB）
cuda True
device MetaX C550
Traceback (most recent call last):
  ...
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 10.00 GiB.
GPU 0 has a total capacity of 7.59 GiB of which 7.51 GiB is free.
```

> 结论：`vmemory` 是设备级硬配额；HAMi 没有运行时 hook，隔离由 vendor device plugin/驱动完成。`vcore` 的算力隔离强度待 D 组多租户实测。

## 9. 参考

| 链接 | 说明 |
|---|---|
| `docs/hami.md` | HAMi 部署指南（沐曦 MetaX GPU 共享 / 拓扑感知调度） |
| `docs/volcano.md` | Volcano 部署与 HAMi(MetaX vGPU) 集成指南 |
| `docs/hami-example-pods.yaml` | sGPU 共享 Pod + 拓扑感知 Pod |
| `docs/hami-mem-demo.yaml` | torch 2GiB 真实消费 demo |
| `docs/volcano-example-job.yaml` | Volcano Job 示例 |
| `docs/volcano-mem-demo.yaml` | Volcano Job 真实消费 demo |
| `24_verify_hami.sh` / `25_verify_volcano.sh` | 自动验证脚本（见 §2 T3 / T5） |
| `docs/test-results/2026-11-23-hami-volcano-metax-sgpu/` | 本次实测 87 个原始日志（仓库归档） |
| `docs/test-results/2026-11-24-hami-metax-isolation/` | 2026-11-24 隔离机制实测原始证据（33 个证据文件 + README） |
| `/home/ubuntu/hv-test-20261123/` | 本次实测完整结果包（93 文件：日志 + 文档 + YAML 副本；另有 `iso/` 隔离证据） |
| `/root/hv-test-20261123/`（容器 c） | 本次实测完整结果包（容器内副本；另有 `iso/`） |

本工作区配套文档：

- `HAMi-MetaX-拓扑感知调度与sGPU共享.html` — 沐曦 MetaX 专题（含官方原图）
- `HAMi-核心概念补全-官方概念9篇全解.html` — 官方概念 9 篇全解（18 张官方原图）
- `HAMi-架构原理部署与GPU支持速览.html` — 架构 / 原理 / 部署 / GPU 支持矩阵
- `K8s-GPU调度方案全景对比与选型指南.md` — GPU 调度方案全景对比
- `HAMi-Topo-assets/metax-c550-real-topology.{svg,png}` — §1.2 图 1：实机 8×C550 拓扑
- `HAMi-Topo-assets/metax-c550-sgpu-map.{svg,png}` — §1.2 图 2：16 个 sGPU 切片映射

上游官方文档：https://project-hami.io/zh/docs/category/concepts

---

## 附录 D 三项边界实测（B0–B4，待执行计划）

> **状态：待执行。** 本附录只装三项会决定“能否上生产多租户”的边界测试：B1 显存 2× 超卖、B2 vcore 谱系、B3 spread/binpack 对照。长稳、故障注入、升级回滚、带宽基线留作专项。
> 证据命名沿用 `B1-*` / `B2-*` / `B3-*`，与既有 V1–V8 不冲突；三项都不改代码、不重装组件。
> **本手册章节映射**：B1 → §1.4/§7 + 新增越界阶梯表；B2 → §1.4/§7 + 新增曲线；B3 → §3 V5/V6 + §4/§6；B0 → §1.1。原计划引用的“图 6/7、f9/f10、§5.3/§6.1/§6.2”属于另一份长版文档编号，在本手册中按上述映射回填。

### B0 上机前置（三项共用，约 3 分钟）

上一轮 V8 留下两个会污染基线的状态：GPU4/5/7 的 `sGPU-M` 可能仍为 Enabled（粘滞），`hami-demo` 里可能有残留对象。每次 B 项前后都要存基线。

```bash
# 1) 清场（本环境 hami-demo 已在上轮 V8 清理；如存在则删）
kubectl -n hami-demo delete vcjob,pod,deploy --all --wait=true 2>/dev/null
kubectl get pods -A | grep -E 'hami-demo|volcano-sgpu' || echo CLEAN

# 2) 确认 vendor 仍是 sgpu、两节点都是 128
#    修正：本环境 CM 的 key 是 cluster-config（不是 config.yaml）
kubectl -n metax-operator get cm metax-device-config \
  -o jsonpath='{.data.cluster-config}' | grep -E 'mode|shareNums'
kubectl get nodes -o json | jq -r '.items[] |
  "\(.metadata.name) gpu=\(.status.allocatable["metax-tech.com/gpu"] // 0) sgpu=\(.status.allocatable["metax-tech.com/sgpu"] // 0)"'

# 3) 存基线（每项前后各一份：B1-before / B1-after）
ssh worker02 'mx-smi; mx-smi --show-memory' > B0-mx-smi-worker02-baseline.txt
kubectl get node cubestack-k8s-worker02 \
  -o jsonpath='{.metadata.annotations.metax-tech\.com/node-gpu-devices}' | jq . > B0-node-gpu-devices-worker02.json
```

判定：两节点 `sgpu=128 / gpu=0`，且 `mx-smi` 无 Sliced 行（或仅 Enabled 无切片），才可开始 B1。

### B1 显存 2× 超卖：失败点到底在哪一层

**缺什么**：16 × 8192 MiB = 128 GiB > 64 GiB 只是配额相加，没有一次真实越界。生产要回答三件事：第几个 GiB 开始失败、失败被谁拦住、会不会把节点拖死。

**一个前提**：GPU 级落位本身是 spread（V5 已证 8 Pod → 8 张不同卡），靠“多 Pod 堆同一张卡”堆不满 16 切片。必须用一个 Pod 一次拿满 16 个 slot（需先确认 vendor 接受 `sgpu=16 / vcore=400 / vmemory=128` 的组合）。

```yaml
# B1-fullcard.yaml —— 单 Pod 吃满一张卡：128 GiB 配额 / 400% 算力
apiVersion: v1
kind: Pod
metadata:
  name: b1-fullcard
  namespace: hami-demo
spec:
  schedulerName: hami-scheduler
  containers:
  - name: c
    image: registry.cubestack.io:5000/suanova/maca-pytorch:3.8.5.2-py312-torch2.8-v2.1-SNAPSHOT-20261121-78a83fb
    command: ["sleep", "infinity"]
    resources:
      limits:
        metax-tech.com/sgpu: 16
        metax-tech.com/vmemory: 128
        metax-tech.com/vcore: 400
```

```bash
kubectl apply -f B1-fullcard.yaml
kubectl -n hami-demo get pod b1-fullcard -w                  # 到 Running
kubectl -n hami-demo get pod b1-fullcard -o wide            # 记节点与 BDF
kubectl -n hami-demo get pod b1-fullcard -o jsonpath='{.metadata.annotations}' | jq > B1-annotations.json
```

加压脚本（容器内，4 GiB 一步，每步停 5 s 给宿主侧采样；用 `/opt/conda/bin/python3.12`，系统 python 无 torch）：

```python
# B1-alloc.py —— 逐级 alloc 到失败，打印失败类型
import torch, time
bufs, total = [], 0
for i in range(1, 41):                      # 上限 160 GiB，足够越过 128
    try:
        bufs.append(torch.empty(4 * 1024**3 // 4, dtype=torch.float32, device="cuda"))
        total += 4
        print(f"STEP {i:02d} OK total={total}GiB", flush=True)
    except RuntimeError as e:
        print(f"STEP {i:02d} FAIL total={total}GiB err={e}", flush=True)
        break
    time.sleep(5)
```

```bash
# 宿主侧同步采样（另开终端，一路到底）
for i in $(seq 1 40); do
  date '+%H:%M:%S'; ssh worker02 'mx-smi --show-memory | grep -E "vis_vram|reserved"'
  sleep 5
done > B1-samples.txt

# 失败后立刻取证
ssh worker02 'dmesg -T | tail -80'                              > B1-dmesg.txt
ssh worker02 'mx-smi; mx-smi --show-process'                    > B1-mx-smi-after.txt
kubectl -n hami-demo describe pod b1-fullcard                   > B1-describe.txt
kubectl -n hami-demo get pod b1-fullcard \
  -o jsonpath='{.status.containerStatuses[0].state}' | jq .     > B1-state.json
```

四个拦截层——判定归属：

| 层 | 现象 | 证据 | 生产含义 |
|---|---|---|---|
| L1 调度层 | Pod 一直 Pending，事件 `CardInsufficientMemory` / `NodeUnfitPod` | `B1-describe.txt`、extender 日志 | 最理想：调度期就拒绝，节点不背风险 |
| L2 hook 层 | 容器内 `RuntimeError: out of memory`，宿主 `vis_vram` 停在 8192 附近不再涨 | `B1-alloc.py` 输出 + `B1-samples.txt` | 软隔离可信；文档需写明“vmemory 到顶由 MACA 返回 OOM” |
| L3 驱动层 | 宿主 `vis_vram` 涨过 8192（甚至接近 65536）才失败 | `B1-samples.txt` 出现 >8192 的值 | hook 只计数不拦截，2× 超卖是真空头 |
| L4 宿主层 | `dmesg` 出现 `Out of memory: Killed process`，节点可能 NotReady | `B1-dmesg.txt` | 多租户不可用：一个租户能把整台拖垮 |

判读要点：L2 与 L3 的分界线是宿主 `vis_vram` 有没有越过 8192；L3 与 L4 的分界线是失败发生在容器内还是内核。

**回填**：§1.4/§7 + 新增“越界阶梯表”（步 / 累计 GiB / 切片 used / 物理 used / 结果）；图中加“配额线 128 GiB vs 物理线 64 GiB”与实测折线的交点。

### B2 vcore 谱系：把 2.24× 的单点变成曲线

**缺什么**：只有 `vcore=25 → 实测 56%` 一个点，“2.24×”是一次乘法。既不能说明线性，也不能说明 50/75/100 会怎样。

**先取两个锚点**：`vcore=100`（证明这套 workload 本身能吃满整卡）和空载 0%。锚点不正，后面全是噪声。

```yaml
# B2-matmul-job.yaml —— 吞吐可复现的固定负载，只改 VCORE
apiVersion: batch/v1
kind: Job
metadata: {name: b2-vcVCORE, namespace: hami-demo}
spec:
  backoffLimit: 0
  template:
    spec:
      schedulerName: hami-scheduler
      restartPolicy: Never
      containers:
      - name: c
        image: registry.cubestack.io:5000/suanova/maca-pytorch:3.8.5.2-py312-torch2.8-v2.1-SNAPSHOT-20261121-78a83fb
        command: ["/opt/conda/bin/python3.12", "/w/bench.py", "--n", "8192", "--it", "300"]
        resources:
          limits:
            metax-tech.com/sgpu: 1
            metax-tech.com/vmemory: 8
            metax-tech.com/vcore: VCORE
```

> 注：`/w/bench.py` 需先准备固定 matmul benchmark（或直接用 V7 的内联 matmul 命令改造）；本仓库当前没有该脚本，执行前需补齐并固定 `--n/--it`。

```bash
for v in 25 50 75 100; do
  sed "s/VCORE/$v/" B2-matmul-job.yaml | kubectl apply -f -
  kubectl -n hami-demo wait --for=condition=complete job/b2-vc$v --timeout=15m
done

# 采样：每组 60 s × 1 s，去掉前 10 s 预热后取均值
for i in $(seq 1 60); do ssh worker02 'mx-smi --show-usage' | grep -E '^GPU'; sleep 1; done > B2-usage-v25.txt
```

记录表（回填时直接填）：

| vcore | 配额比例 | 实测整卡 GPU% | 吞吐（iter/s 或 TFLOPS） | 相对 100% | 倍率 |
|---|---|---|---|---|---|
| 25 | 1/4 | 56%（已有） | 待填 | 待填 | 2.24× |
| 50 | 1/2 | 待填 | 待填 | 待填 | 待填 |
| 75 | 3/4 | 待填 | 待填 | 待填 | 待填 |
| 100 | 1/1（native） | 待填（锚点） | 待填 | 100% | 1.00× |

三种曲线，结论完全不同：

- **水平**（25/50/75 都在 56% 附近）→ 令牌桶只做“有/无”限流，vcore 不按比例分配 → “按比例软限”要推翻；
- **线性**（≈ 2.24 × vcore%）→ 可写“按比例软限，实测溢出约 2.2×”，2.24× 从单点变成斜率；
- **饱和**（25→56、50→78、75→92、100→100）→ 存在“最低配额地板”，小切片天然占便宜 → 容量规划要按 25% 切片的实际占用算，而不是按 vcore 算。

**再加一组并发**（这组才回答“4× 超卖”）：同一张卡上 2 个、4 个 25% 切片同时跑同一 workload，看总吞吐是否被封在 1 个整卡。若 4×25% 的总吞吐 ≈ 1×100%，说明 4× 只是账面数字、物理仍是 1×。

**回填**：§1.4/§7 补曲线与并发表；新增三假设曲线 + 实测点图（原计划图 f9）。

### B3 spread / binpack 对照：把疑点变成结论

**缺什么**：8 个 Pod 注解写着 spread，行为却像 binpack（§3 V5），只有推断没有对照。三种可能——① 注解被拓扑分支覆盖、② 策略另有来源、③ 注解根本没被读——目前无法区分。

三组，固定 8 Pod、同一镜像、同时提交，只改策略来源：

```bash
# A 组（基线，复现现状）：Pod 注解 spread
kubectl apply -f B3-8pods-annot-spread.yaml

# B 组：注解换 binpack
sed 's/node-scheduler-policy: spread/node-scheduler-policy: binpack/' B3-8pods-annot-spread.yaml | kubectl apply -f -

# C 组：删掉注解，只靠 Chart 默认
sed '/node-scheduler-policy/d' B3-8pods-annot-spread.yaml | kubectl apply -f -
```

> 注：`B3-8pods-annot-spread.yaml` 需按 V5 的 8 Pod 模板生成（`sgpu=1 / vcore=100 / vmemory=4`，加 `exp=b3`、`grp=A/B/C` 标签）；本仓库当前没有该文件，执行前需补齐。

```bash
# 落位矩阵（这就是判定证据）
kubectl -n hami-demo get pods -l exp=b3 -o json | jq -r '
  .items[] | "\(.metadata.labels.grp)\t\(.metadata.name)\t\(.spec.nodeName)\t\(.metadata.annotations["metax-tech.com/gpu-allocated-status"] // "-")"' \
  | sort > B3-placement.txt

# extender 决策日志（含 policy 与打分耗时）
kubectl -n kube-system logs deploy/hami-scheduler -c vgpu-scheduler-extender --since=15m \
  | grep -E 'policy|NodeFitPod|score' > B3-extender.txt
```

判定表：

| A（spread） | B（binpack） | C（无注解） | 结论 |
|---|---|---|---|
| 全落一台 | 全落一台 | 全落一台 | 注解完全没被读（拓扑分支硬编码或 bug） |
| 全落一台 | 分开 | 全落一台 | spread 在 `sgpuTopologyAware=true` 分支被忽略，binpack 正常 → 确认 bug，可提 issue |
| 全落一台 | 分开 | 分开 | Chart 默认就是 binpack，spread 是无效配置项 → 文档改写“节点级策略只能改 values” |

顺手赚一条：`B3-extender.txt` 的时间戳能算出单次打分耗时，把“调度延迟”也一起补了，不用单独排一次实验。

**回填**：§3 V5/V6 从“⚠️ 待确认”改为结论 + 判定表；§8.6 遗留第 3 项可以销掉。

### B4 耗时、风险与回填映射

| 项 | 上机耗时 | 主要风险 | 回填位置（本手册） |
|---|---|---|---|
| B1 | 40–60 min | L4 会把节点打挂；放到可重启的节点，或最后做 | §1.4 + §7 + 越界阶梯表 |
| B2 | 60–90 min（4 组 × 2 次采样） | 采样终端要一直挂着，ssh 断了就得重跑 | §1.4 + §7 + 曲线表 |
| B3 | 30–40 min | 三组之间必须清场，否则落位受残留 Pod 影响 | §3 V5/V6 + §4/§6 |

**建议顺序 B3 → B2 → B1**：B3 最便宜且顺手拿调度延迟；B1 是唯一有“打挂节点”风险的，放最后，动手前先确认 worker 能重启。

> **执行前置**：B1 前需确认 worker02 可重启（VM 控制台/`virtctl`/vmpool 任一路径），并准备回滚窗口；B2 需先补齐 `/w/bench.py`；B3 需先补齐 `B3-8pods-annot-spread.yaml`。

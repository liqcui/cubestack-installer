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

### 5.1 整卡

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

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: metax-sgpu
  annotations:
    metax-tech.com/sgpu-topology-aware: "true"   # 可选;覆盖全局 HAMI_METAX_SGPU_TOPOLOGY_AWARE
spec:
  containers:
    - name: ubuntu
      image: ubuntu:22.04
      command: ["sleep", "infinity"]
      resources:
        limits:
          metax-tech.com/sgpu: 1      # 1 个共享 GPU
          metax-tech.com/vcore: 60    # 60% 算力
          metax-tech.com/vmemory: 4   # 4 GiB 显存(裸整数单位 GiB)
```

说明:
- Pod 不需要手写 `schedulerName` —— admission webhook 检测到设备资源后自动注入 `hami-scheduler`;
- 拓扑策略(同 MetaXLink/PCIe Switch 优先)由 vendor plugin 与 HAMi 协同,`sgpuTopologyAware=true` 仅影响
  sGPU 100% 算力请求;整卡请求不受该开关影响;
- 资源名必须与 vendor plugin 一致(默认 `metax-tech.com/*`;改过插件资源名时同步改 chart `devices.metax.*`)。

## 6. 验证口径(`--steps verify_hami`)

1. `hami-scheduler` Deployment Ready;
2. `hami-webhook` MutatingWebhookConfiguration 存在;
3. `hami-scheduler-device` ConfigMap 含 `metax-tech.com/{gpu,sgpu,vcore,vmemory}`;
4. 有节点声明 `metax-tech.com/gpu` allocatable 时: 创建 sGPU 测试 Pod(`sgpu=1/vcore=60/vmemory=4`),
   断言 webhook 注入 `schedulerName=hami-scheduler`、Pod Ready;容器内 `/dev/mxcd` 存在为增强项(warn);
5. 无沐曦卡: 组件级通过并明确告警跳过 GPU 端到端(不误报)。

## 7. 故障排查

| 现象 | 排查 |
|---|---|
| 测试 Pod 一直 Pending | `kubectl describe pod`;确认 MetaX device plugin 已 advertise `metax-tech.com/sgpu`;确认 `hami-scheduler` 是 Running |
| Pod 的 `schedulerName` 仍是 `default-scheduler` | webhook 是否生效:`kubectl get mutatingwebhookconfiguration hami-webhook`;命名空间是否在 `HAMI_WEBHOOK_WHITELIST_NAMESPACES` 里(被白名单跳过) |
| `hami-admission-create/patch` Job 失败 | certgen 镜像 digest 不匹配(模块会提前校验)或 registry 不可达 |
| 镜像拉取失败 | 节点 containerd 是否信任集群内置 registry(`05_k8s_registry.sh`);`HAMI_IMAGE_MODE=offline` 时 tar 是否在 `HAMI_OFFLINE_DIR` |
| `HAMI_IMAGE_MODE=auto` 时推镜像失败 | 安装机不可达拉取源: 默认 `m.daocloud.io`;可改用离线 tar(`HAMI_IMAGE_MODE=offline` 并备料)或设 `HAMI_IMAGE_SOURCE=upstream` |

## 8. 边界(本分支)

- 只支持 **沐曦(MetaX)**;HAMi 自带 NVIDIA device plugin 固定关闭(NVIDIA 场景不在本次范围)。
- 镜像尚未登记到 `container-image-mirror` / 离线版本树(按用户口径:仅 installer 分支,验证后推送 fork)。
- chart 升级: 替换 vendored tgz + `.digest`(sha256sum),再 `HAMI_CHART_SYNC=online` 可做远端比对。

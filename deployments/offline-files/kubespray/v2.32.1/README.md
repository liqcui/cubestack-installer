# offline-files/kubespray/v2.32.1/ —— kubespray **v2.32.1 版本目录**

- 上游基线: `kubernetes-sigs/kubespray` `release-2.32` HEAD `99951b5`
  (`galaxy.yml` = 2.32.1；上游暂无同名 tag)
- 树: 上游 2.32.1 + cubestack 补丁 01–17 + 19/20(18 个有效补丁)
- Kubernetes 线: **1.36.5**(目标树 `kubelet_checksums` 表首)
- 生成方式: 以 `v2.32.0/` 为基线 `cubestack-version-dir.sh refresh`(复制未变资产)，
  从 `_upstream-release-2.32.1/` 补入 7 个新镜像 + 7 个新二进制/CRD

## 版本面

| 组件 | 版本 |
|---|---|
| Kubernetes | 1.36.5 |
| pause | 3.10.2 |
| coredns | v1.14.2 |
| etcd | v3.6.15 |
| containerd | 2.3.7 |
| crictl | 1.36.0 |
| gateway-api | 1.6.3 |
| calico | v3.32.2(补丁 14/15) |
| local-volume-provisioner | 2.10.0(补丁 17) |
| NFD | 0.19.0 |
| registry | 3.1.2(补丁 19) |
| CNI plugins / runc / nerdctl / helm / skopeo / yq | 不变 |

Ceph / Rook / CSI 镜像沿用项目钉子（Rook v1.21.1、Ceph v20.2.2、csi v3.18.1 等）。

## 内容

| 文件 | 用途 |
|---|---|
| `tree.tar.gz`(+ `.sha256`) | 预打补丁的整树(顶层 `kubespray/`；不含 `.venv` 与 `inventory/local`) |
| `VERSION.profile` | 该版本的版本面钉子(与 `config/profiles/v2.32.1.profile` 一致) |
| `kubelet/kubectl/kubeadm-1.36.5-amd64` | 节点二进制 |
| `crictl-1.36.0-...` / `containerd-2.3.7-...` / `etcd-3.6.15-...` / `runc-1.4.3.amd64` | 运行时 |
| `calicoctl-3.32.2-amd64` / `calico-3.32.2-kdd-crds.yaml` | Calico |
| `gateway-api-standard-install.yaml` | Gateway API 1.6.3 CRD(dest basename) |
| `images/*.tar` | 完整 34 个节点预加载镜像 |
| `README.md` | 本文件 |

## 校验

```bash
bash deployments/kubespray/cubestack-version-dir.sh verify v2.32.1 --full
# ✅ 二进制/CRD 15/15
# ✅ 镜像 34/34
```

`tree.tar.gz` 指纹与上游 `checksums.yml` / 暂存区 `SHA256SUMS` 均通过。

## 发布状态

- 本地: `/data/offline-files/kubespray/v2.32.1`
- MinIO: `cubestack-installer/offline-files/kubespray/v2.32.1`
  (53 objects, 6.9 GiB, 2026-11-13；`tree.tar.gz` sha256 与本地一致)

## 说明

- `v2.32.0/` 保留用于回滚；本目录已移除它不再需要的旧件(1.35.8 控制面、etcd 3.6.14、
  coredns 1.12.4、pause 3.10.1、containerd 2.3.5、crictl 1.35.0)。
- `_upstream-release-2.32.1/` 是上游增量/校验暂存区，**不是**可部署版本目录；
  本目录是它与 `v2.32.0/` 合并后的可部署形态。

# 2026-11-23 HAMi × Volcano（MetaX sGPU）实测原始日志

- 执行时间：2026-11-23 23:06–23:25 CST
- 执行环境：容器 `cubestack-install-c`（镜像 `sha-baa5dc3`）
- 集群：5 节点（3 master + worker01/worker02 各 8× MetaX C550 64GB）
- 软件：HAMi 2.11.0（`kube-system/hami`）、Volcano 1.16.0（`volcano-system/volcano`）、MetaX GPU Operator 0.15.3、K8s v1.35.8
- 结论：**T0–T6、V1–V8 全部通过**（verify_hami / verify_volcano RC=0；卸载/重装 RC=0；native 回退/恢复通过）
- 回填版手册：[`../../hami-volcano-metax-sgpu-test-manual-2026-11-23.md`](../../hami-volcano-metax-sgpu-test-manual-2026-11-23.md)

本目录存放本次实测的原始终端输出（87 个 `.txt`），未做裁剪；手册中的结论均可在这些文件中找到对应证据。本次直接 apply 的 4 份示例 YAML 已位于 `docs/` 根目录（`hami-example-pods.yaml`、`hami-mem-demo.yaml`、`volcano-example-job.yaml`、`volcano-mem-demo.yaml`），不在本目录重复。

## 文件索引

| 前缀 | 内容 |
|---|---|
| `ENV-*` | 环境采集：kubectl 版本、节点、helm、worker OS/驱动、cluster.conf 关键项 |
| `T0-*` | MetaX Operator Pod 列表；worker01/02 宿主 mx-smi |
| `T1-*` | metax-device-config、ClusterOperator CR、节点 allocatable、device plugin Pod；`T1-reload-exact.txt` 为 apply + 删除 device plugin Pod 的重载验证 |
| `T2-*` | HAMi helm status / Pod / Deployment / webhook |
| `T3-*` | verify_hami 完整输出（RC=0） |
| `T4-*` | Volcano helm status / Pods / CRD / Queue |
| `T5-*` | verify_volcano 完整输出（RC=0） |
| `T6-*` | Volcano、HAMi 卸载/重装日志与状态；重装后 sample Job |
| `V1-*` | 节点 sGPU 容量、vendor mode、device plugin |
| `V2-*` | HAMi device-config、extender/kube-scheduler 日志 |
| `V3-*` | 示例 Pod、schedulerName、HAMi 注解、FilteringSucceed |
| `V4-*` | worker02 mx-smi 四视图（空载 + 25% 切片） |
| `V5-*` | 拓扑注解、node-gpu-devices、8×vcore=100 Pod 分布与评分、extender 日志 |
| `V6-*` | Volcano sample Job、Pod 分配注解 |
| `V7-*` | torch 2GiB demo 日志/注解；mx-smi 四视图（2324/8192、56–57%） |
| `V8-*` | 清理、native 回退、sgpu 恢复、恢复后 verify_hami |

## 关键结论（详见手册 §1.3）

1. `sGPU-M: Enabled/Disabled` 是单卡当前 sGPU 运行模式，不是“该卡被永久关闭”；25% Pod 已成功落到曾显示 Disabled 的 GPU7（worker01/worker02 均有实证）。
2. `vcore=100` 请求走 native 整卡分配，不产生 Sliced GPU 行；`vcore<100` 才创建切片。
3. `allocatable.sgpu=128` 来自节点注解 `totalDevCount=16`/卡 × 8；mx-smi Sliced 表只列当前已实例化切片（0–16 行均正常）。
4. `shareNums: 4` 与 `totalDevCount=16` 的 vendor 语义映射仍待确认。

## 说明

- 日志为原始终端输出，包含内部环境 IP（10.66.3.x）与 Kubernetes 对象名；**不含密码/令牌/私钥**（`cluster.conf` 仅采集了非敏感项）。
- 宿主/容器 c 的完整结果包（93 个文件，含文档与 YAML 副本）另存于 `/home/ubuntu/hv-test-20261123/` 与 `/root/hv-test-20261123/`。

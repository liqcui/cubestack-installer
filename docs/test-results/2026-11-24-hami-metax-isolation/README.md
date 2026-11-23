# 2026-11-24 MetaX sGPU 隔离机制实测原始证据

- 执行时间：2026-11-24 00:18–00:22 CST
- 执行环境：容器 `cubestack-install-c`；worker02 `cubestack-k8s-worker02`
- 软件：HAMi 2.11.0、MetaX GPU Operator 0.15.3、vendor `mode: sgpu`
- 目标：判断 MetaX 路径的 sGPU 隔离由谁实现——HAMi `LD_PRELOAD`/`libvgpu` hook，还是 vendor device plugin + 驱动，还是仅配额记账。
- 结论：**vendor 驱动实现隔离，HAMi 只做调度与注解**；`vmemory` 是设备级硬配额（容器内 GPU 容量 7.59 GiB，10 GiB 分配 OOM）；无 `LD_PRELOAD`/`libvgpu`/`MX_VISIBLE_DEVICES`。

完整说明见手册 §1.4 / §8.7：
[`../../hami-volcano-metax-sgpu-test-manual-2026-11-23.md`](../../hami-volcano-metax-sgpu-test-manual-2026-11-23.md)

## 探针

| Pod | 配额 | 用途 |
|---|---|---|
| `iso-probe` | `sgpu=1 / vcore=25 / vmemory=8` | 检查容器内 preload、设备节点、环境变量、mx-smi |
| `iso-mem-over` | 同左 | 容器内 torch 尝试分配 10 GiB（> 8 GiB 配额） |

## 关键证据

| 检查 | 结果 | 文件 |
|---|---|---|
| `/etc/ld.so.preload` | 不存在（rc=1） | `ld-preload.txt` |
| `libvgpu` | 0 个 | `find-vgpu.txt` |
| 环境变量 | 无 `LD_PRELOAD` / `MX_VISIBLE_DEVICES` / `CUDA_VISIBLE_DEVICES` | `environ.txt`、`env.txt` |
| Pod spec | `env=null`；仅 serviceaccount 挂载；HAMi 未注入 | `pod.json`、`pod.yaml` |
| CRI devices | 仅 `/dev/mxcd`、`/dev/dri/card8`、`/dev/dri/renderD135`、`/dev/sgpu000` | `cri-inspect.json` |
| 容器内 mx-smi | `Attached GPUs: 1`；Sliced `25% / 0 of 8192 MiB` | `mx-smi-in-container.txt` |
| 超配额分配 | `torch.OutOfMemoryError`；GPU 总容量 7.59 GiB | `mem-over-run2.txt` |
| vendor 日志 | `created sgpu [sched_quota=25;vram_quota=8192;...] on 0000:e4:00.0#0` | `device-plugin-iso-log.txt` |
| 宿主 sysfs | `.../0000:e4:00.0/sgpu/sgpu0`、`.../0000:e3:00.0/sgpu/sgpu0` | `sysfs-sgpu-worker02.txt` |

## 文件索引

| 文件 | 内容 |
|---|---|
| `iso-probe.yaml` / `iso-mem-over.yaml` | 两个探针 Pod 清单 |
| `iso-collect.sh` | 容器内证据采集脚本 |
| `iso-mem-over-test.sh` / `iso-mem-over-run2.sh` | 超配额分配与宿主采样脚本 |
| `ld-preload.txt` / `find-vgpu.txt` / `find-maca.txt` | preload / libvgpu / MACA 路径检查 |
| `dev-list.txt` / `dev-all.txt` / `mountinfo.txt` | 容器内设备节点与挂载 |
| `environ.txt` / `env.txt` | 环境变量（NUL 分隔已转可读） |
| `pod.json` / `pod.yaml` | 探针 Pod 完整对象（注解、spec） |
| `cri-inspect.json` | CRI runtime spec（devices/mounts/env） |
| `mx-smi-in-container.txt` | 容器内 mx-smi（1 张 8GiB 虚拟 GPU） |
| `mem-over-run2.txt` | torch 10 GiB 分配 OOM |
| `mem-over-host-mx-smi2.txt` / `...process2.txt` / `...usage2.txt` | 超配额期间宿主视图 |
| `device-plugin-iso-log.txt` | vendor device plugin 创建 sGPU 日志 |
| `sysfs-sgpu-worker02.txt` | 宿主 `/sys/.../sgpu/` 目录 |
| `mem-over-annotations.txt` | 探针 Pod 的 HAMi 分配注解 |
| `cleanup.txt` / `mx-smi-after-cleanup.txt` | 清理与切片回收验证 |

## 说明

- 本次只做隔离机制验证；附录 D 的 B1/B2/B3（2× 超卖、vcore 谱系、spread/binpack 对照）仍为**待执行计划**。
- 日志含内部 IP / 对象名，不含密码、令牌或私钥。
- 测试后已删除 `hami-demo` 与两个探针 Pod；worker02 Sliced 行归 0。

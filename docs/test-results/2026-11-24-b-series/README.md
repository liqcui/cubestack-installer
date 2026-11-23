# 2026-11-24 B 组边界实测（B1–B3 + 同卡并发 / 25% packing）

- 执行时间：2026-11-24 00:24–01:10 CST
- 环境：容器 `cubestack-install-c`；worker01/worker02；HAMi 2.11.0（sgpu 模式）
- 目标：补齐附录 D 的边界数据——B1 显存 2× 超卖、B2 vcore 谱系与同卡并发、B3 spread/binpack 与 25% packing。
- 约束：**未重启任何服务器**；B1 的 2× 超卖在 L1（admission/scheduler）被拦截，未执行高风险分配。
- 完整说明：手册附录 D
  [`../../hami-volcano-metax-sgpu-test-manual-2026-11-23.md`](../../hami-volcano-metax-sgpu-test-manual-2026-11-23.md)

## 结果速览

### B1 显存 2× 超卖：L1 拦截

| 尝试 | 结果 | 证据 |
|---|---|---|
| `vcore: 400`（16×25%） | **admission webhook 拒绝**：`core request 400 is out of range (must be an integer between 0 and 100)` | `B1-apply.txt` |
| `sgpu: 16 / vcore: 100 / vmemory: 128` | **scheduler 拒绝**：`8/16 NodeInsufficientDevice`（每节点 8 个设备） | `B1-v100-apply.txt`、`B1-v100-describe.txt` |

结论：单 Pod 无法构造 16 切片 / 128GiB 的 2× 超卖请求；vcore 上限 100，`sgpu` 设备数上限 8/节点。当前 API 下最坏单 Pod 是 1 设备 × 100% / 64GiB。L1 拦截是理想结果，节点未承担风险。

### B2 vcore 谱系：平台曲线

固定 workload：`bench.py --n 2048 --seconds 60`，每迭代 `torch.cuda.synchronize()`；同一镜像、同一节点类型。

| vcore | 配额 | 实测整卡 GPU% | 吞吐（TFLOPS） | iter/s | 相对 100% | 每配额倍率 |
|---|---|---|---|---|---|---|
| 25 | 1/4 | 34.8% | 47.57 | 2768.89 | 68.1% | 2.72× |
| 50 | 1/2 | 36.2% | 49.33 | 2871.61 | 70.6% | 1.41× |
| 75 | 3/4 | 36.2% | 49.11 | 2858.79 | 70.3% | 0.94× |
| 100 | 1/1（native） | 51.1% | 69.89 | 4068.17 | 100% | 1.00× |

结论：25/50/75 吞吐在 47–49 TFLOPS 平台，100% 跳到 ~70 TFLOPS → **水平/地板曲线**，vcore 不按比例分配；25% 切片实际拿到约 68% 的整卡吞吐。

### B2 同卡并发（2× / 4× 25%）

用 7 个 `vcore=100` blocker 占满 worker02 的 7 张 GPU，只留 1 张；所有 benchmark Pod 均落到同一张卡（BDF `0000:23:00.0`，GPU0）。

| 组 | Pod 数 | 每 Pod TFLOPS | 总 TFLOPS | 整卡 GPU0% | 相对单 25% |
|---|---|---|---|---|---|
| 1×25%（B2 基线） | 1 | 47.57 | 47.57 | 34.8% | 100% |
| 2×25% | 2 | 39.42 / 39.50（均值 39.46） | **78.92** | 62.8% | 每 Pod 83.0% |
| 4×25% | 4 | 15.54 / 13.72 / 13.45 / 15.35（均值 14.52） | **58.06** | 69.8% | 每 Pod 30.5% |
| 1×100%（B2 基线） | 1 | 69.89 | 69.89 | 51.1% | — |

结论：
- 2×25% 每 Pod 降到单切片的 83%，总吞吐 78.92 TFLOPS；
- 4×25% 每 Pod 降到 30.5%，总吞吐 58.06 TFLOPS，低于 1×100%（69.89）；
- 并发下物理 GPU 利用率 62.8% / 69.8%，说明多进程比单进程更能填满 GPU；2× 总吞吐高于 1×100% 与本 benchmark 的单进程 host-bound 有关，**每 Pod 的劣化倍数**才是稳定结论；
- 4×25% 并未把总吞吐放大到 4×，物理 GPU 仍是上限。

### B3 spread / binpack：100% 与 25% 两个视角

**100%（每 Pod 独占整卡）**：

| 组 | 策略来源 | 落位 | GPU 分布 | 关键节点评分 |
|---|---|---|---|---|
| A | 注解 `spread` | 全部 worker02 | 8 张不同 GPU | worker01 700000、worker02 9.84 → 选 worker02 |
| B | 注解 `binpack` | 全部 worker01 | 8 张不同 GPU | worker02 -700000、worker01 9.84 → 选 worker01 |
| C | 无注解（默认） | 全部 worker01 | 8 张不同 GPU | 同 B |

**25%（每张卡可放多个切片）**：

| 组 | 策略来源 | 落位 | GPU 分布 |
|---|---|---|---|
| A | 注解 `spread` | worker01 4 + worker02 4 | **8 张不同 GPU，跨两节点** |
| B | 注解 `binpack` | 全部 worker01 | **8 张不同 GPU（未在同卡 packing）** |
| C | 无注解（默认） | 全部 worker01 | 同 B |

结论：
- 100% 视角：注解被读取（A 与 B/C 节点不同；C = B，默认等价 binpack），但节点选择与策略名**相反**（spread→已填充节点，binpack→空节点），推测 topology-aware 评分压过节点策略；
- 25% 视角：spread 的确跨节点/GPU 分散（4+4）；binpack 只做**节点级** packing（全在 worker01），**不做 GPU 级 packing**（仍分散到 8 张 GPU），默认同 binpack；
- 因此“同卡多切片”不能靠 binpack 自动实现，需要 blocker 钉住（B2 并发即用此法）。

## 文件索引

| 前缀 | 内容 |
|---|---|
| `B1-*` | vcore=400 拒绝、sgpu=16 拒绝、describe/events、清理、宿主 mx-smi |
| `B2-*` | 四个 vcore 的 Job 日志、Pod 注解、mx-smi/usage 采样、清理 |
| `B2C-*` | 同卡 2×/4×25% 并发：blocker 落位、benchmark 落位、日志、usage 采样、清理 |
| `B3-*` | 100% 三组 8 Pod 的落位、extender 日志、清理 |
| `B3S-*` | 25% 三组 8 Pod 的落位、extender 日志、清理 |
| `b1-*` / `b2-*` / `b3-*` / `b2c-*` | 本次使用的 YAML、脚本、bench.py |
| `bench.py` | 固定 matmul benchmark（n=2048，60s，逐迭代 sync） |

## 说明

- 未重启服务器；B1 未执行 128GiB 分配，避免 L4 节点风险。
- 日志含内部 IP / 对象名，不含密码、令牌或私钥。
- 测试后 `hami-demo` 已清理，worker Sliced 行归 0。

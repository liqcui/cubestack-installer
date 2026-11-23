# 2026-11-24 B 组边界实测（B1–B3）

- 执行时间：2026-11-24 00:24–00:53 CST
- 环境：容器 `cubestack-install-c`；worker01/worker02；HAMi 2.11.0（sgpu 模式）
- 目标：补齐附录 D 的三项边界——B1 显存 2× 超卖、B2 vcore 谱系、B3 spread/binpack 对照。
- 约束：**未重启任何服务器**；B1 的 2× 超卖场景在 L1（admission/scheduler）被拦截，未执行高风险分配。
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

结论：25/50/75 吞吐在 47–49 TFLOPS 平台，100% 跳到 ~70 TFLOPS → **水平/地板曲线**，vcore 不按比例分配；25% 切片实际拿到约 68% 的整卡吞吐。绝对 GPU% 低于 V7 的 56%（本 benchmark 每迭代 sync，host-bound），但相对比较有效。并发 4×25% 未测（无法稳定钉在同一张卡）。

### B3 spread / binpack：注解被读，但节点选择与名称相反

8 Pod × `vcore=100`（每 Pod 独占一张 GPU），三组只改策略来源：

| 组 | 策略来源 | 落位 | GPU 分布 | 节点评分（关键） |
|---|---|---|---|---|
| A | Pod 注解 `spread` | 全部 worker02 | 8 张不同 GPU（e4/e3/a4/a3/66/63/26/23） | worker01 700000、worker02 9.84 → 选 worker02 |
| B | Pod 注解 `binpack` | 全部 worker01 | 8 张不同 GPU | worker02 -700000、worker01 9.84 → 选 worker01 |
| C | 无注解（Chart 默认） | 全部 worker01 | 8 张不同 GPU | 同 B |

结论：
- 注解**确实被读取**（A 与 B/C 节点不同；C = B，默认等价 binpack）。
- 但节点选择与策略名**相反**：spread 选了已填充的 worker02，binpack 选了空的 worker01；推测 topology-aware 的 700000/-700000 评分压过了节点策略，或评分符号/权重与名称不一致，需 HAMi/vendor 确认。
- 8×100% 无法体现 GPU 级 packing（每 Pod 独占整卡）；若要看 GPU 级 spread/binpack，应改用 8×25% 变体。

## 文件索引

| 前缀 | 内容 |
|---|---|
| `B1-*` | vcore=400 拒绝、sgpu=16 拒绝、describe/events、清理、宿主 mx-smi |
| `B2-*` | 四个 vcore 的 Job 日志、Pod 注解、mx-smi/usage 采样、清理 |
| `B3-*` | 三组 8 Pod 的落位、extender 日志、清理 |
| `b1-*` / `b2-*` / `b3-*` | 本次使用的 YAML、脚本、bench.py |
| `bench.py` | 固定 matmul benchmark（n=2048，60s，逐迭代 sync） |

## 说明

- 未重启服务器；B1 未执行 128GiB 分配，避免 L4 节点风险。
- 日志含内部 IP / 对象名，不含密码、令牌或私钥。
- 测试后 `hami-demo` 已清理，worker Sliced 行归 0。

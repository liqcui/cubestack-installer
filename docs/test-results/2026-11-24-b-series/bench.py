import argparse, json, time
import torch

p = argparse.ArgumentParser()
p.add_argument("--n", type=int, default=2048)
p.add_argument("--seconds", type=float, default=60)
a = p.parse_args()

assert torch.cuda.is_available(), "cuda not available"
print("device", torch.cuda.get_device_name(0), flush=True)
x = torch.randn(a.n, a.n, device="cuda", dtype=torch.float32)
# Warmup (same expression as the V7 demo, known to work on MetaX/MACA)
for _ in range(3):
    y = x @ x
    torch.cuda.synchronize()

t0 = time.time()
it = 0
while time.time() - t0 < a.seconds:
    y = x @ x
    torch.cuda.synchronize()
    it += 1
dt = time.time() - t0
print(json.dumps({
    "n": a.n,
    "seconds": round(dt, 3),
    "iters": it,
    "iter_per_sec": round(it / dt, 2),
    "tflops": round(2 * a.n**3 * it / dt / 1e12, 2),
}), flush=True)

"""Train the square classifier and export it for web/core/classifier.js.

    python3 training/train.py --train dirA dirB --val unseen=dirV seen=dirW \
        --out web/model/pieces-v1 --epochs 8

Each directory holds crops.u8 / labels.u8 from make_crops.mjs. The export is a float32 .bin plus a
.json manifest. Batch normalisation is folded into the convolutions, so the JS runtime only needs
3x3 convolutions, 2x2 max pooling and dense layers (OIHW kernels, CHW flatten).
"""

import argparse
import json
import os
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

CLASSES = ["", "P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"]
CROP = 32


def load(dirs):
    xs, ys = [], []
    for d in dirs:
        x = np.fromfile(os.path.join(d, "crops.u8"), np.uint8).reshape(-1, CROP, CROP)
        y = np.fromfile(os.path.join(d, "labels.u8"), np.uint8)
        assert len(x) == len(y), d
        xs.append(x)
        ys.append(y)
    return np.concatenate(xs), np.concatenate(ys)


class Net(nn.Module):
    def __init__(self, channels, hidden):
        super().__init__()
        self.convs = nn.ModuleList()
        self.norms = nn.ModuleList()
        cin = 1
        for c in channels:
            self.convs.append(nn.Conv2d(cin, c, 3, padding=1, bias=False))
            self.norms.append(nn.BatchNorm2d(c))
            cin = c
        flat = cin * (CROP // 2 ** len(channels)) ** 2
        self.d0 = nn.Linear(flat, hidden)
        self.d1 = nn.Linear(hidden, len(CLASSES))
        self.drop = nn.Dropout(0.2)

    def forward(self, x):
        for conv, norm in zip(self.convs, self.norms):
            x = F.max_pool2d(F.relu(norm(conv(x))), 2)
        x = self.drop(F.relu(self.d0(x.flatten(1))))
        return self.d1(x)


def augment(x):
    """uint8 [N, 32, 32] -> float [N, 1, 32, 32].

    Beyond camera jitter (shift, contrast, brightness, noise) this varies the drawing itself:
    stretch, shear, mirror and heavier or lighter strokes. Piece sets differ in exactly those ways,
    and without it the network memorises the glyphs of the sets it was shown.
    """
    n = x.shape[0]
    xf = (x.float() / 255.0)[:, None]

    # Stroke weight: a min filter fattens dark lines, a max filter thins them.
    r = torch.rand(n)
    strength = torch.empty(n, 1, 1, 1).uniform_(0.3, 1.0)
    thick = r < 0.25
    thin = (r >= 0.25) & (r < 0.45)
    if thick.any():
        xf[thick] = torch.lerp(xf[thick], -F.max_pool2d(-xf[thick], 3, 1, 1), strength[thick])
    if thin.any():
        xf[thin] = torch.lerp(xf[thin], F.max_pool2d(xf[thin], 3, 1, 1), strength[thin])

    # Geometry: scale each axis, shear, rotate a little, shift, and sometimes mirror.
    sx = torch.empty(n).uniform_(0.88, 1.12) * torch.where(torch.rand(n) < 0.2, -1.0, 1.0)
    sy = torch.empty(n).uniform_(0.88, 1.12)
    angle = torch.empty(n).uniform_(-0.07, 0.07)
    shear = torch.empty(n).uniform_(-0.08, 0.08)
    cos, sin = torch.cos(angle), torch.sin(angle)
    theta = torch.zeros(n, 2, 3)
    theta[:, 0, 0] = cos / sx
    theta[:, 0, 1] = (-sin + shear) / sy
    theta[:, 1, 0] = sin / sx
    theta[:, 1, 1] = cos / sy
    theta[:, :, 2] = torch.empty(n, 2).uniform_(-0.125, 0.125)
    grid = F.affine_grid(theta, (n, 1, CROP, CROP), align_corners=False)
    xf = F.grid_sample(xf, grid, mode="bilinear", padding_mode="border", align_corners=False)

    gain = torch.empty(n, 1, 1, 1).uniform_(0.7, 1.2)
    bias = torch.empty(n, 1, 1, 1).uniform_(-0.12, 0.12)
    gamma = torch.empty(n, 1, 1, 1).uniform_(0.7, 1.4)
    noise = torch.randn_like(xf) * torch.empty(n, 1, 1, 1).uniform_(0.0, 0.04)
    xf = xf.clamp(1e-4, 1.0).pow(gamma)
    xf = ((xf - 0.5) * gain + 0.5 + bias + noise).clamp(0.0, 1.0)
    return xf - 0.5


@torch.no_grad()
def evaluate(model, x, y):
    model.eval()
    preds = []
    for i in range(0, len(x), 4096):
        xb = torch.from_numpy(x[i : i + 4096]).float() / 255.0 - 0.5
        preds.append(model(xb[:, None]).argmax(1).numpy())
    pred = np.concatenate(preds)
    wrong = pred != y
    boards = wrong.reshape(-1, 64).sum(axis=1)
    return 1 - wrong.mean(), (boards == 0).mean(), (boards <= 1).mean(), pred


def export(model, channels, out, version):
    """Fold batch norm into each convolution and write the weights in runtime order."""
    tensors, blobs, layers = {}, [], []
    offset = 0

    def put(name, array):
        nonlocal offset
        a = np.ascontiguousarray(array, np.float32)
        tensors[name] = {"shape": list(a.shape), "offset": offset}
        offset += a.size
        blobs.append(a.ravel())

    for i, (conv, norm) in enumerate(zip(model.convs, model.norms)):
        scale = (norm.weight / torch.sqrt(norm.running_var + norm.eps)).detach()
        put(f"c{i}w", (conv.weight.detach() * scale[:, None, None, None]).numpy())
        put(f"c{i}b", (norm.bias.detach() - norm.running_mean * scale).numpy())
        layers += [{"type": "conv", "weight": f"c{i}w", "bias": f"c{i}b"}, {"type": "pool"}]
    put("d0w", model.d0.weight.detach().numpy())
    put("d0b", model.d0.bias.detach().numpy())
    put("d1w", model.d1.weight.detach().numpy())
    put("d1b", model.d1.bias.detach().numpy())
    layers += [{"type": "dense", "weight": "d0w", "bias": "d0b", "relu": True}, {"type": "dense", "weight": "d1w", "bias": "d1b", "relu": False}]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    np.concatenate(blobs).astype("<f4").tofile(out + ".bin")
    with open(out + ".json", "w") as f:
        json.dump({"version": version, "input": CROP, "classes": CLASSES, "layers": layers, "tensors": tensors}, f)
    print(f"exported {offset} weights -> {out}.bin / .json", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", nargs="+", required=True)
    ap.add_argument("--val", nargs="*", default=[], help="name=dir pairs, each reported separately")
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=int, default=8)
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--lr", type=float, default=3e-3)
    ap.add_argument("--channels", default="24,48,96")
    ap.add_argument("--hidden", type=int, default=128)
    ap.add_argument("--keep-empty", type=float, default=0.3, help="fraction of empty-square crops kept for training")
    ap.add_argument("--version", default="v1")
    args = ap.parse_args()

    torch.manual_seed(0)
    rng = np.random.default_rng(0)
    channels = tuple(int(c) for c in args.channels.split(","))
    x, y = load(args.train)
    keep = (y != 0) | (rng.random(len(y)) < args.keep_empty)
    x, y = x[keep], y[keep]
    print(f"train crops {len(x)}  class counts {np.bincount(y, minlength=13).tolist()}", flush=True)
    vals = {}
    for spec in args.val:
        name, d = spec.split("=", 1)
        vals[name] = load([d])
    xt, yt = torch.from_numpy(x), torch.from_numpy(y.astype(np.int64))

    model = Net(channels, args.hidden)
    steps_per_epoch = len(x) // args.batch
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=steps_per_epoch * args.epochs, pct_start=0.1)

    t0 = time.time()
    for epoch in range(args.epochs):
        model.train()
        order = torch.randperm(len(xt))
        running, seen = 0.0, 0
        for i in range(steps_per_epoch):
            idx = order[i * args.batch : (i + 1) * args.batch]
            loss = F.cross_entropy(model(augment(xt[idx])), yt[idx], label_smoothing=0.03)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            sched.step()
            running += loss.item()
            seen += 1
        msg = f"epoch {epoch + 1}/{args.epochs}  loss {running / seen:.4f}  {time.time() - t0:.0f}s"
        for name, (xv, yv) in vals.items():
            acc, perfect, near, _ = evaluate(model, xv, yv)
            msg += f"  | {name}: squares {acc * 100:.3f}% boards exact {perfect * 100:.1f}% <=1 wrong {near * 100:.1f}%"
        print(msg, flush=True)
        export(model, channels, args.out, args.version)  # keep the latest epoch usable

    for name, (xv, yv) in vals.items():
        _, _, _, pred = evaluate(model, xv, yv)
        confusion = np.zeros((13, 13), int)
        np.add.at(confusion, (yv, pred), 1)
        recall = {CLASSES[c] or "empty": round(float(confusion[c, c] / max(1, confusion[c].sum())), 4) for c in range(13)}
        print(f"{name} per-class recall: {recall}", flush=True)


if __name__ == "__main__":
    main()

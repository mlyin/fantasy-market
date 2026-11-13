"""Train the square classifier and export it for web/core/classifier.js.

    python3 training/train.py --train dirA dirB --val dirV --out web/model/pieces-v1 --epochs 10

Each directory holds crops.u8 / labels.u8 from make_crops.mjs. The export is a float32 .bin plus a
.json manifest; the layer order and tensor layouts (OIHW kernels, CHW flatten) match the JS runtime.
"""

import argparse
import json
import os
import time

import jax
import jax.numpy as jnp
import numpy as np
import optax

CLASSES = ["", "P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"]
CROP = 32
CHANNELS = (16, 32, 64)
HIDDEN = 128


def load(dirs):
    xs, ys = [], []
    for d in dirs:
        x = np.fromfile(os.path.join(d, "crops.u8"), np.uint8).reshape(-1, CROP, CROP)
        y = np.fromfile(os.path.join(d, "labels.u8"), np.uint8)
        assert len(x) == len(y), d
        xs.append(x)
        ys.append(y)
    return np.concatenate(xs), np.concatenate(ys)


def init(key):
    params = {}
    cin = 1
    for i, cout in enumerate(CHANNELS):
        key, k = jax.random.split(key)
        params[f"c{i}w"] = jax.random.normal(k, (cout, cin, 3, 3)) * np.sqrt(2.0 / (cin * 9))
        params[f"c{i}b"] = jnp.zeros((cout,))
        cin = cout
    flat = cin * (CROP // 2 ** len(CHANNELS)) ** 2
    key, k1, k2 = jax.random.split(key, 3)
    params["d0w"] = jax.random.normal(k1, (HIDDEN, flat)) * np.sqrt(2.0 / flat)
    params["d0b"] = jnp.zeros((HIDDEN,))
    params["d1w"] = jax.random.normal(k2, (len(CLASSES), HIDDEN)) * np.sqrt(1.0 / HIDDEN)
    params["d1b"] = jnp.zeros((len(CLASSES),))
    return params


def forward(params, x):
    """x: [N, 32, 32] floats in -0.5..0.5 -> logits [N, 13]."""
    h = x[:, None, :, :]
    for i in range(len(CHANNELS)):
        h = jax.lax.conv_general_dilated(h, params[f"c{i}w"], (1, 1), "SAME", dimension_numbers=("NCHW", "OIHW", "NCHW"))
        h = jax.nn.relu(h + params[f"c{i}b"][None, :, None, None])
        h = jax.lax.reduce_window(h, -jnp.inf, jax.lax.max, (1, 1, 2, 2), (1, 1, 2, 2), "VALID")
    h = h.reshape(h.shape[0], -1)
    h = jax.nn.relu(h @ params["d0w"].T + params["d0b"])
    return h @ params["d1w"].T + params["d1b"]


def augment(key, x):
    """x: uint8 [N, 32, 32] -> float batch with shift, contrast, brightness and noise jitter."""
    k1, k2, k3, k4, k5 = jax.random.split(key, 5)
    n = x.shape[0]
    xf = x.astype(jnp.float32) / 255.0
    pad = jnp.pad(xf, ((0, 0), (2, 2), (2, 2)), mode="edge")
    off = jax.random.randint(k1, (n, 2), 0, 5)
    idx = jnp.arange(CROP)
    rows = off[:, 0, None] + idx[None, :]
    cols = off[:, 1, None] + idx[None, :]
    xf = pad[jnp.arange(n)[:, None, None], rows[:, :, None], cols[:, None, :]]
    gain = jax.random.uniform(k2, (n, 1, 1), minval=0.7, maxval=1.2)
    bias = jax.random.uniform(k3, (n, 1, 1), minval=-0.12, maxval=0.12)
    noise = jax.random.normal(k4, xf.shape) * jax.random.uniform(k5, (n, 1, 1), minval=0.0, maxval=0.04)
    xf = jnp.clip((xf - 0.5) * gain + 0.5 + bias + noise, 0.0, 1.0)
    return xf - 0.5


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", nargs="+", required=True)
    ap.add_argument("--val", nargs="*", default=[])
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=int, default=10)
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--keep-empty", type=float, default=0.35, help="fraction of empty-square crops kept for training")
    ap.add_argument("--version", default="v1")
    args = ap.parse_args()

    rng = np.random.default_rng(0)
    x, y = load(args.train)
    keep = (y != 0) | (rng.random(len(y)) < args.keep_empty)
    x, y = x[keep], y[keep]
    print(f"train crops {len(x)}  class counts {np.bincount(y, minlength=13).tolist()}", flush=True)
    xv, yv = load(args.val) if args.val else (None, None)

    steps_per_epoch = len(x) // args.batch
    total = steps_per_epoch * args.epochs
    schedule = optax.warmup_cosine_decay_schedule(0.0, args.lr, min(500, total // 20), total, args.lr * 0.02)
    opt = optax.adamw(schedule, weight_decay=1e-4)
    params = init(jax.random.PRNGKey(0))
    state = opt.init(params)

    def loss_fn(p, xb, yb):
        logits = forward(p, xb)
        labels = optax.smooth_labels(jax.nn.one_hot(yb, len(CLASSES)), 0.03)
        return optax.softmax_cross_entropy(logits, labels).mean()

    @jax.jit
    def step(p, s, key, xb, yb):
        xa = augment(key, xb)
        loss, grads = jax.value_and_grad(loss_fn)(p, xa, yb)
        updates, s = opt.update(grads, s, p)
        return optax.apply_updates(p, updates), s, loss

    @jax.jit
    def predict(p, xb):
        return jnp.argmax(forward(p, xb.astype(jnp.float32) / 255.0 - 0.5), axis=1)

    def evaluate(p, xe, ye):
        preds = []
        for i in range(0, len(xe), 4096):
            preds.append(np.asarray(predict(p, jnp.asarray(xe[i : i + 4096]))))
        pred = np.concatenate(preds)
        wrong = pred != ye
        boards = wrong.reshape(-1, 64).sum(axis=1)
        return 1 - wrong.mean(), (boards == 0).mean(), (boards <= 1).mean(), pred

    key = jax.random.PRNGKey(1)
    t0 = time.time()
    for epoch in range(args.epochs):
        order = rng.permutation(len(x))
        running = 0.0
        for i in range(steps_per_epoch):
            idx = order[i * args.batch : (i + 1) * args.batch]
            key, k = jax.random.split(key)
            params, state, loss = step(params, state, k, jnp.asarray(x[idx]), jnp.asarray(y[idx]))
            running += float(loss) if i % 50 == 0 else 0.0
        msg = f"epoch {epoch + 1}/{args.epochs}  loss ~{running / max(1, steps_per_epoch // 50):.4f}  {time.time() - t0:.0f}s"
        if xv is not None:
            acc, perfect, near, _ = evaluate(params, xv, yv)
            msg += f"  val square acc {acc * 100:.3f}%  boards perfect {perfect * 100:.1f}%  <=1 error {near * 100:.1f}%"
        print(msg, flush=True)

    if xv is not None:
        acc, perfect, near, pred = evaluate(params, xv, yv)
        confusion = np.zeros((13, 13), int)
        np.add.at(confusion, (yv, pred), 1)
        print("per-class recall:", {CLASSES[c] or "empty": round(confusion[c, c] / max(1, confusion[c].sum()), 4) for c in range(13)})

    # Export.
    names = []
    layers = []
    for i in range(len(CHANNELS)):
        layers += [{"type": "conv", "weight": f"c{i}w", "bias": f"c{i}b"}, {"type": "pool"}]
        names += [f"c{i}w", f"c{i}b"]
    layers += [{"type": "dense", "weight": "d0w", "bias": "d0b", "relu": True}, {"type": "dense", "weight": "d1w", "bias": "d1b", "relu": False}]
    names += ["d0w", "d0b", "d1w", "d1b"]
    tensors = {}
    blobs = []
    offset = 0
    for n in names:
        a = np.asarray(params[n], np.float32)
        tensors[n] = {"shape": list(a.shape), "offset": offset}
        offset += a.size
        blobs.append(a.ravel())
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    np.concatenate(blobs).astype("<f4").tofile(args.out + ".bin")
    with open(args.out + ".json", "w") as f:
        json.dump({"version": args.version, "input": CROP, "classes": CLASSES, "layers": layers, "tensors": tensors}, f)
    print(f"exported {offset} weights -> {args.out}.bin / .json")


if __name__ == "__main__":
    main()

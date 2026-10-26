#!/usr/bin/env python3
"""Write sparse fake GGUF files with real headers, for exercising the scheduler
without downloading models. File size stands in for weight size; the content
after the header is a hole, so this uses almost no disk.

Usage: python3 -I scripts/dev/make_test_models.py OUT_DIR
"""
import os
import struct
import sys

# name, arch, layers, embd, heads, kv_heads, trained_ctx, size_mb
MODELS = [
    ("fake-1.7b-q4", "llama", 24, 2048, 32, 32, 8192, 1056),
    ("fake-1.7b-q4-oom", "llama", 24, 2048, 32, 32, 8192, 1056),
    ("fake-360m-q4", "llama", 32, 960, 15, 5, 8192, 270),
]


def s(text):
    b = text.encode()
    return struct.pack("<Q", len(b)) + b


def kv_u32(key, value):
    return s(key) + struct.pack("<I", 4) + struct.pack("<I", value)


def kv_str(key, value):
    return s(key) + struct.pack("<I", 8) + s(value)


def kv_str_array(key, items):
    out = s(key) + struct.pack("<I", 9) + struct.pack("<I", 8) + struct.pack("<Q", len(items))
    for it in items:
        out += s(it)
    return out


def header(arch, layers, embd, heads, kv_heads, ctx):
    kvs = [
        kv_str("general.architecture", arch),
        kv_str_array("tokenizer.ggml.tokens", ["<s>", "</s>"] + [f"t{i}" for i in range(1000)]),
        kv_u32(f"{arch}.block_count", layers),
        kv_u32(f"{arch}.embedding_length", embd),
        kv_u32(f"{arch}.attention.head_count", heads),
        kv_u32(f"{arch}.attention.head_count_kv", kv_heads),
        kv_u32(f"{arch}.context_length", ctx),
    ]
    return b"GGUF" + struct.pack("<IQQ", 3, 0, len(kvs)) + b"".join(kvs)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "models"
    os.makedirs(out_dir, exist_ok=True)
    for name, arch, layers, embd, heads, kv_heads, ctx, size_mb in MODELS:
        path = os.path.join(out_dir, name + ".gguf")
        with open(path, "wb") as f:
            f.write(header(arch, layers, embd, heads, kv_heads, ctx))
            f.truncate(size_mb * 1024 * 1024)
        print(path)


if __name__ == "__main__":
    main()

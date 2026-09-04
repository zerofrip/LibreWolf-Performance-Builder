#!/usr/bin/env python3
"""Analyze Phase 3 compiler-invocations.jsonl for x86-64-v3 evidence."""
from __future__ import annotations

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: analyze-compiler-invocations.py <compiler-invocations.jsonl>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    c_ok = cxx_ok = rust_ok = False
    host_c_leak = host_rust_leak = False

    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = obj.get("kind") or ""
            argv = obj.get("argv") or []
            joined = " ".join(argv)
            has_march = "-march=x86-64-v3" in joined
            has_cpu = "target-cpu=x86-64-v3" in joined
            has_win = "windows-msvc" in joined or "x86_64-pc-windows-msvc" in joined
            is_cl = kind == "clang-cl" or (argv and str(argv[0]).endswith("clang-cl"))

            if kind == "rustc":
                if has_cpu and has_win:
                    rust_ok = True
                if has_cpu and not has_win:
                    host_rust_leak = True
                continue

            if kind in ("clang", "cc", "clangxx", "cxx", "clang-cl") or is_cl:
                if has_march and not has_win and not is_cl:
                    # Host Linux clang with march is a leak. clang-cl is always target.
                    host_c_leak = True
                if not has_march:
                    continue
                if not (has_win or is_cl):
                    continue
                srcs = [a for a in argv if isinstance(a, str) and a.endswith((".c", ".cc", ".cpp", ".cxx", ".C"))]
                if kind in ("clang", "cc") or any(a.endswith(".c") for a in srcs):
                    c_ok = True
                if kind in ("clangxx", "cxx") or "-TP" in argv or any(
                    a.endswith((".cpp", ".cxx", ".cc")) for a in srcs
                ):
                    cxx_ok = True
                # clang-cl without clear extension still proves target v3 once we see any compile
                if is_cl and not srcs and ("-c" in argv or "/c" in argv):
                    # ambiguous language — do not mark both; wait for typed sources
                    pass

    out = {
        "c_target": c_ok,
        "cxx_target": cxx_ok,
        "rust_target": rust_ok,
        "host_c_march_leak": host_c_leak,
        "host_rust_target_cpu_leak": host_rust_leak,
    }
    json.dump(out, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

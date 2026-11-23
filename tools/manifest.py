"""Write corpus/manifest.json: a deterministic list of documents.

Each entry is {"path", "bytes", "sha256"}. Order is sorted by path so every
run and every engine sees the documents in the same order.
"""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
docs = []
for p in sorted(root.rglob("*.md")):
    rel = p.relative_to(root).as_posix()
    if rel.endswith("LICENSE.md"):
        continue
    data = p.read_bytes()
    docs.append({"path": rel, "bytes": len(data),
                 "sha256": hashlib.sha256(data).hexdigest()})
(root / "manifest.json").write_text(json.dumps({"docs": docs}, indent=0) + "\n")
total = sum(d["bytes"] for d in docs)
print(f"{len(docs)} docs, {total / 1e6:.1f} MB")

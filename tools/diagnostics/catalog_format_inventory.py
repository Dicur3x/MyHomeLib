"""Inventory an existing merged catalogue without opening it for writing.

Keeps small representative candidates; does not extract books or copy the DB.
"""
import argparse
import collections
import heapq
import json
import pathlib
import sqlite3
import time


def inventory(catalogue, root):
    started = time.perf_counter()
    before = catalogue.stat()
    connection = sqlite3.connect(catalogue.as_uri() + "?mode=ro&immutable=1", uri=True)
    connection.execute("PRAGMA query_only=ON")
    counts, live, candidates = collections.Counter(), collections.Counter(), {}
    sources = []
    try:
        for (value,) in connection.execute("SELECT SettingValue FROM Settings"):
            if isinstance(value, bytes):
                value = value.decode("utf-8", errors="replace")
            if not isinstance(value, str) or not value.startswith("[{"):
                continue
            try:
                items = json.loads(value)
                if isinstance(items, list):
                    sources.extend(s for s in items if isinstance(s, dict) and "root" in s)
            except ValueError:
                pass
        for book_id, folder, name, ext, size, deleted, inside in connection.execute(
            "SELECT BookID,Folder,FileName,Ext,BookSize,IsDeleted,InsideNo FROM Books"
        ):
            ext = (ext or "").lower()
            counts[ext] += 1
            if not deleted:
                live[ext] += 1
            heap = candidates.setdefault(ext, [])
            # A dozen small examples per extension keep the audit bounded, while
            # allowing fallback if a particular archive is missing or corrupt.
            # Unknown zero sizes must not displace every real small book in
            # the bounded pool (common in FB2/EPUB metadata).
            rank = int(size) if size and size > 0 else 2**63 - 1
            # Prefer ordinary ZIP/plain originals for bounded standalone samples.
            # FLibrary's stripped 7z rows often report a placeholder size of 1.
            archive_rank = 1 if str(folder or '').lower().endswith('.7z') else 0
            row = (-bool(deleted), -archive_rank, -rank, book_id, folder or "", name or "", inside, int(size or 0))
            if len(heap) < 12:
                heapq.heappush(heap, row)
            elif row > heap[0]:
                heapq.heapreplace(heap, row)
        result = []
        roots = list(dict.fromkeys([str(root)] + [s["root"] for s in sources]))
        for ext, count in counts.most_common():
            examples = []
            for deleted_rank, _, _, book_id, folder, name, inside, size in sorted(candidates.get(ext, []), reverse=True):
                paths = []
                for base in roots:
                    archive = pathlib.Path(base) / folder
                    plain = archive / (name + ext)
                    if archive.is_file():
                        paths.append({"path": str(archive), "member": name + ext})
                    elif plain.is_file():
                        paths.append({"path": str(plain), "member": ""})
                examples.append({"id": book_id, "size": size, "deleted": bool(deleted_rank), "folder": folder,
                                 "name": name, "inside": inside, "available": paths})
            result.append({"extension": ext, "records": count, "live_records": live[ext], "examples": examples})
        after = catalogue.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise RuntimeError("Catalogue changed during read-only inventory; retry after it is idle")
        return {"catalogue": str(catalogue), "size": before.st_size, "mtime_ns": before.st_mtime_ns,
                "read_only": True, "database_copied": False, "sources": sources, "formats": result,
                "seconds": round(time.perf_counter() - started, 3)}
    finally:
        connection.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("catalogue", type=pathlib.Path)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    report = inventory(args.catalogue.resolve(), args.root)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"formats": len(report["formats"]), "seconds": report["seconds"],
                      "available": [{"ext": f["extension"], "records": f["records"],
                                     "examples": sum(bool(s["available"]) for s in f["examples"])}
                                    for f in report["formats"] if f["records"] >= 4]}, ensure_ascii=False))

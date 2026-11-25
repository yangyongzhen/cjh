#!/usr/bin/env python3
"""Release 附件上传：校验回调 header → PUT 预签名地址。

用法：upload_release.py <file_path> <upload_url> <callback_b64> <project_id> [content_type]
一取一传：预签名 URL 只能用一次，每次上传前重新取。
content_type 必须使用 `upload_url` 响应里的 Content-Type（签名覆盖该头），
默认 application/octet-stream 只适用于二进制附件。
"""
import base64
import json
import os
import sys
import urllib.request


def main() -> int:
    if len(sys.argv) not in (5, 6):
        print("用法: upload_release.py <file> <url> <callback_b64> <project_id> [content_type]")
        return 2
    path, url, callback, project_id = sys.argv[1:5]
    content_type = sys.argv[5] if len(sys.argv) == 6 else "application/octet-stream"

    # 自检：回调必须是合法 base64 + 合法 JSON，且含 callbackUrl
    try:
        obj = json.loads(base64.b64decode(callback))
    except Exception as exc:  # noqa: BLE001
        print(f"callback header 非法: {exc}")
        return 3
    if not obj.get("callbackUrl"):
        print("callback header 缺 callbackUrl")
        return 3

    size = os.path.getsize(path)
    with open(path, "rb") as f:
        data = f.read()

    req = urllib.request.Request(
        url,
        data=data,
        method="PUT",
        headers={
            "x-obs-meta-project-id": project_id,
            "x-obs-acl": "private",
            "x-obs-callback": callback,
            "Content-Type": content_type,
            "Content-Length": str(size),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            print(f"STATUS {resp.status} {resp.read().decode(errors='replace')[:200]}")
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code}: {exc.read().decode(errors='replace')[:300]}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

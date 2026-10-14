#!/usr/bin/env python3
"""通过 GitHub REST API 把本地 HEAD 推送到远端，绕开被阻断的 git 协议。

背景
----
国内直连 GitHub 时，`git fetch`（HTTP GET）通常正常，
但 `git push` 用的是 HTTP POST /git-receive-pack，容易被重置或长时间挂起。
而 GitHub 的 REST API（api.github.com）走的是另一个端点，往往依然通畅。

原理
----
用 Git Data API 手工拼一次提交，语义等价于 `git push`：
    1. 把每个文件的内容 POST 成 blob
    2. 用这些 blob 组成一棵 tree
    3. 以远端当前 HEAD 为父提交，创建 commit
    4. 把 main 指向这个新 commit

关键技巧
--------
创建 commit 时显式传入本地提交的 author / committer（含日期），
这样算出来的 commit sha 与本地完全一致 —— 推送后本地与远端不会分叉，
之后网络恢复时仍可正常使用普通的 `git push`。

用法
----
    python tools/gh_api_push.py [owner/repo] [branch]

依赖：已登录的 gh CLI（用它携带凭据，脚本本身不接触任何 token）
"""

import base64
import json
import subprocess
import sys

DEFAULT_REPO = "hwx365/BackgroundRecorder"
DEFAULT_BRANCH = "main"


def run(args, cwd=None):
    result = subprocess.run(
        args, cwd=cwd, capture_output=True, text=True, encoding="utf-8"
    )
    if result.returncode != 0:
        raise RuntimeError(f"命令失败: {' '.join(args)}\n{result.stderr.strip()}")
    return result.stdout


def git(*args):
    return run(["git", *args]).strip()


def api(method, path, body=None):
    """调用 gh api，body 为 None 时是 GET。"""
    args = ["gh", "api", "-X", method, path]
    if body is not None:
        args += ["--input", "-"]
    result = subprocess.run(
        args,
        input=json.dumps(body) if body is not None else None,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        raise RuntimeError(f"API {method} {path} 失败:\n{result.stderr.strip()}")
    text = result.stdout.strip()
    return json.loads(text) if text else {}


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_REPO
    branch = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_BRANCH

    # 本地提交信息
    message = git("log", "-1", "--pretty=%B").rstrip()
    author_name = git("log", "-1", "--pretty=%an")
    author_email = git("log", "-1", "--pretty=%ae")
    author_date = git("log", "-1", "--pretty=%aI")
    committer_name = git("log", "-1", "--pretty=%cn")
    committer_email = git("log", "-1", "--pretty=%ce")
    committer_date = git("log", "-1", "--pretty=%cI")
    local_sha = git("rev-parse", "HEAD")

    print(f"本地 HEAD: {local_sha}")
    print(f"提交信息 : {message.splitlines()[0]}")

    # 远端当前 HEAD（新分支时不存在）
    parent_sha = None
    try:
        parent_sha = api("GET", f"/repos/{repo}/git/ref/heads/{branch}")["object"]["sha"]
        print(f"远端 {branch}: {parent_sha}")
    except RuntimeError:
        print(f"远端 {branch} 尚不存在，将作为首个提交推送")

    if parent_sha == local_sha:
        print("本地与远端已经一致，无需推送。")
        return

    # 1) 逐文件上传 blob
    stage_lines = git("ls-files", "--stage").splitlines()
    tree_entries = []
    for line in stage_lines:
        # 格式: <mode> <sha> <stage>\t<path>
        meta, path = line.split("\t", 1)
        mode = meta.split()[0]
        with open(path, "rb") as handle:
            content = base64.b64encode(handle.read()).decode("ascii")
        blob = api("POST", f"/repos/{repo}/git/blobs",
                   {"content": content, "encoding": "base64"})
        tree_entries.append({
            "path": path,
            "mode": mode,
            "type": "blob",
            "sha": blob["sha"],
        })
        print(f"  已上传 {path}")

    # 2) 组成 tree（不基于 base_tree，远端结果与本地完全一致）
    tree = api("POST", f"/repos/{repo}/git/trees", {"tree": tree_entries})
    print(f"tree: {tree['sha']}")

    # 3) 创建 commit —— author/committer 用本地原值，保证 sha 与本地相同
    payload = {
        "message": message,
        "tree": tree["sha"],
        "author": {"name": author_name, "email": author_email, "date": author_date},
        "committer": {"name": committer_name, "email": committer_email,
                      "date": committer_date},
    }
    if parent_sha:
        payload["parents"] = [parent_sha]

    commit = api("POST", f"/repos/{repo}/git/commits", payload)
    print(f"commit: {commit['sha']}")

    # 4) 更新分支指向
    if parent_sha:
        api("PATCH", f"/repos/{repo}/git/refs/heads/{branch}",
            {"sha": commit["sha"], "force": False})
    else:
        api("POST", f"/repos/{repo}/git/refs",
            {"ref": f"refs/heads/{branch}", "sha": commit["sha"]})

    print("推送完成。")
    print(f"  sha 与本地一致: {commit['sha'] == local_sha}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print(f"失败: {exc}")
        sys.exit(1)

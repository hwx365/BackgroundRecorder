#!/usr/bin/env python3
"""一条命令走完：提交 → 推送 → 等 GitHub 编译 → 下载 ipa → 校验。

为什么需要它
------------
这台开发机是 Windows，编译不了 iOS。所以每次改完代码都要：
提交、推送到 GitHub、等 macOS 机器跑 xcodebuild、把产物下载回来。
手工做一遍十几步，容易漏、容易看错运行 id。这个脚本把整条链固化下来。

用法
----
    python tools/rebuild.py -m "修复某某问题"      # 提交 + 推送 + 等编译 + 下载 ipa
    python tools/rebuild.py                       # 不改代码，只重跑一次流水线
    python tools/rebuild.py --no-download         # 只等到编译结束，不下 ipa
    python tools/rebuild.py --repo owner/repo     # 换仓库（默认 hwx365/BackgroundRecorder）

前置条件
--------
1. 已安装并登录 gh CLI（`gh auth status` 能通过，scope 需要 repo + workflow）
2. 已安装 python 3.9+
3. 当前分支有提交历史

设计说明
--------
* 推送走 `tools/gh_api_push.py`（REST API），不走 `git push`。
  原因见那份脚本的注释：国内直连时 git 的 push 端点常被重置，
  而 api.github.com 通常可用。两个脚本的远端 sha 与本地严格一致。
* 用「本地 HEAD 的 sha」去匹配 CI 运行，而不是「最近一次运行」——
  否则并发或延迟会让你等到别人的/上一次的构建结果。
* 退出码：0 成功，1 失败。可直接用于批处理。
"""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = REPO_ROOT.parent
DEFAULT_REPO = "hwx365/BackgroundRecorder"
DEFAULT_BRANCH = "main"
ARTIFACT_NAME = "BackgroundRecorder-unsigned-ipa"
IPA_NAME = "BackgroundRecorder-unsigned.ipa"
XCODE_SCHEME = "BackgroundRecorder"


# ---------------------------------------------------------------- 基础设施

def fix_console_encoding() -> None:
    """Windows 控制台默认 GBK，中文输出会变乱码。切成 UTF-8。"""
    if sys.platform != "win32":
        return
    os.system("chcp 65001 >nul 2>&1")
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def find_gh() -> str:
    """gh 不一定在 PATH 里（Windows 安装后常需要重开终端）。"""
    found = shutil.which("gh")
    if found:
        return found
    for candidate in (
        r"C:\Program Files\GitHub CLI\gh.exe",
        r"C:\Program Files (x86)\GitHub CLI\gh.exe",
    ):
        if Path(candidate).exists():
            return candidate
    raise SystemExit("找不到 gh CLI。装一个：winget install --id GitHub.cli -e")


GH = None


def run(args, cwd=None, check=True, capture=True):
    result = subprocess.run(
        args,
        cwd=str(cwd or REPO_ROOT),
        capture_output=capture,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and result.returncode != 0:
        raise SystemExit(
            "命令失败: " + " ".join(args) + "\n" + (result.stderr or "").strip()
        )
    return result


def gh(*args, check=True):
    return run([GH, *args], check=check)


def gh_json(*args, check=True):
    import json

    out = gh(*args, check=check).stdout.strip()
    return json.loads(out) if out else []


def step(title: str) -> None:
    print()
    print("=" * 66)
    print("  " + title)
    print("=" * 66)


# ---------------------------------------------------------------- 各阶段

def commit_if_needed(message: str | None) -> None:
    step("1/6  提交本地改动")

    status = run(["git", "status", "--short"]).stdout.strip()
    if not status:
        print("  工作区干净，没有需要提交的改动")
        return

    print("  待提交文件：")
    for line in status.splitlines():
        print("    " + line)

    if not message:
        print("\n  未提供 -m，跳过提交（只重跑流水线）")
        print("  如果这些改动应该进构建，请加上 -m \"说明\" 重跑")
        return

    run(["git", "add", "-A"])
    run(["git", "commit", "-m", message])
    head = run(["git", "log", "-1", "--pretty=%h %s"]).stdout.strip()
    print("\n  已提交: " + head)


def push() -> str:
    """返回**远端**的 commit sha —— 后续匹配 CI 运行必须用它。"""
    step("2/6  推送到 GitHub（走 REST API，不用 git push）")

    # 子进程也要按 UTF-8 输出，否则中文会被父进程按 UTF-8 解码成乱码
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    result = subprocess.run(
        [sys.executable, "tools/gh_api_push.py"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
    )
    lines = ((result.stdout or "") + (result.stderr or "")).strip().splitlines()

    if result.returncode != 0:
        for line in lines[-20:]:
            print("  " + line)
        raise SystemExit("推送失败，排查：gh auth status / 网络 / 杀软是否拦截")

    # 只摘关键行：逐文件上传的流水账有几十行，没必要都打出来
    keys = ("本地 HEAD", "提交信息", "远端", "tree:", "commit:", "REMOTE_SHA=", "推送完成")
    for line in lines:
        if line.startswith(keys):
            print("  " + line)

    remote_sha = next(
        (line.split("=", 1)[1].strip() for line in lines if line.startswith("REMOTE_SHA=")),
        None,
    )
    local_sha = run(["git", "rev-parse", "HEAD"]).stdout.strip()

    if not remote_sha:
        print("  （推送脚本没给出远端 sha，回退用本地 HEAD）")
        return local_sha

    if remote_sha != local_sha:
        # 两边都用本方式推送时，父提交不同，commit sha 必然不同。属正常。
        print("  提示：远端 commit 与本地不同（历史已分叉，属正常现象）")
        print("        后续按远端 sha 去匹配 CI 运行")
    return remote_sha


def wait_for_run(repo: str, sha: str, timeout_minutes: int) -> int:
    step("3/6  等待 GitHub Actions 编译")

    print("  目标提交: " + sha[:10])
    print("  轮询中（首次编译约 3~5 分钟）…")

    deadline = time.time() + timeout_minutes * 60
    run_id = None
    announced = False

    while time.time() < deadline:
        if run_id is None:
            runs = gh_json(
                "run", "list", "--repo", repo, "--commit", sha, "--limit", "1",
                "--json", "databaseId,status,conclusion,displayTitle",
                check=False,
            )
            if runs:
                run_id = runs[0]["databaseId"]
                print("  找到运行: id=" + str(run_id) + "  " + runs[0].get("displayTitle", ""))
            else:
                if not announced:
                    print("  等待运行出现…")
                    announced = True
                time.sleep(5)
                continue

        info = gh_json(
            "run", "view", str(run_id), "--repo", repo,
            "--json", "status,conclusion", check=False,
        )
        status = info.get("status") if isinstance(info, dict) else None
        conclusion = info.get("conclusion") if isinstance(info, dict) else None

        if status == "completed":
            if conclusion == "success":
                print("  编译成功 ✓")
                return run_id
            print("  编译失败 ✗  conclusion=" + str(conclusion))
            print()
            print("  ---- 失败步骤日志（尾部）----")
            logs = gh("run", "view", str(run_id), "--repo", repo,
                      "--log-failed", check=False).stdout or ""
            for line in logs.strip().splitlines()[-40:]:
                print("  " + line[:200])
            raise SystemExit(1)

        time.sleep(10)

    raise SystemExit("等待超时，去网页看：https://github.com/" + repo + "/actions")


def download(repo: str, run_id: int, out_dir: Path) -> Path:
    step("4/6  下载编译产物")

    if out_dir.exists():
        shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True, exist_ok=True)

    gh("run", "download", str(run_id), "--repo", repo,
       "-n", ARTIFACT_NAME, "-D", str(out_dir))

    candidates = list(out_dir.rglob("*.ipa"))
    if not candidates:
        raise SystemExit("下载完成但没找到 ipa，检查 artifact 名是否被改过")
    ipa = candidates[0]
    print("  " + str(ipa) + "  (" + str(round(ipa.stat().st_size / 1024 / 1024, 2)) + " MB)")
    return ipa


def verify(ipa: Path) -> bool:
    step("5/6  校验 ipa 内容")

    ok = True
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()

        plists = [n for n in names if n.endswith(".app/Info.plist")]
        if not plists:
            print("  ✗ 包内没有 .app/Info.plist，结构不对")
            return False
        info = plistlib.loads(z.read(plists[0]))
        print("  包结构: " + plists[0])

        def check(label, actual, expected=None, truthy=False):
            nonlocal ok
            if truthy:
                good = bool(actual)
            elif expected is not None:
                good = actual == expected
            else:
                good = actual is not None
            mark = "✓" if good else "✗"
            if not good:
                ok = False
            shown = actual if not isinstance(actual, (dict, list)) else str(actual)[:40]
            print("  " + mark + " " + label.ljust(26) + " = " + str(shown))

        check("显示名称", info.get("CFBundleDisplayName"), "黑色相机")
        check("最低系统版本", info.get("MinimumOSVersion"), "17.0")
        check("相机权限说明", info.get("NSCameraUsageDescription"), truthy=True)
        check("麦克风权限说明", info.get("NSMicrophoneUsageDescription"), truthy=True)
        check("相册权限说明", info.get("NSPhotoLibraryAddUsageDescription"), truthy=True)
        check("文件共享开关", info.get("UIFileSharingEnabled"), True)
        check("不应有后台模式", "UIBackgroundModes" not in info, True)

        icons = [n for n in names if "AppIcon" in n and n.endswith(".png")]
        check("图标资源数量", len(icons) > 0, True)

        exe = info.get("CFBundleExecutable")
        present = any(n.endswith(".app/" + str(exe)) for n in names)
        check("可执行文件在包内", present, True)

    return ok


def main() -> int:
    global GH

    parser = argparse.ArgumentParser(
        description="提交 → 推送 → 等编译 → 下载并校验 ipa",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("-m", "--message", help="提交信息；不给则不提交，只重跑流水线")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="GitHub 仓库 owner/repo")
    parser.add_argument("--branch", default=DEFAULT_BRANCH, help="分支名")
    parser.add_argument("--out", default=str(WORKSPACE / "ipa"), help="ipa 下载目录")
    parser.add_argument("--timeout", type=int, default=20, help="等待编译的分钟数")
    parser.add_argument("--no-download", action="store_true", help="只等编译，不下载")
    args = parser.parse_args()

    fix_console_encoding()
    GH = find_gh()

    print("仓库: " + args.repo + "   分支: " + args.branch)
    print("工作目录: " + str(REPO_ROOT))

    auth = gh("auth", "status", check=False)
    if auth.returncode != 0:
        raise SystemExit("gh 未登录。先执行：gh auth login（浏览器授权，无需 token）")

    commit_if_needed(args.message)
    sha = push()
    run_id = wait_for_run(args.repo, sha, args.timeout)

    if args.no_download:
        print("\n  已跳过下载。artifact 在：https://github.com/" + args.repo + "/actions/runs/" + str(run_id))
        return 0

    ipa = download(args.repo, run_id, Path(args.out))
    passed = verify(ipa)

    step("6/6  完成")
    print("  ipa : " + str(ipa))
    print("  大小: " + str(round(ipa.stat().st_size / 1024 / 1024, 2)) + " MB")
    print("  校验: " + ("全部通过" if passed else "有项目未通过，见上面 ✗ 行"))
    print()
    print("  下一步：Sideloadly 拖入该 ipa → 填 Apple ID → Start")
    print("  免费签名有效期 7 天，到期重跑一次即可")
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n已中断")
        sys.exit(130)

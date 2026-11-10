#!/usr/bin/env python3
"""
Fast download of GitHub Actions macOS artifact via aria2c,
graceful shutdown of running Zen app (preserving tabs & profile),
clean in-place upgrade, quarantine removal, ad-hoc signing, and relaunch.

Works with:
- Full action run URL: https://github.com/owner/repo/actions/runs/123456789
- Run ID directly: 123456789
- Latest run on current branch / repo
- Any repo (zen-browser/desktop, ShubhamJ010/desktop, etc.)
- Any artifact name (Zen-SJ-macOS-aarch64, zen-macos-aarch64, etc.)
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request


def run(cmd, check=True, capture_output=False, text=True):
    return subprocess.run(cmd, check=check, capture_output=capture_output, text=text)


def get_gh_token():
    res = run(["gh", "auth", "token"], capture_output=True)
    token = res.stdout.strip()
    if not token:
        sys.exit("[-] gh CLI is not authenticated. Run 'gh auth login'.")
    return token


def parse_run_or_url(input_str, default_repo):
    """
    Accepts:
    - https://github.com/ShubhamJ010/desktop/actions/runs/42798527985
    - https://github.com/zen-browser/desktop/actions/runs/42798527985/job/123...
    - 42798527985
    - None
    Returns (repo, run_id)
    """
    if not input_str:
        return default_repo, None

    url_match = re.search(r"github\.com/([^/]+/[^/]+)/actions/runs/(\d+)", input_str)
    if url_match:
        return url_match.group(1), url_match.group(2)

    if input_str.isdigit():
        return default_repo, input_str

    sys.exit(f"[-] Invalid run ID or URL: {input_str}")


def resolve_artifact(repo, run_id=None, branch=None, workflow=None, artifact_name_pattern=None):
    if not run_id:
        print(f"[*] Querying latest successful run in {repo}...")
        cmd = ["gh", "run", "list", "--repo", repo, "--status", "success", "--limit", "1", "--json", "databaseId,headBranch,workflowName"]
        if branch:
            cmd.extend(["--branch", branch])
        if workflow:
            cmd.extend(["--workflow", workflow])
        res = run(cmd, capture_output=True)
        runs = json.loads(res.stdout)
        if not runs:
            sys.exit(f"[-] No successful runs found in {repo}.")
        run_id = str(runs[0]["databaseId"])
        print(f"[+] Found latest run: {run_id} (Branch: {runs[0].get('headBranch')}, Workflow: {runs[0].get('workflowName')})")
    else:
        print(f"[*] Inspecting run {run_id} in {repo}...")

    res = run(["gh", "api", f"repos/{repo}/actions/runs/{run_id}/artifacts"], capture_output=True)
    data = json.loads(res.stdout)
    artifacts = data.get("artifacts", [])
    if not artifacts:
        sys.exit(f"[-] No artifacts found for run {run_id} in {repo}.")

    target = None
    if artifact_name_pattern:
        for a in artifacts:
            if artifact_name_pattern.lower() in a["name"].lower():
                target = a
                break
    if not target:
        # Default prioritize macOS aarch64 / arm64 / dmg artifacts
        for a in artifacts:
            name_lower = a["name"].lower()
            if "mac" in name_lower and ("aarch64" in name_lower or "arm64" in name_lower):
                target = a
                break
    if not target:
        target = artifacts[0]

    print(f"[+] Selected artifact: {target['name']} (ID: {target['id']}, Size: {target['size_in_bytes'] / (1024*1024):.1f} MB)")
    return target


def get_redirect_url(download_api_url, token):
    req = urllib.request.Request(
        download_api_url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
    )

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    opener = urllib.request.build_opener(NoRedirect)
    try:
        opener.open(req)
        sys.exit("[-] Expected redirect from GitHub API, but got 200.")
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 307, 308):
            return e.headers["Location"]
        sys.exit(f"[-] HTTP error getting artifact redirect: {e.code} {e.read().decode()}")


def download_with_aria2(url, out_dir, out_file):
    cmd = [
        "aria2c",
        "-x", "16",
        "-s", "16",
        "-k", "1M",
        "--auto-file-renaming=false",
        "--allow-overwrite=true",
        "-d", out_dir,
        "-o", out_file,
        url,
    ]
    print(f"[*] Downloading {out_file} via aria2c (16 parallel connections)...")
    run(cmd)
    print("[+] Download complete.")


def detect_installed_app(preferred_name=None):
    if preferred_name:
        path = f"/Applications/{preferred_name}.app" if not preferred_name.endswith(".app") else f"/Applications/{preferred_name}"
        if os.path.exists(path):
            return path

    candidates = [
        "/Applications/Zen SJ.app",
        "/Applications/Zen Browser.app",
        "/Applications/Zen.app",
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return "/Applications/Zen SJ.app"


def graceful_quit(app_name):
    # AppleScript sends kAEQuitApplication event - browser flushes session and tab state to disk
    print(f"[*] Gracefully closing '{app_name}' to save tabs and session...")
    run(["osascript", "-e", f'tell application "{app_name}" to quit'], check=False)
    for _ in range(15):
        res = run(["pgrep", "-f", f"{app_name}.app/Contents/MacOS"], check=False, capture_output=True)
        if res.returncode != 0:
            print("[+] Application quit cleanly.")
            return
        time.sleep(1)
    print("[!] Application did not quit in 15s; continuing...")


def install_from_dmg(dmg_path, target_app_path, app_name):
    mount_point = tempfile.mkdtemp(prefix="zen_mount_")
    print(f"[*] Attaching DMG to {mount_point}...")
    run(["hdiutil", "attach", dmg_path, "-mountpoint", mount_point, "-nobrowse", "-readonly"])

    try:
        source_app = None
        for item in os.listdir(mount_point):
            if item.endswith(".app"):
                source_app = os.path.join(mount_point, item)
                break

        if not source_app:
            sys.exit(f"[-] No .app bundle found inside DMG at {mount_point}")

        print(f"[+] Found app in DMG: {source_app}")
        graceful_quit(app_name)

        print(f"[*] Replacing {target_app_path}...")
        if os.path.exists(target_app_path):
            shutil.rmtree(target_app_path)
        shutil.copytree(source_app, target_app_path, symlinks=True)

        print("[*] Clearing quarantine attributes...")
        run(["xattr", "-cr", target_app_path], check=False)

        print("[*] Ad-hoc signing updated app bundle...")
        run(["codesign", "--force", "--deep", "-s", "-", target_app_path])

        print(f"[+] Successfully installed over {target_app_path} with zero data loss.")
    finally:
        print("[*] Detaching DMG...")
        run(["diskutil", "eject", mount_point], check=False)
        shutil.rmtree(mount_point, ignore_errors=True)


def install_from_app_folder(source_app, target_app_path, app_name):
    graceful_quit(app_name)
    print(f"[*] Replacing {target_app_path}...")
    if os.path.exists(target_app_path):
        shutil.rmtree(target_app_path)
    shutil.copytree(source_app, target_app_path, symlinks=True)

    print("[*] Clearing quarantine attributes...")
    run(["xattr", "-cr", target_app_path], check=False)

    print("[*] Ad-hoc signing updated app bundle...")
    run(["codesign", "--force", "--deep", "-s", "-", target_app_path])

    print(f"[+] Successfully installed over {target_app_path} with zero data loss.")


def main():
    parser = argparse.ArgumentParser(description="Fast Zen Browser CI artifact updater via aria2c (supports ANY run URL / ID)")
    parser.add_argument("run", nargs="?", default=None, help="GitHub Actions run URL (e.g. https://github.com/.../actions/runs/123) or run ID")
    parser.add_argument("--repo", default="ShubhamJ010/desktop", help="GitHub repo (owner/repo) if run argument is only an ID")
    parser.add_argument("--branch", default=None, help="Filter latest run by branch")
    parser.add_argument("--workflow", default=None, help="Filter latest run by workflow file")
    parser.add_argument("--name", default=None, help="Artifact name filter (substring match)")
    parser.add_argument("--app-path", default=None, help="Destination .app path (default: auto-detected)")
    parser.add_argument("--no-relaunch", action="store_true", help="Do not relaunch browser after install")
    args = parser.parse_args()

    repo, run_id = parse_run_or_url(args.run, args.repo)
    token = get_gh_token()
    artifact = resolve_artifact(repo, run_id, args.branch, args.workflow, args.name)
    download_url = artifact["archive_download_url"]
    redirect_url = get_redirect_url(download_url, token)

    target_app = args.app_path or detect_installed_app()
    app_name = os.path.splitext(os.path.basename(target_app))[0]

    with tempfile.TemporaryDirectory(prefix="zen_update_") as tmpdir:
        download_with_aria2(redirect_url, tmpdir, "artifact.zip")

        # Find any zip in tmpdir
        zip_path = None
        for f in os.listdir(tmpdir):
            if f.endswith(".zip"):
                zip_path = os.path.join(tmpdir, f)
                break

        if not zip_path:
            sys.exit("[-] Downloaded zip file not found in tmpdir.")

        print(f"[*] Extracting downloaded artifact ({os.path.basename(zip_path)})...")
        run(["unzip", "-q", "-o", zip_path, "-d", tmpdir])

        # Find DMG or .app inside artifact
        dmg_file = None
        app_file = None
        for root, dirs, files in os.walk(tmpdir):
            for d in dirs:
                if d.endswith(".app"):
                    app_file = os.path.join(root, d)
                    break
            for f in files:
                if f.endswith(".dmg"):
                    dmg_file = os.path.join(root, f)
                    break
            if dmg_file or app_file:
                break

        if dmg_file:
            install_from_dmg(dmg_file, target_app, app_name)
        elif app_file:
            install_from_app_folder(app_file, target_app, app_name)
        else:
            sys.exit(f"[-] No DMG or .app found in extracted artifact.")

        if not args.no_relaunch:
            print(f"[*] Relaunching {target_app}...")
            run(["open", "-a", target_app])
            print("[+] Complete! Session and tabs preserved.")


if __name__ == "__main__":
    main()

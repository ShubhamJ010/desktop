#!/usr/bin/env python3
"""
Fast download of GitHub Actions macOS artifact via aria2c,
graceful shutdown of running Zen app (preserving tabs & profile),
clean in-place upgrade, quarantine removal, ad-hoc signing, and relaunch.
"""

import argparse
import json
import os
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
    return res.stdout.strip()


def resolve_artifact(repo, run_id=None, artifact_name_pattern=None):
    if not run_id:
        print("[*] Fetching latest successful workflow run...")
        res = run(
            ["gh", "run", "list", "--repo", repo, "--status", "success", "--limit", "1", "--json", "databaseId"],
            capture_output=True,
        )
        runs = json.loads(res.stdout)
        if not runs:
            sys.exit("[-] No successful runs found.")
        run_id = str(runs[0]["databaseId"])
        print(f"[+] Using latest run: {run_id}")

    res = run(["gh", "api", f"repos/{repo}/actions/runs/{run_id}/artifacts"], capture_output=True)
    data = json.loads(res.stdout)
    artifacts = data.get("artifacts", [])
    if not artifacts:
        sys.exit(f"[-] No artifacts found for run {run_id}")

    target = None
    if artifact_name_pattern:
        for a in artifacts:
            if artifact_name_pattern.lower() in a["name"].lower():
                target = a
                break
    if not target:
        target = artifacts[0]

    print(f"[+] Selected artifact: {target['name']} (ID: {target['id']}, Size: {target['size_in_bytes']} bytes)")
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
    url_file = os.path.join(out_dir, "url.txt")
    with open(url_file, "w") as f:
        f.write(url)

    cmd = [
        "aria2c",
        "-x", "16",
        "-s", "16",
        "-k", "1M",
        "-i", url_file,
        "-d", out_dir,
        "-o", out_file,
    ]
    print(f"[*] Downloading {out_file} via aria2c (16 parallel connections)...")
    run(cmd)
    print("[+] Download complete.")


def detect_installed_app():
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
    # AppleScript sends kAEQuitApplication event - browser saves session state cleanly
    print(f"[*] Gracefully closing '{app_name}' to save tabs and session...")
    run(["osascript", "-e", f'tell application "{app_name}" to quit'], check=False)
    for _ in range(15):
        res = run(["pgrep", "-f", f"{app_name}.app/Contents/MacOS"], check=False, capture_output=True)
        if res.returncode != 0:
            print("[+] Application quit cleanly.")
            return
        time.sleep(1)
    print("[!] Application did not quit in 15s; continuing...")


def install_dmg(dmg_path, target_app_path, app_name):
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


def main():
    parser = argparse.ArgumentParser(description="Fast Zen Browser CI artifact updater via aria2c")
    parser.add_argument("--repo", default="ShubhamJ010/desktop", help="GitHub repo (owner/repo)")
    parser.add_argument("--run-id", default=None, help="GitHub Actions run ID (default: latest successful)")
    parser.add_argument("--name", default="Zen-SJ-macOS-aarch64", help="Artifact name filter")
    parser.add_argument("--app-path", default=None, help="Destination .app path")
    parser.add_argument("--no-relaunch", action="store_true", help="Do not relaunch browser after install")
    args = parser.parse_args()

    token = get_gh_token()
    artifact = resolve_artifact(args.repo, args.run_id, args.name)
    download_url = artifact["archive_download_url"]
    redirect_url = get_redirect_url(download_url, token)

    target_app = args.app_path or detect_installed_app()
    app_name = os.path.splitext(os.path.basename(target_app))[0]

    with tempfile.TemporaryDirectory(prefix="zen_update_") as tmpdir:
        zip_path = os.path.join(tmpdir, "artifact.zip")
        download_with_aria2(redirect_url, tmpdir, "artifact.zip")

        print("[*] Extracting DMG from downloaded artifact...")
        run(["unzip", "-q", "-o", zip_path, "-d", tmpdir])

        dmg_file = None
        for root, _, files in os.walk(tmpdir):
            for f in files:
                if f.endswith(".dmg"):
                    dmg_file = os.path.join(root, f)
                    break
            if dmg_file:
                break

        if not dmg_file:
            sys.exit(f"[-] No DMG file found in extracted artifact.")

        install_dmg(dmg_file, target_app, app_name)

        if not args.no_relaunch:
            print(f"[*] Relaunching {target_app}...")
            run(["open", "-a", target_app])
            print("[+] Done!")


if __name__ == "__main__":
    main()

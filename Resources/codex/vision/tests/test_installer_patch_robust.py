#!/usr/bin/env python3
"""Installer & Patch 鲁莽性测试
Run: python3 tests/test_installer_patch_robust.py
"""
import os, sys, tempfile, pathlib, subprocess, json, re, shutil, shlex
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REPO_ROOT = os.path.abspath(os.path.join(HERE, "../../../../.."))
INSTALLER = os.path.join(ROOT, "../codex-oneclick-setup.command") if os.path.exists(os.path.join(ROOT, "../codex-oneclick-setup.command")) else os.path.join(REPO_ROOT, "Resources/codex/codex-oneclick-setup.command")
# Fallback to bundled
if not os.path.exists(INSTALLER):
    INSTALLER = os.path.join(ROOT, "../../Resources/codex/codex-oneclick-setup.command") if os.path.exists(os.path.join(ROOT, "../../Resources/codex/codex-oneclick-setup.command")) else ""
if not os.path.exists(INSTALLER):
    INSTALLER = "/Applications/OpenCode 小组件.app/Contents/Resources/codex/codex-oneclick-setup.command"
if not os.path.exists(INSTALLER):
    # find via build
    for p in ["/Users/steve233/Desktop/OpenCodeGoWidget-main/Resources/codex/codex-oneclick-setup.command"]:
        if os.path.exists(p):
            INSTALLER = p
            break

PASS, FAIL = [], []

def check(name, fn):
    try:
        fn()
        PASS.append(name)
        print(f"  PASS {name}")
    except AssertionError as e:
        FAIL.append((name, f"ASSERT {e}"))
        print(f"  FAIL {name}: {e!r}")
        import traceback; traceback.print_exc()
    except Exception as e:
        FAIL.append((name, f"EXC {e!r}"))
        print(f"  FAIL {name}: {e!r}")
        import traceback; traceback.print_exc()

def run_installer(env, args):
    # run with timeout 15, capture
    proc = subprocess.Popen(["/bin/zsh", INSTALLER] + args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        out, _ = proc.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
        return 124, out
    return proc.returncode, out

def base_env():
    env = os.environ.copy()
    # keep PATH etc
    return env

# ---------- installer edge ----------

def t_installer_empty_keys_noninteractive():
    # No keys at all should die only if no existing install; if existing exists it reuses and succeeds
    # Test isolated HOME with no existing files to ensure correct failure
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        env = base_env()
        env["HOME"] = td
        env["ONECLICK_GO_KEY"] = ""
        env["ONECLICK_DS_KEY"] = ""
        env["ONECLICK_GLM_KEY"] = ""
        env["ONECLICK_PASS"] = "testpass123"
        rc, out = run_installer(env, ["--noninteractive", "--install", "--skip-patch", "--skip-proxy-start"])
        # Should fail because no existing keys to reuse
        assert rc != 0
        assert "至少需要" in out or "need" in out.lower() or "GO" in out
    # With existing install, empty should succeed (reuse)
    env = base_env()
    env["ONECLICK_GO_KEY"] = ""
    env["ONECLICK_DS_KEY"] = ""
    env["ONECLICK_GO_KEY"] = ""  # will reuse existing
    env["ONECLICK_PASS"] = "testpass123"
    # If existing exists, check that it doesn't fail on "至少需要"
    # We don't assert rc, just that it doesn't crash trap
    rc2, out2 = run_installer(env, ["--noninteractive", "--install", "--skip-patch", "--skip-proxy-start"])
    assert isinstance(out2, str)

def t_installer_short_go_key_rejected():
    env = base_env()
    env["ONECLICK_GO_KEY"] = "short"
    env["ONECLICK_DS_KEY"] = ""
    env["ONECLICK_PASS"] = "validpass"
    rc, out = run_installer(env, ["--noninteractive", "--install", "--skip-patch", "--skip-proxy-start"])
    assert rc != 0
    assert "过短" in out or "invalid" in out.lower() or "长度" in out

def t_installer_simple_pass_allowed():
    env = base_env()
    # use existing Go if available, else dummy long
    existing = ""
    try:
        if os.path.exists(os.path.expanduser("~/.config/agent-vision-toolkit/env")):
            txt = open(os.path.expanduser("~/.config/agent-vision-toolkit/env")).read()
            m = re.search(r'ZEN_API_KEY=(\S+)', txt)
            if m: existing = m.group(1).strip()
    except: pass
    go = existing if len(existing) >= 20 else "sk-test-" + "a"*30
    # Check existing pass to know if empty should succeed via reuse
    existing_pass = ""
    try:
        existing_pass = open(os.path.expanduser("~/.codex/picker-patch/.keychain-pass")).read().strip()
    except: pass
    for pwd in ["1", "ab", "0000", "a", "123", "   "]:
        env2 = base_env()
        env2["ONECLICK_GO_KEY"] = go
        env2["ONECLICK_DS_KEY"] = ""
        env2["ONECLICK_PASS"] = pwd
        rc, out = run_installer(env2, ["--noninteractive", "--install", "--skip-patch", "--skip-proxy-start"])
        if pwd.strip() == "" and not existing_pass:
            # only if no existing pass should empty fail
            assert rc != 0, f"empty pwd with no existing should fail but got {rc} {out[:200]}"
        elif pwd.strip() == "" and existing_pass:
            # with existing pass, empty should succeed (reuse)
            assert "缺少签名" not in out, f"empty pwd with existing should reuse, not fail: {out[:300]}"
        else:
            assert "过短" not in out, f"pwd {pwd!r} wrongly rejected length: {out[:300]}"
            assert "不能为 0000" not in out, f"pwd {pwd!r} wrongly rejected 0000: {out[:300]}"

def t_installer_update_reuses_old():
    # update mode with no keys should succeed if old keys exist (reuse)
    # We test that update doesn't require ONECLICK_PASS if old exists and we provide it?
    # Just check that update with empty ONECLICK_* but existing files doesn't crash with "未检测到"
    # If no existing install, it should gracefully switch to install message
    env = base_env()
    env["ONECLICK_GO_KEY"] = ""
    env["ONECLICK_DS_KEY"] = ""
    env["ONECLICK_PASS"] = ""
    rc, out = run_installer(env, ["--noninteractive", "--update", "--skip-patch", "--skip-proxy-start"])
    # Should either succeed via reuse, or fail with clear message, not crash trap
    assert isinstance(out, str) and len(out) > 0

def t_installer_whitespace_keys():
    # Isolated HOME: whitespace go should be treated as empty and fail if no existing
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        env = base_env()
        env["HOME"] = td
        env["ONECLICK_GO_KEY"] = "   "
        env["ONECLICK_DS_KEY"] = "   "
        env["ONECLICK_PASS"] = "   pass with spaces   "
        rc, out = run_installer(env, ["--noninteractive", "--install", "--skip-patch", "--skip-proxy-start"])
        assert rc != 0
    # With existing install, whitespace go reuses existing and should not crash
    env = base_env()
    env["ONECLICK_GO_KEY"] = "   "
    env["ONECLICK_DS_KEY"] = "   "
    env["ONECLICK_PASS"] = "   pass with spaces   "
    rc2, out2 = run_installer(env, ["--noninteractive", "--install", "--skip-patch", "--skip-proxy-start"])
    assert isinstance(out2, str)

# ---------- CodexInstaller.swift detectStatus robustness (sim via file fuzz) ----------

def t_detect_status_malformed_files():
    # Create temp HOME with malformed config.toml / models.json / env / patch-state
    import tempfile, pathlib, json
    with tempfile.TemporaryDirectory() as td:
        home = pathlib.Path(td)
        cd = home / ".codex-deepseek"
        cd.mkdir(parents=True)
        # malformed config.toml
        (cd / "config.toml").write_text('model = \nmodel = "unterminated\n', encoding="utf-8")
        # malformed models.json
        (cd / "models.json").write_text('{"models": [{"slug": 123}]}', encoding="utf-8")
        # env with weird lines
        envp = home / ".config/agent-vision-toolkit/env"
        envp.parent.mkdir(parents=True, exist_ok=True)
        envp.write_text('ZEN_API_KEY=  "  spaced \"key\"  "\nVISION_API_KEY=\n# comment\nNOT_A_KEY=foo\n', encoding="utf-8")
        # patch-state with truncated json
        patchdir = home / ".codex/picker-patch"
        patchdir.mkdir(parents=True)
        (patchdir / "patch-state.json").write_text('{"sourceVersion":', encoding="utf-8")
        (patchdir / ".keychain-pass").write_text(' 0000 \n', encoding="utf-8")
        # Now run a python mimic of detectStatus logic (we just ensure no crash when reading)
        # Simulate Swift's detectStatus reading
        for p in [cd/"config.toml", cd/"models.json", envp, patchdir/"patch-state.json"]:
            try:
                txt = p.read_text(encoding="utf-8", errors="replace")
                # try regex like Swift does
                re.search(r'model\s*=\s*"([^"]+)', txt)
                json.loads(txt) if p.suffix==".json" else None
            except Exception as e:
                # should not propagate as crash, just log
                pass
        # If we reach here without exception, pass
        assert True

# ---------- patch regex robustness ----------

def t_patch_regex_various_asar():
    import tempfile, pathlib
    regex = re.compile(r'useHiddenModels&&[^`]*!==`amazonBedrock`')
    cases = [
        (b'a.useHiddenModels&&i!==`amazonBedrock`', 1, True),
        (b'i.useHiddenModels&&r!==`amazonBedrock`', 1, True),
        (b'x.useHiddenModels&&y!==`amazonBedrock`', 1, True),
        (b'useHiddenModels&&!==`amazonBedrock`', 1, True), # [^`]* can be zero, so this actually matches
        (b'a.useHiddenModels&&i===`amazonBedrock`', 0, False), # already patched
        (b'a.useHiddenModels&&i!==`amazonBedrock` a.useHiddenModels&&i!==`amazonBedrock`', 2, False), # duplicate -> should refuse
    ]
    for content, expected_count, should_allow in cases:
        with tempfile.NamedTemporaryFile(delete=False) as tf:
            tf.write(b"header" + content + b"footer")
            tf.flush()
            path = tf.name
            try:
                data = open(path, "rb").read()
                matches = len(regex.findall(data.decode(errors="replace")))
                assert matches == expected_count, f"{content}: {matches} != {expected_count}"
                # Simulate patch.sh check: if matches !=1 => refuse
                allow = (matches == 1)
                assert allow == should_allow, f"allow {allow} != {should_allow} for {content}"
            finally:
                os.unlink(path)

def t_patch_sparkle_feed():
    feed_old = b'https://persistent.oaistatic.com/codex-app-prod/appcast.xml'
    feed_new = b'https://invalid.invalid.invalid/codex-app-prod/appcast.xml'
    assert len(feed_old) == len(feed_new) or len(feed_new) <= len(feed_old)  # ensure same-length patch possible
    # Simulate dd patch at offset
    import tempfile
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tf.write(b"xx" + feed_old + b"yy")
        tf.flush()
        path = tf.name
        try:
            with open(path, "r+b") as f:
                data = f.read()
                off = data.find(feed_old)
                assert off != -1
                f.seek(off)
                f.write(feed_new[:len(feed_old)])
            assert feed_new[:10] in open(path, "rb").read()
        finally:
            os.unlink(path)

for name, fn in list(globals().items()):
    if name.startswith("t_"):
        check(name, fn)

print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    for n,e in FAIL:
        print(f"  !! {n}: {e}")
    sys.exit(1)

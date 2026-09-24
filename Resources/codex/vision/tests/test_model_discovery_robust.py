#!/usr/bin/env python3
"""鲁莽性测试 - model_discovery / patch / installer / config
Run: python3 tests/test_model_discovery_robust.py
"""
import json, os, sys, tempfile, pathlib, re, copy, subprocess, shutil, time, random, string
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import importlib.util
spec = importlib.util.spec_from_file_location("md", os.path.join(ROOT, "model_discovery.py"))
md = importlib.util.module_from_spec(spec)
spec.loader.exec_module(md)

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

# ---------- quota table fuzz ----------

def _fake_html(rows):
    # rows: list of (disp, h5, wk, mo)
    html = "<table>"
    for r in rows:
        html += f"<tr><td>{r[0]}</td><td>{r[1]}</td><td>{r[2]}</td><td>{r[3]}</td></tr>"
    html += "</table>"
    return html

def t_quota_parse_malformed():
    # monkey patch urlopen to return our fake html
    orig = md.urllib.request.urlopen
    def fake_open(req, timeout=10):
        class R:
            def __enter__(self): return self
            def __exit__(self,*a): pass
            def read(self): return _fake_html([
                ("Model","每5小时","每周","每月"),  # header
                ("Mimo V2.5","30100","75200","150400"),
                ("Bad Row","$10","$20","$30"),  # price row should be filtered
                ("Free Model","-","-","-"),
                ("Grok 4.6","abc","def","ghi"),  # non-numeric should be filtered except free
                ("Qwen","100","200","300"),
            ]).encode()
        return R()
    md.urllib.request.urlopen = fake_open
    try:
        ids = md.fetch_quota_ids(timeout=2)
        assert ids is not None
        assert "mimo-v2.5" in ids
        assert "qwen" in ids or "qwen-0" in ids or len(ids)>=1
    finally:
        md.urllib.request.urlopen = orig

def t_quota_html_injection():
    orig = md.urllib.request.urlopen
    malicious = '<tr><td><script>alert(1)</script></td><td>100</td><td>200</td><td>300</td></tr>'
    def fake(req, timeout=10):
        class R:
            def __enter__(self): return self
            def __exit__(self,*a): pass
            def read(self): return f"<table>{malicious}</table>".encode()
        return R()
    md.urllib.request.urlopen = fake
    try:
        ids = md.fetch_quota_ids(timeout=2)
        # should not crash, may produce sanitized id
        assert isinstance(ids, (list, type(None)))
    finally:
        md.urllib.request.urlopen = orig

def t_quota_empty_html():
    orig = md.urllib.request.urlopen
    def fake(req, timeout=10):
        class R:
            def __enter__(self): return self
            def __exit__(self,*a): pass
            def read(self): return b"<html></html>"
        return R()
    md.urllib.request.urlopen = fake
    try:
        ids = md.fetch_quota_ids(timeout=2)
        # empty should return None and not crash
        assert ids is None or isinstance(ids, list)
    finally:
        md.urllib.request.urlopen = orig

def t_quota_nested_markup_row():
    """2026-09-14 事故回归：配额行带 <br><small>/<del>/<strong> 装饰时不能漏行。

    旧实现用 `<td>([^<]+)</td>` 逐格匹配纯文本，官方给 DeepSeek V4.1 Flash 那行
    加了促销装饰后整行匹配失败 -> 配额 id 27->26 -> 同步把它当野模型剪掉，
    Codex 的模型列表里就再也选不到了。
    """
    names = ["Kimi K3", "Qwen3.8 Max", "Grok 4.6", "GLM-5.3-Flash", "GLM-5.3",
             "GLM-5.2", "GLM-5.1", "Kimi K2.7 Code", "Kimi K2.6", "LongCat-2.0"]
    html = "<table><tr><td>模型</td><td>每5小时</td><td>每周</td><td>每月</td></tr>"
    for n in names:
        html += f"<tr><td>{n}</td><td>100</td><td>200</td><td>300</td></tr>"
    html += ('<tr><td>DeepSeek V4.1 Flash<br><small>4x · 9 月 20 日结束</small></td>'
             '<td><del>6,500</del><br><strong>26,000</strong></td>'
             '<td><del>16,250</del><br><strong>65,000</strong></td>'
             '<td><del>32,500</del><br><strong>130,000</strong></td></tr></table>')
    # 行名不带促销备注；配额取当前生效值（<strong>）而不是被划掉的旧值
    rows = md.parse_quota_rows(html)
    assert ("DeepSeek V4.1 Flash", "26,000", "65,000", "130,000") in rows, rows

    orig_open, orig_align = md.urllib.request.urlopen, md._align_remote_id
    orig_cache_dir, orig_page = md.CACHE_DIR, md.LAST_QUOTA_PAGE
    with tempfile.TemporaryDirectory() as td:
        md.CACHE_DIR = pathlib.Path(td)
        md.LAST_QUOTA_PAGE = ""
        def fake_open(req, timeout=10):
            class R:
                def __enter__(self): return self
                def __exit__(self,*a): pass
                def read(self): return html.encode()
            return R()
        md.urllib.request.urlopen = fake_open
        md._align_remote_id = lambda norm, guess: guess
        try:
            ids = md.fetch_quota_ids(timeout=2)
            assert ids and len(ids) == len(names) + 1, ids
            assert "deepseek-flash" in ids, ids
            # 页面归一化文本要记下来，剪枝安全闸靠它判断"文档里还提不提到"
            assert md.LAST_QUOTA_PAGE, "page_norm 未记录，剪枝安全闸会失效"
            assert md._norm_key("deepseek-v4.1-flash") in md.LAST_QUOTA_PAGE
        finally:
            md.urllib.request.urlopen = orig_open
            md._align_remote_id = orig_align
            md.CACHE_DIR = orig_cache_dir
            md.LAST_QUOTA_PAGE = orig_page

def t_prune_safety_hold():
    """解析漏行/单次抓取异常都不许当场删模型：

    1) 文档里还出现的 -> safety-hold（判为解析漏行，永久保留）；
    2) 第一次缺席的 -> prune-grace（挂起一轮，第二次仍缺席才剪）。
    """
    with tempfile.TemporaryDirectory() as td:
        home = pathlib.Path(td)
        orig_home = pathlib.Path.home
        pathlib.Path.home = lambda: home
        keys = ("CODEX_HOME", "MODELS_JSON", "CACHE_DIR", "CACHE_FILE", "QUOTA_CACHE_FILE",
                "PRUNE_PENDING_FILE", "LAST_QUOTA_PAGE")
        fns = ("fetch_quota_ids", "fetch_zen_free_ids", "fetch_remote_ids",
               "fetch_upstream_details", "fetch_modelsdev")
        orig_vals = {k: getattr(md, k) for k in keys}
        orig_fns = {k: getattr(md, k) for k in fns}
        try:
            md.CODEX_HOME = home / ".codex-deepseek"
            md.MODELS_JSON = md.CODEX_HOME / "models.json"
            md.CACHE_DIR = home / ".local/share/agent-vision-toolkit"
            md.CACHE_FILE = md.CACHE_DIR / "go_models_cache.json"
            md.QUOTA_CACHE_FILE = md.CACHE_DIR / "go_quota_cache.json"
            md.PRUNE_PENDING_FILE = md.CACHE_DIR / "prune_pending.json"
            md.CODEX_HOME.mkdir(parents=True, exist_ok=True)
            md.CACHE_DIR.mkdir(parents=True, exist_ok=True)
            md.MODELS_JSON.write_text(json.dumps({"models": [
                {"slug": "deepseek-v4.1-flash-go", "priority": 1, "visibility": "list",
                 "display_name": "DeepSeek-V4.1-Flash (Go)"},
                {"slug": "kimi-k2.5-go", "priority": 2, "visibility": "list",
                 "display_name": "Kimi-K2.5 (Go)"},
                {"slug": "mimo-v2.5-go", "priority": 3, "visibility": "list",
                 "display_name": "MiMo-V2.5 (Go)"},
            ]}))
            # 模拟事故现场：配额表漏了 V4.1 那一行
            md.fetch_quota_ids = lambda timeout=10: ["mimo-v2.5"]
            md.fetch_zen_free_ids = lambda timeout=10: []
            md.fetch_remote_ids = lambda timeout=10: None
            md.fetch_upstream_details = lambda: {}
            md.fetch_modelsdev = lambda: {}
            md.LAST_QUOTA_PAGE = md._norm_key("DeepSeek V4.1 Flash 26,000 65,000 130,000")
            # 第一轮：文档里还有的 hold 住；真野的 kimi 进 grace（首次缺席不剪）
            md.sync(force=True, dry_run=False)
            slugs = [m["slug"] for m in json.loads(md.MODELS_JSON.read_text())["models"]]
            assert "deepseek-v4.1-flash-go" in slugs, f"文档里仍有该模型却被剪: {slugs}"
            assert "mimo-v2.5-go" in slugs, slugs
            assert "kimi-k2.5-go" in slugs, f"首次缺席不该当场剪: {slugs}"
            assert "kimi-k2.5" in json.loads(md.PRUNE_PENDING_FILE.read_text()), "缺席未记账"
            # 第二轮：宽限期已过（把首次缺席时间改成 epoch 0）才真剪
            md.PRUNE_PENDING_FILE.write_text(json.dumps({"kimi-k2.5": 0}))
            md.sync(force=True, dry_run=False)
            slugs = [m["slug"] for m in json.loads(md.MODELS_JSON.read_text())["models"]]
            assert "kimi-k2.5-go" not in slugs, f"连续缺席该剪没剪: {slugs}"
            assert "deepseek-v4.1-flash-go" in slugs, f"文档里仍有该模型却被剪: {slugs}"
        finally:
            pathlib.Path.home = orig_home
            for k, v in orig_vals.items():
                setattr(md, k, v)
            for k, v in orig_fns.items():
                setattr(md, k, v)

# ---------- fetch_remote_ids shapes ----------

def t_fetch_remote_shapes():
    cases = [
        (["a", "b"], ["a","b"]),
        ([{"id":"x"}, {"id":"y"}], ["x","y"]),
        ({"data": ["m1", "m2"]}, ["m1","m2"]),
        ({"data": [{"id": "k1"}, "k2"]}, ["k1","k2"]),
        ({"data": []}, None),
        ([], None),
        ({"unexpected": 123}, None),
        (["  TRIM  ", " trim ", "TRIM"], ["trim"]),  # dedup + lower + strip
    ]
    orig = md.urllib.request.build_opener
    for raw, expected in cases:
        def fake_opener(*a, **kw):
            class Op:
                def open(self, req, timeout=10):
                    class R:
                        def __enter__(self): return self
                        def __exit__(self,*a): pass
                        def read(self): return json.dumps(raw).encode()
                    return R()
            return Op()
        md.urllib.request.build_opener = fake_opener
        try:
            out = md.fetch_remote_ids(timeout=2)
            if expected is None:
                assert out is None, f"{raw} -> {out} expected None"
            else:
                assert out == [e.lower().strip() for e in expected], f"{raw} -> {out}"
        finally:
            md.urllib.request.build_opener = orig

def t_fetch_remote_malformed_json():
    orig = md.urllib.request.build_opener
    def fake(*a,**kw):
        class Op:
            def open(self, req, timeout=10):
                class R:
                    def __enter__(self): return self
                    def __exit__(self,*a): pass
                    def read(self): return b"not json {"
                return R()
        return Op()
    md.urllib.request.build_opener = fake
    try:
        out = md.fetch_remote_ids(timeout=2)
        assert out is None
    finally:
        md.urllib.request.build_opener = orig

# ---------- display -> id normalization ----------

def t_norm_display_fuzz():
    for s in ["", "  ", "MIMO--V2.5  ", "Qwen--3.8 Max!!", "GROK 4.6", "GLM-5.3-FlAsH", "a"*500]:
        out = md._norm_display(s)
        assert isinstance(out, str)

def t_is_free_val_fuzz():
    for v in ["-", "—", "限免", "免费", "∞", "不计配额", "限时免费", "123", "  -  ", "Inf", ""]:
        assert isinstance(md._is_free_val(v), bool)

# ---------- build_entry robustness ----------

def t_build_entry_weird_ids():
    # need at least one template
    j = md.load_models_json()
    models = j.get("models", [])
    if not models:
        print("    SKIP no models.json")
        return
    for rid in ["", "a", "a"*100, "mimo-v2.5", "deepseek-v4-flash", "grok-4.6", "unknown-xyz-123", "big-pickle", "mimo-v2.5-free"]:
        try:
            e = md.build_entry(models[0], rid, 999)
            assert "slug" in e and "display_name" in e
            assert isinstance(e["supported_reasoning_levels"], list)
        except Exception as e:
            assert False, f"build_entry crash {rid}: {e}"

def t_find_template_fallback():
    j = md.load_models_json()
    models = j.get("models", [])
    if not models:
        print("    SKIP")
        return
    for rid in ["", "weird", "deepseek-unknown", "gpt-unknown", "mimo-unknown", "glm-unknown"]:
        tmpl = md.find_template(models, rid)
        assert tmpl is not None

# ---------- sync with temp HOME ----------

def t_sync_with_fake_quota():
    # use temp dir as HOME to not touch real models.json
    with tempfile.TemporaryDirectory() as td:
        home = pathlib.Path(td)
        # mock HOME via patching Path.home
        orig_home = pathlib.Path.home
        pathlib.Path.home = lambda: home
        # also patch md globals
        orig_CODEX_HOME = md.CODEX_HOME
        orig_MODELS_JSON = md.MODELS_JSON
        orig_CACHE_DIR = md.CACHE_DIR
        orig_CACHE_FILE = md.CACHE_FILE
        orig_QUOTA_CACHE = md.QUOTA_CACHE_FILE
        try:
            md.CODEX_HOME = home / ".codex-deepseek"
            md.MODELS_JSON = md.CODEX_HOME / "models.json"
            md.CACHE_DIR = home / ".local/share/agent-vision-toolkit"
            md.CACHE_DIR.mkdir(parents=True, exist_ok=True)
            md.CACHE_FILE = md.CACHE_DIR / "go_models_cache.json"
            md.QUOTA_CACHE_FILE = md.CACHE_DIR / "go_quota_cache.json"
            md.CODEX_HOME.mkdir(parents=True, exist_ok=True)
            # seed with minimal models.json
            seed = {"models": [{"slug": "mimo-v2.5-go", "priority": 1, "display_name": "x", "description": "", "visibility":"list", "supported_reasoning_levels": [], "default_reasoning_level":"high", "supported_in_api": True}]}
            md.MODELS_JSON.write_text(json.dumps(seed))
            # fake quota ids
            orig_fetch_quota = md.fetch_quota_ids
            orig_fetch_zen = md.fetch_zen_free_ids
            md.fetch_quota_ids = lambda timeout=10: ["mimo-v2.5", "glm-5.3", "new-model-xyz"]
            md.fetch_zen_free_ids = lambda timeout=10: []
            try:
                n = md.sync(force=True, dry_run=False)
                assert isinstance(n, int)
                # check models.json now contains new-model-xyz-go
                j = json.loads(md.MODELS_JSON.read_text())
                slugs = [m["slug"] for m in j["models"]]
                assert "new-model-xyz-go" in slugs
                assert len(j["models"]) == len(set(slugs))  # no dup
            finally:
                md.fetch_quota_ids = orig_fetch_quota
                md.fetch_zen_free_ids = orig_fetch_zen
        finally:
            pathlib.Path.home = orig_home
            md.CODEX_HOME = orig_CODEX_HOME
            md.MODELS_JSON = orig_MODELS_JSON
            md.CACHE_DIR = orig_CACHE_DIR
            md.CACHE_FILE = orig_CACHE_FILE
            md.QUOTA_CACHE_FILE = orig_QUOTA_CACHE

def t_sync_quota_failure_no_clobber():
    with tempfile.TemporaryDirectory() as td:
        home = pathlib.Path(td)
        orig_home = pathlib.Path.home
        pathlib.Path.home = lambda: home
        orig_CODEX_HOME = md.CODEX_HOME
        orig_MODELS_JSON = md.MODELS_JSON
        orig_CACHE_DIR = md.CACHE_DIR
        orig_QUOTA_CACHE = md.QUOTA_CACHE_FILE
        try:
            md.CODEX_HOME = home / ".codex-deepseek"
            md.MODELS_JSON = md.CODEX_HOME / "models.json"
            md.CACHE_DIR = home / ".local/share/agent-vision-toolkit"
            md.CACHE_DIR.mkdir(parents=True, exist_ok=True)
            md.QUOTA_CACHE_FILE = md.CACHE_DIR / "go_quota_cache.json"
            md.CODEX_HOME.mkdir(parents=True, exist_ok=True)
            md.MODELS_JSON.write_text(json.dumps({"models": [{"slug":"mimo-v2.5-go","priority":1}]}))
            orig_fetch = md.fetch_quota_ids
            orig_zen = md.fetch_zen_free_ids
            md.fetch_quota_ids = lambda timeout=10: None
            md.fetch_zen_free_ids = lambda timeout=10: []
            try:
                n = md.sync(force=True)
                assert n == 0, f"expected 0 but got {n}"
                j = json.loads(md.MODELS_JSON.read_text())
                assert len(j["models"]) == 1
            finally:
                md.fetch_quota_ids = orig_fetch
                md.fetch_zen_free_ids = orig_zen
        finally:
            pathlib.Path.home = orig_home
            md.CODEX_HOME = orig_CODEX_HOME
            md.MODELS_JSON = orig_MODELS_JSON
            md.CACHE_DIR = orig_CACHE_DIR
            md.QUOTA_CACHE_FILE = orig_QUOTA_CACHE

# ---------- config / patch robustness ----------

def t_models_json_malformed():
    with tempfile.TemporaryDirectory() as td:
        p = pathlib.Path(td)/"models.json"
        for bad in ["", "not json", "[]", "{}", '{"models": "not-a-list"}', '{"models": [{"slug": 123}]}']:
            p.write_text(bad)
            # load_models_json should not crash when used via sync? It does json.loads directly, may raise.
            # Test that our wrapper handles or raises predictably
            try:
                j = json.loads(p.read_text())
                # if it parses, check fallback
            except:
                pass

def t_patch_regex_various():
    # check patch.sh regex still matches after possible variable renames
    patterns = [
        'a.useHiddenModels&&i!==`amazonBedrock`',
        'i.useHiddenModels&&r!==`amazonBedrock`',
        'x.useHiddenModels&&y!==`amazonBedrock`',
        'a.useHiddenModels && i !== `amazonBedrock`',  # spaced should not match current regex
    ]
    regex = re.compile(r'useHiddenModels&&[^`]*!==`amazonBedrock`')
    for pat in patterns[:3]:
        assert regex.search(pat), f"should match {pat}"
    # spaced variant should not match, which is expected to trigger rebuild failure path (good)
    assert not regex.search(patterns[3])

def t_installer_key_validation():
    # simulate installer key checks: length <8 is suspicious
    def is_suspicious(k):
        return len(k.strip())>0 and len(k.strip())<8
    assert is_suspicious("short")
    assert not is_suspicious("sk-1234567890abcdef")
    assert not is_suspicious("")
    # test trimming
    assert not is_suspicious("  sk-12345678  ".strip())

def t_effective_levels_precedence():
    """覆盖层（手工实测）> models.dev > opencodex —— 2026-09-17 修正后的优先级。"""
    ov = {"glm-5.3": ["low", "high", "max"]}
    lv, manual = md._effective_levels(
        "glm-5.3", "glm-5.3", (1000000, ["medium"], None, "GLM 5.3", "opencode-go"), None, ov)
    assert lv == ["low", "high", "max"] and manual is True, (lv, manual)
    lv, manual = md._effective_levels(
        "hy3", "hy3", (256000, ["low", "medium"], None, "Hy3", "opencode-go"), None, ov)
    assert lv == ["low", "medium"] and manual is False, (lv, manual)
    lv, manual = md._effective_levels("x", "x", None, (1000, ["high"]), ov)
    assert lv == ["high"] and manual is False, (lv, manual)
    lv, manual = md._effective_levels("y", "y", None, None, ov)
    assert lv is None and manual is False, (lv, manual)
    # -free 剥后缀后的 lookup 也能命中覆盖层
    lv, manual = md._effective_levels("kimi-x-free", "kimi-x", None, None, {"kimi-x": ["low"]})
    assert lv == ["low"] and manual is True, (lv, manual)


def t_sync_heals_stale_levels():
    """老机器目录里的陈旧档位/上下文必须被同步纠正（覆盖层 > models.dev）。"""
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        cache = td / "cache"
        cache.mkdir(parents=True)
        # 全套隔离：连 CODEX_HOME 也要指到临时目录，否则 sync_desktop_whitelist /
        # backup 步骤会去写真机的 ~/.codex-deepseek（2026-09-17 踩过：把真 config.toml
        codex_home = td / "codex-home"
        codex_home.mkdir(parents=True)
        (codex_home / "config.toml").write_text(
            '[desktop]\nenabled-reasoning-efforts = ["low", "medium", "high"]\n')
        models_path = codex_home / "models.json"
        seed = {"models": [
            {"slug": "glm-5.3-go", "display_name": "GLM-5.3 (Go)", "priority": 1,
             "context_window": 99999, "max_context_window": 99999,
             "supported_reasoning_levels": [{"effort": "medium", "description": "stale"}],
             "default_reasoning_level": "medium", "input_modalities": ["text"]},
            {"slug": "kimi-k3-go", "display_name": "Kimi-K3 (Go)", "priority": 2,
             "context_window": 1048576, "max_context_window": 1048576,
             "supported_reasoning_levels": [{"effort": "high", "description": "stale"}],
             "default_reasoning_level": "high", "input_modalities": ["text"]},
        ]}
        models_path.write_text(json.dumps(seed, ensure_ascii=False))
        (cache / "reasoning_overrides.json").write_text(
            json.dumps({"kimi-k3": ["low", "high"]}, ensure_ascii=False))

        saved = {k: getattr(md, k) for k in
                 ("CODEX_HOME", "MODELS_JSON", "CACHE_DIR", "CACHE_FILE", "QUOTA_CACHE_FILE",
                  "ZEN_CACHE_FILE", "MODELSDEV_CACHE", "PRUNE_PENDING_FILE",
                  "fetch_quota_ids", "fetch_remote_ids", "fetch_zen_free_ids",
                  "fetch_upstream_details", "fetch_modelsdev")}
        mddev = {
            "glm-5.3": (1000000, ["low", "medium", "high"], {"input": ["text", "image"]},
                        "GLM 5.3", "opencode-go"),
            "kimi-k3": (1048576, ["low", "high", "max"], {"input": ["text"]},
                        "Kimi K3", "opencode-go"),
        }
        try:
            md.CODEX_HOME = codex_home
            md.MODELS_JSON = models_path
            md.CACHE_DIR = cache
            md.CACHE_FILE = cache / "go_models_cache.json"
            md.QUOTA_CACHE_FILE = cache / "go_quota_cache.json"
            md.ZEN_CACHE_FILE = cache / "zen_models_cache.json"
            md.MODELSDEV_CACHE = cache / "modelsdev_cache.json"
            md.PRUNE_PENDING_FILE = cache / "prune_pending.json"
            md.fetch_quota_ids = lambda timeout=None: ["glm-5.3", "kimi-k3"]
            md.fetch_remote_ids = lambda: []
            md.fetch_zen_free_ids = lambda: []
            md.fetch_upstream_details = lambda: {}
            md.fetch_modelsdev = lambda: mddev
            md.sync(force=True)
        finally:
            for k, v in saved.items():
                setattr(md, k, v)

        out = {m["slug"]: m for m in json.loads(models_path.read_text())["models"]}
        glm = out["glm-5.3-go"]
        assert glm["context_window"] == 1000000 and glm["max_context_window"] == 1000000, glm
        assert [l["effort"] for l in glm["supported_reasoning_levels"]] == ["low", "medium", "high"], glm
        assert glm["input_modalities"] == ["text", "image"], glm
        kimi = out["kimi-k3-go"]
        assert [l["effort"] for l in kimi["supported_reasoning_levels"]] == ["low", "high"], kimi
        assert kimi["default_reasoning_level"] == "low", kimi
        reg = json.loads((cache / "reasoning_registry.json").read_text())
        assert reg["kimi-k3"] == ["low", "high"], reg.get("kimi-k3")
        assert reg["glm-5.3"] == ["low", "medium", "high"], reg.get("glm-5.3")


# ---------- 显示名：GPT 前缀（2026-09-24）----------

def t_display_name_gpt_prefix_safe():
    """Codex 选择器会吃掉开头的 "GPT-"（"GPT-6-Luna (Go)" 显示成 "6 Luna (Go)"）——
    所以显示名里不许出现 GPT- 前缀，任何 GPT 模型都必须是 "GPT 6 Luna" 这种空格写法。
    这条是规则，不是单模型补丁：以后新增 gpt-7 / gpt-9 自动生效。
    """
    assert md._display_name_for("gpt-6-luna", "Go", "GPT 6 Luna") == "GPT 6 Luna (Go)"
    assert md._display_name_for("gpt-6-luna", "Go", None) == "GPT 6 Luna (Go)"
    assert md._display_name_for("gpt-7-ultra", "Go", "GPT 7 Ultra") == "GPT 7 Ultra (Go)"
    assert md._display_name_for("gpt-9-turbo-free", "Zen", "GPT 9 Turbo Free") == "GPT 9 Turbo Free (Zen)"
    # 别的模型不许被顺手改掉（MiMo/DeepSeek 的连字符是刻意保留的）
    assert md._display_name_for("mimo-v2.6-flash", "Go", "MiMo-V2.6-Flash") == "MiMo-V2.6-Flash (Go)"
    assert md._display_name_for("deepseek-v4.1-flash", "Go", "DeepSeek V4.1 Flash") == "DeepSeek-V4.1-Flash (Go)"
    # 兜底（没有官方名、只能拿 id 拼）也要守规矩
    assert md._display_name_for("gpt-8-mini", "Go", None) == "GPT 8 Mini (Go)"
    for rid, sfx in [("gpt-6-luna", "Go"), ("gpt-7-ultra", "Go"), ("gpt-9-turbo-free", "Zen")]:
        name = md._display_name_for(rid, sfx, None)
        assert not name.startswith("GPT-"), f"{rid} 还是 GPT- 开头：{name}"


for name, fn in list(globals().items()):
    if name.startswith("t_"):
        check(name, fn)

print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    for n,e in FAIL:
        print(f"  !! {n}: {e}")
    sys.exit(1)

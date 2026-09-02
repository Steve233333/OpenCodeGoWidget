#!/usr/bin/env python3
"""上下文与推理档位核对 - 只读审计，可选补 registry"""
import argparse, json, pathlib, sys
HOME = pathlib.Path.home()
MODELS_JSON = HOME / ".codex-deepseek/models.json"
REG_PATH = HOME / ".local/share/agent-vision-toolkit/reasoning_registry.json"

def load():
    mj = json.loads(MODELS_JSON.read_text())
    reg = json.loads(REG_PATH.read_text()) if REG_PATH.exists() else {}
    return mj, reg

def _bare_for_reg(slug):
    if slug.endswith("-zen"):
        bare = slug[:-4]
    elif slug.endswith("-go"):
        bare = slug[:-3]
    else:
        bare = slug
    # for Zen Free, strip -free for lookup
    if bare.endswith("-free"):
        lookup = bare[:-5]
        return lookup
    return bare

def report():
    mj, reg = load()
    rows = []
    for m in mj["models"]:
        slug = m["slug"]
        bare = _bare_for_reg(slug)
        # also try full remote id with -free
        full_bare = slug[:-4] if slug.endswith("-zen") else (slug[:-3] if slug.endswith("-go") else slug)
        ctx = m.get("context_window")
        levels = [e["effort"] for e in m.get("supported_reasoning_levels",[])]
        exp = reg.get(full_bare) or reg.get(bare)
        if exp is None:
            status = "缺表(通用high)"
        elif levels == exp:
            status = "一致"
        else:
            status = f"偏差(期望{exp})"
        rows.append((slug, ctx, levels, exp, status))
    # print table
    print(f"{'slug':35} {'ctx':7} {'当前档位':25} {'期望':25} 判定")
    print("-"*120)
    for slug, ctx, lv, exp, st in rows:
        print(f"{slug:35} {str(ctx):7} {str(lv):25} {str(exp):25} {st}")
    # summary
    ok = sum(1 for r in rows if r[4]=="一致")
    miss = sum(1 for r in rows if "缺表" in r[4])
    dev = len(rows)-ok-miss
    print(f"\n总计 {len(rows)}  一致 {ok}  缺表 {miss}  偏差 {dev}")
    if miss:
        print("\n建议补 registry:")
        for slug, ctx, lv, exp, st in rows:
            if "缺表" in st and "通用" in st:
                bare = _bare_for_reg(slug)
                print(f'  "{bare}": ["high"]  # 当前 {lv} 通用')

def fix(dry=True):
    mj, reg = load()
    to_add = {}
    for m in mj["models"]:
        slug=m["slug"]
        bare=_bare_for_reg(slug)
        full_bare = slug[:-4] if slug.endswith("-zen") else (slug[:-3] if slug.endswith("-go") else slug)
        if bare not in reg and full_bare not in reg:
            # only for Go/Zen models
            if slug.endswith("-go") or slug.endswith("-zen"):
                to_add[bare]=[e["effort"] for e in m.get("supported_reasoning_levels",[])] or ["high"]
    if not to_add:
        print("无缺表项需补")
        return
    print("将新增 registry 条目:")
    for k,v in to_add.items():
        print(f'  "{k}": {v}')
    if dry:
        print("(dry-run 未写入)")
        return
    reg.update(to_add)
    REG_PATH.write_text(json.dumps(reg, ensure_ascii=False, indent=2)+"\n")
    print(f"已写入 {REG_PATH}")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="只读报表")
    ap.add_argument("--fix", action="store_true", help="补缺表项")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.fix:
        fix(dry=args.dry_run)
    else:
        report()

#!/bin/bash
# 说大白话：把"每天的钱"从两个来源各算一遍，对不上就报警。
#   来源 A：request-logs（/logs 页面用的接口，我们现在的明细来源）逐条相加
#   来源 B：usage/cost-by-day?bucket=hour 小时桶按北京时间归日
# 为什么要它：2026-09-26 上游撤掉 usage/rows 之后，"来源不一致"害我们画过一次 305%。
# 用法：scripts/probe-usage-vs-logs.sh [天数，默认 3]
set -uo pipefail

DAYS="${1:-3}"
python3 - "$DAYS" <<'PY'
import datetime, json, os, plistlib, sys, time
import urllib.error, urllib.parse, urllib.request

days = int(sys.argv[1])
bj = datetime.timezone(datetime.timedelta(hours=8))

plist = os.path.expanduser("~/Library/Group Containers/2DC432GLL2.com.steve233.opencodego/"
                           "Library/Preferences/2DC432GLL2.com.steve233.opencodego.plist")
prefs = plistlib.load(open(plist, "rb"))
ws = prefs.get("workspaceID") or ""
auth = prefs.get("authCookie") or ""
sess = prefs.get("consoleSession") or ""
if not ws or not sess:
    print("❌ 拿不到控制台凭据（先在 App 里登录/刷新一次）")
    sys.exit(1)

headers = {
    "Cookie": "; ".join(x for x in ["oc_locale=zh", f"auth={auth}", f"__Host-console_session={sess}"]
                        if not x.endswith("=")),
    "x-org-id": ws,
    "Accept": "application/json",
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
    "Referer": f"https://opencode.ai/console/{ws}/logs",
}


def get_json(url, attempts=3):
    """大窗口 export 偶尔会读超时 → 重试几次（app 侧同样会重试一轮）"""
    last = None
    for i in range(attempts):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as r:
                return json.loads(r.read().decode())
        except Exception as e:      # noqa: BLE001
            last = e
            time.sleep(2 * (i + 1))
    raise SystemExit(f"❌ 连续 {attempts} 次取数失败：{url[:90]}…（{last}）")


def ms(day, hour=0):
    return int(datetime.datetime(day.year, day.month, day.day, hour, tzinfo=bj).timestamp() * 1000)


def logs_of_day(day):
    """一天的全部日志（export 单次 ≤1000 条，超了按中点二分）"""
    out, queue = [], [(ms(day), ms(day + datetime.timedelta(days=1)))]
    while queue:
        since, until = queue.pop()
        q = urllib.parse.urlencode({"format": "json", "since": since, "until": until})
        obj = get_json(f"https://opencode.ai/console/api/request-logs/export?{q}")
        content = json.loads(obj["content"]) if isinstance(obj["content"], str) else obj["content"]
        items = content.get("items") or []
        if obj.get("truncated") and until - since > 120_000:
            mid = (since + until) // 2
            queue += [(since, mid), (mid, until)]
        else:
            out += items
    return out


def hourly_by_beijing_day():
    obj = get_json(f"https://opencode.ai/console/api/usage/cost-by-day?range=30d&bucket=hour")
    per_day = {}
    for item in obj if isinstance(obj, list) else obj.get("items", []):
        ts = datetime.datetime.fromisoformat(item["date"].replace("Z", "+00:00"))
        key = ts.astimezone(bj).strftime("%Y-%m-%d")
        per_day[key] = per_day.get(key, 0) + int(item["totalCostMicroCents"]) / 1e8
    return per_day


buckets = hourly_by_beijing_day()
today = datetime.datetime.now(bj).date()
print(f"=== 最近 {days} 天：request-logs 逐条 vs cost-by-day 小时桶 ===")
bad = 0
for i in range(days):
    day = today - datetime.timedelta(days=i)
    items = logs_of_day(day)
    from_logs = sum((it.get("cost") or 0) for it in items)
    from_hours = buckets.get(day.strftime("%Y-%m-%d"), 0)
    diff = abs(from_logs - from_hours)
    ok = diff <= max(0.02, from_hours * 0.005)   # 0.5% 或 2 分钱以内
    by_key, by_model = {}, {}
    for it in items:
        c = it.get("cost") or 0
        by_key[it.get("serviceAPIKeyID") or "-"] = by_key.get(it.get("serviceAPIKeyID") or "-", 0) + c
        by_model[it.get("model") or "-"] = by_model.get(it.get("model") or "-", 0) + c
    print(f"\n{day}  {'✅' if ok else '❌'}  日志 {len(items)} 条 · ${from_logs:.6f} · 小时桶 ${from_hours:.6f} · 差 ${diff:.6f}")
    for k, v in sorted(by_key.items(), key=lambda kv: -kv[1]):
        if v > 0: print(f"      key   {k:34} ${v:.6f}")
    for k, v in sorted(by_model.items(), key=lambda kv: -kv[1])[:4]:
        if v > 0: print(f"      model {k:34} ${v:.6f}")
    if not ok:
        bad += 1

print()
if bad:
    print(f"❌ {bad} 天对不上 —— 数据源口径可能又变了")
    sys.exit(1)
print("✅ 全部对齐（两个来源独立算出同一笔钱）")
PY

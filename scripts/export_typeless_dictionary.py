#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Export Typeless personal dictionary to a single-column CSV via CDP.

Reusable pipeline (verified 2026-11-03 / 2026-11-04):
  1. Typeless must run with --remote-debugging-port (see Export-TypelessDictionary.ps1)
  2. Read the hub.html page target over CDP
  3. Ask the app for a fresh list request (tab switch) to learn total_count
  4. Scroll with REAL wheel events (Input.dispatchMouseEvent) and read the
     visible card texts from the DOM at every position
  5. Verify unique count == total_count, then write UTF-8 BOM CSV (no header)

Preconditions that must be checked before blaming the method:
  - The Typeless window must be VISIBLE. When hidden, CDP input silently
    times out and the list never re-renders.
  - If the list was already fully loaded, the app stops issuing
    /user/dictionary/list requests, so network capture returns nothing.
    In that case DOM reading is the correct source.
"""

import argparse
import asyncio
import base64
import csv
import datetime
import hashlib
import json
import os
import shutil
import sys
import urllib.request

import websockets

HUB = "hub.html"
LIST_PATH = "/user/dictionary/list"

JS_STATE = """(() => {
  const el = [...document.querySelectorAll('*')].find(e => {
    const s = getComputedStyle(e);
    return (s.overflowY==='auto'||s.overflowY==='scroll') && e.scrollHeight > e.clientHeight + 20;
  });
  if (!el) return null;
  const box = el.getBoundingClientRect();
  const texts = [...el.querySelectorAll('p.MuiTypography-root.content')]
      .filter(p => {
        const r = p.getBoundingClientRect();
        const cy = r.top + r.height / 2;
        return cy >= box.top && cy <= box.bottom && p.textContent.trim().length > 0;
      })
      .map(p => p.textContent.trim());
  return {st: Math.round(el.scrollTop), sh: el.scrollHeight, ch: Math.round(el.clientHeight),
          x: box.x + box.width / 2, y: box.y + box.height / 2, texts};
})()"""

JS_TOP = """(() => {
  const el = [...document.querySelectorAll('*')].find(e => {
    const s = getComputedStyle(e);
    return (s.overflowY==='auto'||s.overflowY==='scroll') && e.scrollHeight > e.clientHeight + 20;
  });
  if (el) el.scrollTop = 0;
  return true;
})()"""

CLICK_TAB = """(() => {
  const t = [...document.querySelectorAll('p,div,span,button')]
     .reverse().find(n => n.textContent.trim() === '%s' && n.offsetParent !== null);
  if (!t) return 'not-found';
  (t.closest('button') || t).click();
  return 'clicked';
})()"""

UI_LABELS = {
    "Free", "Pro Trial", "升級", "首頁", "歷史紀錄", "字典",
    "所有", "自動新增", "手動新增", "新增單字", "獲取無限字數", "每週限制已達",
    "在試用結束前升級到", "Typeless Pro", "專業版試用",
}


def log(*a):
    print(*a, flush=True)


def ws_url(port):
    targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5))
    for t in targets:
        if t.get("type") == "page" and HUB in t.get("url", ""):
            return t["webSocketDebuggerUrl"], t.get("title")
    raise SystemExit("找不到 Typeless hub.html 分頁；請確認已用 --remote-debugging-port 啟動")


class CDP:
    def __init__(self, ws):
        self.ws = ws
        self.seq = 0
        self.pending = {}
        self.handlers = []

    async def call(self, method, params=None, timeout=25):
        self.seq += 1
        mid = self.seq
        await self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        while mid not in self.pending:
            msg = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=timeout))
            if "id" in msg:
                self.pending[msg["id"]] = msg
            else:
                for h in self.handlers:
                    await h(msg)
        return self.pending.pop(mid)

    async def evaluate(self, expr, timeout=30):
        r = await self.call("Runtime.evaluate", {"expression": expr, "awaitPromise": True,
                                                 "returnByValue": True, "timeout": timeout * 1000},
                            timeout=timeout + 10)
        res = r.get("result", {})
        if "exceptionDetails" in res:
            log("JS error:", json.dumps(res["exceptionDetails"], ensure_ascii=False)[:300])
            return None
        return res.get("result", {}).get("value")


async def capture(port):
    url, title = ws_url(port)
    log(f"target: {title} -> {url.rsplit('/', 1)[-1]}")
    async with websockets.connect(url, max_size=200 * 1024 * 1024, ping_interval=None) as ws:
        cdp = CDP(ws)
        total = [None]
        reqs = {}

        async def on_event(msg):
            m = msg.get("method")
            p = msg.get("params", {})
            if m == "Network.responseReceived":
                u = p["response"]["url"]
                if LIST_PATH in u:
                    reqs[p["requestId"]] = u
            elif m == "Network.loadingFinished":
                rid = p["requestId"]
                if rid in reqs:
                    reqs.pop(rid)
                    try:
                        r = await cdp.call("Network.getResponseBody", {"requestId": rid}, timeout=15)
                        body = r["result"]["body"]
                        if r["result"].get("base64Encoded"):
                            body = base64.b64decode(body).decode("utf-8")
                        d = json.loads(body)
                        n = d.get("data", {}).get("total_count")
                        if n:
                            total[0] = n
                            log(f"total_count = {n}")
                    except Exception as e:  # noqa: BLE001
                        log("payload skipped:", type(e).__name__)

        cdp.handlers.append(on_event)
        await cdp.call("Network.enable", timeout=10)
        await cdp.call("Page.bringToFront", timeout=10)   # 前提：讓視窗可見，否則 Input 會靜默 timeout

        # 逼 App 重新請求清單，取得 total_count
        for tab in ("自動新增", "所有"):
            log(f"click tab: {tab} -> {await cdp.evaluate(CLICK_TAB % tab)}")
            await asyncio.sleep(1.8)

        await cdp.evaluate(JS_TOP)
        await asyncio.sleep(0.8)

        state = await cdp.evaluate(JS_STATE)
        if not state:
            raise SystemExit("找不到字典清單容器（請確認目前頁面是「字典」）")

        cx, cy = state["x"], state["y"]
        log(f"start scrollTop={state['st']} scrollHeight={state['sh']} viewport={state['ch']}")

        # 前提檢查：視窗若不可見，CDP 的 Input 會「無聲」卡住而不是報錯。
        # 先送一次滾輪並確認 scrollTop 真的改變，否則直接失敗，不要盲目重試。
        async def wheel(dy=300, timeout=8):
            await cdp.call("Input.dispatchMouseEvent",
                           {"type": "mouseWheel", "x": cx, "y": cy,
                            "deltaX": 0, "deltaY": dy, "pointerType": "mouse"}, timeout=timeout)

        if state["sh"] - state["ch"] > 100:
            try:
                await wheel(300)
                await asyncio.sleep(0.5)
                probe = await cdp.evaluate(JS_STATE)
            except Exception as exc:  # noqa: BLE001
                raise SystemExit(
                    "PRECONDITION_FAILED: 滾輪事件無回應。Typeless 視窗可能被隱藏或最小化。\n"
                    "請先讓 Typeless 主視窗顯示在最上層後再執行（腳本會嘗試自動喚起，但若失敗請手動點一下視窗）。"
                    f"\n原始錯誤：{type(exc).__name__}"
                )
            if probe and probe["st"] == state["st"]:
                raise SystemExit(
                    "PRECONDITION_FAILED: 視窗存在但清單沒有捲動（CDP 輸入被忽略）。\n"
                    "請確認視窗可見、未被其他視窗完全遮蓋，或先以滑鼠實際捲動一次再重跑。"
                )
            await cdp.evaluate(JS_TOP)
            await asyncio.sleep(0.6)
            log("precondition ok: wheel scroll verified")

        order, seen = [], set()

        def add(texts):
            for t in texts:
                if t and t not in seen:
                    seen.add(t)
                    order.append(t)

        add(state["texts"])
        last = state["st"]
        stall = 0
        for i in range(500):
            try:
                await wheel(300)
            except Exception as exc:  # noqa: BLE001
                stall += 1
                log(f"  wheel timeout ({type(exc).__name__}) x{stall}")
                if stall >= 5:
                    raise SystemExit("PRECONDITION_LOST: 滾輪再次無回應，視窗可能又被遮蓋或最小化")
                await asyncio.sleep(0.5)
                continue
            await asyncio.sleep(0.35)
            v = await cdp.evaluate(JS_STATE)
            if not v:
                break
            add(v["texts"])
            if v["st"] == last:
                stall += 1
                if stall >= 4:
                    log(f"reached bottom at {v['st']} / {v['sh'] - v['ch']}")
                    break
            else:
                stall = 0
                last = v["st"]
            if i % 25 == 0:
                log(f"  step {i:3d} top={v['st']:6d} unique={len(order)}")

        return order, total[0]


def clean(words):
    out, seen = [], set()
    for w in words:
        w = w.strip()
        if not w or w in UI_LABELS:
            continue
        if len(w) > 60 or any(ch in w for ch in "。！？"):
            continue
        if w not in seen:
            seen.add(w)
            out.append(w)
    return out


def write_csv(words, outdir, archive):
    stamp = datetime.date.today().strftime("%Y%m%d")
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, f"Typeless_字典_詞彙_{stamp}.csv")
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        wr = csv.writer(f)
        for w in words:
            wr.writerow([w])
    archive_path = os.path.join(archive, os.path.basename(path)) if archive else None
    if archive and os.path.isdir(archive):
        try:
            shutil.copy2(path, archive_path)
        except PermissionError:
            # 目標檔常被 Excel 開著；不要讓整個匯出失敗
            alt = archive_path.replace(".csv", "_new.csv")
            shutil.copy2(path, alt)
            archive_path = alt
            log(f"WARN 目標檔被占用（可能 Excel 開著），已改存：{alt}")
    h = hashlib.sha256(open(path, "rb").read()).hexdigest()
    return path, archive_path, h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9333)
    ap.add_argument("--outdir", default=os.path.join(os.environ["USERPROFILE"], "Desktop", "Typeless字典匯出"))
    ap.add_argument("--archive", default="", help="可選：額外複製一份的資料夾；留空則只輸出到 --outdir")
    ap.add_argument("--allow-mismatch", action="store_true")
    args = ap.parse_args()

    order, total = asyncio.run(capture(args.port))
    words = clean(order)
    log(f"collected unique = {len(words)} | total_count = {total}")

    ok = total is None or len(words) == total
    path, archive_path, h = write_csv(words, args.outdir, args.archive)
    log(f"FILE   : {path}")
    if archive_path:
        log(f"ARCHIVE: {archive_path}")
    log(f"ROWS   : {len(words)}")
    log(f"SHA256 : {h}")
    if not ok:
        log("MISMATCH: 筆數與 App 總數不同，請重跑或檢查視窗是否可見")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

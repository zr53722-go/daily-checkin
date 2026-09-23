#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
每日积分自动领取 —— GitHub Actions 版（云端定时执行）

支持平台：
  - WorkBuddy  凭证：环境变量 WB_TOKEN（accessToken 明文）
  - Trae       凭证：环境变量 TRAE_TOKEN / TRAE_DEVICE_ID

设计要点（与本地 C# 版 DailyCheckin 完全对齐）：
  1. WorkBuddy 端点对合法请求返回 HTTP 400 + 业务响应体，业务体里的 code 才是权威结果，
     绝不能因 HTTP 状态码丢弃响应；code == 10001 表示"今日已签到"，属幂等成功。
  2. Trae 先查 status，若已签到则直接结束；否则调 claim 领取。
  3. 任一平台失败不影响其它平台；全部成功退出码 0，否则 1（便于 Actions 判成败）。
  4. 令牌过期时给出明确提示，而不是静默失败。

环境变量：
  WB_TOKEN           WorkBuddy accessToken（必填，除非只想跑 Trae）
  WB_DOMAIN          WorkBuddy 接口域名，默认 www.codebuddy.cn
  WB_ENDPOINT        签到路径，默认 /v2/billing/meter/daily-checkin
  TRAE_TOKEN         Trae Cloud-IDE-JWT（必填，除非只想跑 WorkBuddy）
  TRAE_DEVICE_ID     Trae x-device-id
  TRAE_HOST          Trae 接口域名，默认 https://api.trae.cn
  TRAE_REQ_SOURCE    1=IDE，2=Solo/Lite，默认 2
  ONLY               仅跑指定平台：wb / trae（不设则全跑）
"""

import json
import os
import sys
import time
from datetime import datetime, timezone

try:
    import requests
except ImportError:
    print("[FATAL] 缺少依赖 requests，请先 pip install requests", flush=True)
    sys.exit(1)

TIMEOUT = 30


def log(level, msg):
    """统一日志格式，便于在 Actions 页面阅读。"""
    print("[{}] [{}] {}".format(
        datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"), level, msg), flush=True)


# ----------------------------------------------------------------------------
# WorkBuddy
# ----------------------------------------------------------------------------

def checkin_workbuddy(token, domain, endpoint):
    """
    返回 True 表示"今天这个平台已经不用再跑了"（含新领成功与今日已签到）。
    """
    if not token:
        log("ERROR", "[WorkBuddy] 未提供 WB_TOKEN，跳过。")
        return False

    url = "https://{}{}".format(domain.strip().rstrip("/"), endpoint)
    headers = {
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    }
    log("INFO", "[WorkBuddy] POST {}".format(url))

    try:
        resp = requests.post(url, headers=headers, json={}, timeout=TIMEOUT)
    except Exception as e:
        log("ERROR", "[WorkBuddy] 请求异常: {}".format(e))
        return False

    # 关键：HTTP 400 也可能带有效业务体，必须解析
    if resp.status_code >= 400:
        log("WARN", "[WorkBuddy] HTTP {}（服务器返回了响应体，继续解析）".format(resp.status_code))

    text = resp.text or ""
    if not text.strip():
        log("ERROR", "[WorkBuddy] 空响应体（HTTP {}）。".format(resp.status_code))
        return False

    try:
        body = json.loads(text)
    except Exception:
        log("ERROR", "[WorkBuddy] 响应非 JSON: {}".format(text[:200]))
        return False

    code = body.get("code", -1)
    msg = body.get("msg", "")
    log("INFO", "[WorkBuddy] 返回 code={}, msg={}".format(code, msg))

    if code == 0:
        log("INFO", "[WorkBuddy] 签到成功（本次新增积分）。")
        return True
    if code == 10001:
        log("INFO", "[WorkBuddy] 今日已签到（幂等成功，说明端点可达、令牌有效）。")
        return True

    # 常见令牌失效特征
    if code in (401, 403, 10002, 10003) or "token" in str(msg).lower() or "登录" in str(msg):
        log("ERROR", "[WorkBuddy] 令牌可能已失效（code={}, msg={}），请更新 WB_TOKEN。".format(code, msg))
        return False

    log("WARN", "[WorkBuddy] 非预期 code={}, msg={}".format(code, msg))
    return False


# ----------------------------------------------------------------------------
# Trae
# ----------------------------------------------------------------------------

def checkin_trae(token, device_id, host, req_source):
    """
    先查状态，未签到则领取。返回 True 表示今天已了结。
    """
    if not token:
        log("ERROR", "[Trae] 未提供 TRAE_TOKEN，跳过。")
        return False

    host = host.strip().rstrip("/")
    headers = {
        "Authorization": "Cloud-IDE-JWT " + token,
        "x-device-id": device_id or "",
        "Content-Type": "application/json",
        "User-Agent": "TraeCheckin/2.0",
    }
    payload = {"req_source": req_source}

    def post(path):
        url = host + path
        try:
            r = requests.post(url, headers=headers, json=payload, timeout=TIMEOUT)
            if r.status_code >= 400:
                log("WARN", "[Trae] HTTP {}（{}）：{}".format(r.status_code, path, (r.text or "")[:200]))
            return json.loads(r.text) if (r.text or "").strip() else None
        except Exception as e:
            log("ERROR", "[Trae] 请求异常 {}: {}".format(path, e))
            return None

    status = post("/trae/api/v2/ug/checkin_credits/status")
    if status is None:
        log("ERROR", "[Trae] 查询签到状态失败。")
        return False

    code = status.get("code", 0)
    if code != 0:
        log("ERROR", "[Trae] 查询状态业务失败: {}".format(json.dumps(status, ensure_ascii=False)))
        # 令牌失效特征
        msg = str(status.get("message", "")) + str(status.get("msg", ""))
        if code in (401, 403) or "token" in msg.lower() or "auth" in msg.lower():
            log("ERROR", "[Trae] 令牌可能已失效，请更新 TRAE_TOKEN。")
        return False

    enable = status.get("enable", True)
    checked_in = status.get("checked_in", False)
    did_checked_in = status.get("did_checked_in", False)

    if not enable:
        log("WARN", "[Trae] 当前账号未开启签到活动（enable=false），跳过。")
        return True

    if checked_in or did_checked_in:
        log("INFO", "[Trae] 今日已签到，无需重复领取。")
        _log_credits(status)
        return True

    claim = post("/trae/api/v2/ug/checkin_credits/claim")
    if claim is None:
        log("ERROR", "[Trae] 领取失败（无响应体）。")
        return False

    claim_code = claim.get("code", -1)
    if claim_code != 0:
        log("ERROR", "[Trae] 领取失败: {}".format(json.dumps(claim, ensure_ascii=False)))
        return False

    log("INFO", "[Trae] 签到领取成功。")
    after = post("/trae/api/v2/ug/checkin_credits/status")
    if after and after.get("code", 0) == 0:
        log("INFO", "[Trae] 今日已签到: checked_in={}".format(after.get("checked_in")))
        _log_credits(after)
    return True


def _log_credits(status):
    credits = status.get("credits")
    extra = status.get("extra_credits")
    if credits is not None or extra is not None:
        log("INFO", "[Trae] 当前积分: credits={}, extra_credits={}".format(credits, extra))


# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

def main():
    log("INFO", "========== 每日积分自动领取（GitHub Actions 云端版） ==========")

    only = os.environ.get("ONLY", "").strip().lower()
    results = {}

    if only != "trae":
        log("INFO", "---------- 平台: WorkBuddy ----------")
        try:
            results["WorkBuddy"] = checkin_workbuddy(
                token=os.environ.get("WB_TOKEN", "").strip(),
                domain=os.environ.get("WB_DOMAIN", "www.codebuddy.cn"),
                endpoint=os.environ.get("WB_ENDPOINT", "/v2/billing/meter/daily-checkin"),
            )
        except Exception as e:
            log("ERROR", "[WorkBuddy] 执行异常: {}".format(e))
            results["WorkBuddy"] = False

    if only != "wb":
        log("INFO", "---------- 平台: Trae ----------")
        try:
            results["Trae"] = checkin_trae(
                token=os.environ.get("TRAE_TOKEN", "").strip(),
                device_id=os.environ.get("TRAE_DEVICE_ID", "").strip(),
                host=os.environ.get("TRAE_HOST", "https://api.trae.cn"),
                req_source=int(os.environ.get("TRAE_REQ_SOURCE", "2")),
            )
        except Exception as e:
            log("ERROR", "[Trae] 执行异常: {}".format(e))
            results["Trae"] = False

    log("INFO", "---------- 汇总 ----------")
    for name, ok in results.items():
        log("INFO", "  {}: {}".format(name, "成功" if ok else "失败"))

    all_ok = all(results.values()) if results else False
    log("INFO", "========== {} ==========".format("全部成功" if all_ok else "存在失败"))
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()

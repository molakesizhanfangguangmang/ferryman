#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ferryman —— 把「任意服务的 webhook」翻译成「目标服务能吃的请求」。

为什么要这么一层（踩过的坑，别删）：
  bili-sync 之类的服务发 webhook 时，只是把模板渲染出的字符串原样当 body POST，
  Content-Type 写死 application/json，模板引擎里没有 JSON 转义手段。它的通知正文
  往往带真换行 —— 塞进手写 JSON 模板就是非法 JSON，接收方直接 422。
  本服务收下任意 body（合法 JSON 也好、带真换行的裸文本也好），抽出一条纯文本，
  用 json.dumps 正确转义后，按目标类型拼成合法请求发出去。

它不认识「业务」，只认识「文本」。配了 DROP_KEYWORDS 时多一条判断：正文里含这些词的整条丢掉、不转发（默认关）。目标可以是另一个中转、一个 agent 接口、
一个现成的 IM 机器人 —— 见 README 的「目标类型」。

配置全部走环境变量（同目录 relay.env，由 install.sh 生成）。
不同目标类型要配什么，见 README。

依赖：纯标准库，python:3.12-alpine 即可。
"""

import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = "webhook-relay"
VERSION = "1.0.1"

TARGET_TYPE = (os.environ.get("TARGET_TYPE") or "generic").strip().lower()
LISTEN_PORT = os.environ.get("LISTEN_PORT", "8311")
MAX_TEXT_LEN = int(os.environ.get("MAX_TEXT_LEN", "1500"))
TEXT_PREFIX = os.environ.get("TEXT_PREFIX", "")
# 正文里含这些词的整条丢掉、不转发（逗号分隔；留空=不过滤）
DROP_KEYWORDS = [w.strip() for w in os.environ.get("DROP_KEYWORDS", "").split(",") if w.strip()]
HTTP_TIMEOUT = float(os.environ.get("HTTP_TIMEOUT", "20"))

# 目标类型 —— generic / qwenpaw / wecom / dingtalk / feishu
TARGET_URL = os.environ.get("TARGET_URL", "")
TARGET_BODY = os.environ.get("TARGET_BODY", "")
TARGET_HEADERS = os.environ.get("TARGET_HEADERS", "")
TARGET_METHOD = (os.environ.get("TARGET_METHOD") or "POST").upper()

QWENPAW_URL = os.environ.get("QWENPAW_URL", "http://127.0.0.1:8088/api/messages/send")
AGENT_ID = os.environ.get("AGENT_ID", "")
CHANNEL = os.environ.get("CHANNEL", "")
TARGET_USER = os.environ.get("TARGET_USER", "")
TARGET_SESSION = os.environ.get("TARGET_SESSION", "")

WECOM_URL = os.environ.get("WECOM_URL", "")
WECOM_KEY = os.environ.get("WECOM_KEY", "")
DINGTALK_URL = os.environ.get("DINGTALK_URL", "")
DINGTALK_TOKEN = os.environ.get("DINGTALK_TOKEN", "")
DINGTALK_SECRET = os.environ.get("DINGTALK_SECRET", "")
FEISHU_URL = os.environ.get("FEISHU_URL", "")
FEISHU_TOKEN = os.environ.get("FEISHU_TOKEN", "")

TEXT_KEYS = ("text", "message", "content", "msg", "desp", "body")


# ---------------------------------------------------------------------------
# 收：从任意 body 里抽出纯文本
# ---------------------------------------------------------------------------


def strip_html(text):
    """粗剥 HTML 标签（有些服务发的是富文本）。"""
    out = []
    depth = 0
    for ch in text:
        if ch == "<":
            depth += 1
        elif ch == ">" and depth:
            depth -= 1
        elif depth == 0:
            out.append(ch)
    return "".join(out)


def repair_json(text):
    """把「JSON 壳里塞了真换行」这种常见坏格式修一下。

    bili-sync 的默认模板 `{"text": "{{{message}}}"}` 会把多行正文原样塞进去，
    换行没转义 -> 非法 JSON。这里把裸换行转义后重试一次，能救回大部分情况。
    """
    if not text.lstrip().startswith(("{", "[")):
        return None
    candidate = text.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n")
    if candidate == text:
        return None
    try:
        return json.loads(candidate)
    except Exception:
        return None


def extract_text(raw):
    """抽不出一条像样的文本就返回空串（调用方会回 400）。"""
    text = raw.decode("utf-8", "replace").strip()
    if not text:
        return ""
    try:
        obj = json.loads(text)
    except Exception:
        obj = repair_json(text)
        if obj is None:
            # 真不是 JSON —— 当纯文本用（HTML 就粗剥一下标签）
            return strip_html(text) if text.lstrip().startswith("<") else text
    if isinstance(obj, str):
        return obj
    if isinstance(obj, dict):
        # 常见的几种壳：{"text": ...} / {"msgtype":"text","text":{"content": ...}}
        for key in TEXT_KEYS:
            value = obj.get(key)
            if isinstance(value, str) and value.strip():
                return value
            if isinstance(value, dict):
                for inner in TEXT_KEYS:
                    deep = value.get(inner)
                    if isinstance(deep, str) and deep.strip():
                        return deep
        return json.dumps(obj, ensure_ascii=False)
    if isinstance(obj, list):
        # 有些服务发一串字符串，按行拼起来更可读
        if obj and all(isinstance(item, str) for item in obj):
            return "\n".join(obj)
        return json.dumps(obj, ensure_ascii=False)
    return json.dumps(obj, ensure_ascii=False)


def drop_hit(text):
    """命中丢弃词就返回那个词，否则空串。按抽出来的正文（截断之前）做子串匹配。"""
    for keyword in DROP_KEYWORDS:
        if keyword in text:
            return keyword
    return ""


# ---------------------------------------------------------------------------
# 发：按目标类型拼请求
# ---------------------------------------------------------------------------


def is_json_shell(template):
    """模板去掉占位符后仍是合法 JSON，才算「JSON 壳」。

    注意不能只看开头是不是 { —— 单独一个 {{{message}}} 也以 { 开头，
    但那是「原样替换」，不该被转义。
    """
    try:
        json.loads(template.replace("{{{message}}}", "x"))
        return True
    except Exception:
        return False


def render_body(template, text):
    """渲染带占位符的模板。

    {{{message}}}  三花括号 = 不转义
    {{message}}    双花括号 = HTML 转义（像 Handlebars 那样）
    模板是 JSON 壳时，先把文本按 JSON 字符串转义再塞进去，这样多行文本不会破坏 JSON。
    """
    if not template:
        template = '{"text": "{{{message}}}"}'
    if "{{{message}}}" in template:
        if is_json_shell(template):
            escaped = json.dumps(text, ensure_ascii=False)[1:-1]
            return template.replace("{{{message}}}", escaped)
        return template.replace("{{{message}}}", text)
    if "{{message}}" in template:
        escaped = (
            text.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
        )
        return template.replace("{{message}}", escaped)
    print("[webhook-relay] TARGET_BODY 里没有 {{{message}}} 占位符，正文接在后面", flush=True)
    return template + "\n" + text


def parse_headers(spec):
    """TARGET_HEADERS 支持两种写法：{"X-A":"1"} 或 "X-A=1;X-B=2"。"""
    spec = (spec or "").strip()
    if not spec:
        return {}
    try:
        obj = json.loads(spec)
        if isinstance(obj, dict):
            return {str(k): str(v) for k, v in obj.items()}
    except Exception:
        pass
    out = {}
    for part in spec.split(";"):
        key, _, value = part.partition("=")
        if key.strip():
            out[key.strip()] = value.strip()
    return out


def dingtalk_signed_url():
    url = DINGTALK_URL or "https://oapi.dingtalk.com/robot/send?access_token=%s" % DINGTALK_TOKEN
    if not DINGTALK_SECRET:
        return url
    timestamp = str(round(time.time() * 1000))
    payload = ("%s\n%s" % (timestamp, DINGTALK_SECRET)).encode("utf-8")
    digest = hmac.new(DINGTALK_SECRET.encode("utf-8"), payload, hashlib.sha256).digest()
    sign = urllib.parse.quote_plus(base64.b64encode(digest))
    joiner = "&" if "?" in url else "?"
    return "%s%stimestamp=%s&sign=%s" % (url, joiner, timestamp, sign)


def simple_text_body(text):
    """企微 / 钉钉的群机器人格式。"""
    return json.dumps({"msgtype": "text", "text": {"content": text}}, ensure_ascii=False)


def build_request(text):
    """返回 (url, body bytes, headers)。配置不全时抛 ValueError。"""
    if TARGET_TYPE == "generic":
        if not TARGET_URL:
            raise ValueError("TARGET_URL 没配")
        headers = parse_headers(TARGET_HEADERS)
        headers.setdefault("Content-Type", "application/json")
        return TARGET_URL, render_body(TARGET_BODY, text).encode("utf-8"), headers

    if TARGET_TYPE == "qwenpaw":
        if not (TARGET_USER and TARGET_SESSION):
            raise ValueError("TARGET_USER / TARGET_SESSION 没配")
        body = json.dumps(
            {
                "channel": CHANNEL or "qq",
                "target_user": TARGET_USER,
                "target_session": TARGET_SESSION,
                "text": text,
            },
            ensure_ascii=False,
        ).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if AGENT_ID:
            headers["X-Agent-Id"] = AGENT_ID
        return QWENPAW_URL, body, headers

    if TARGET_TYPE == "wecom":
        url = WECOM_URL or "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=%s" % WECOM_KEY
        if "key=" in url and not (WECOM_KEY or WECOM_URL):
            raise ValueError("WECOM_KEY 或 WECOM_URL 没配")
        return url, simple_text_body(text).encode("utf-8"), {"Content-Type": "application/json"}

    if TARGET_TYPE == "dingtalk":
        if not (DINGTALK_URL or DINGTALK_TOKEN):
            raise ValueError("DINGTALK_URL 或 DINGTALK_TOKEN 没配")
        return dingtalk_signed_url(), simple_text_body(text).encode("utf-8"), {"Content-Type": "application/json"}

    if TARGET_TYPE == "feishu":
        url = FEISHU_URL or "https://open.feishu.cn/open-apis/bot/v2/hook/%s" % FEISHU_TOKEN
        if not (FEISHU_URL or FEISHU_TOKEN):
            raise ValueError("FEISHU_URL 或 FEISHU_TOKEN 没配")
        body = json.dumps({"msg_type": "text", "content": {"text": text}}, ensure_ascii=False)
        return url, body.encode("utf-8"), {"Content-Type": "application/json"}

    raise ValueError("不认识的目标类型 TARGET_TYPE=%r（可选 generic/qwenpaw/wecom/dingtalk/feishu）" % TARGET_TYPE)


def judge(payload_text):
    """群机器人会回 200 但带 errcode/code，这里把它当失败。返回 (ok, note)。"""
    try:
        obj = json.loads(payload_text)
    except Exception:
        return True, ""
    if not isinstance(obj, dict):
        return True, ""
    for key in ("errcode", "code", "StatusCode"):
        if key in obj:
            try:
                code = int(obj[key])
            except (TypeError, ValueError):
                continue
            if code != 0:
                return False, "%s=%s %s" % (key, code, obj.get("errmsg") or obj.get("msg") or "")
            return True, ""
    if obj.get("ok") is False:
        return False, str(obj.get("detail") or obj)
    return True, ""


def send(text):
    try:
        url, body, headers = build_request(text)
    except ValueError as exc:
        return False, "配置错误：%s" % exc
    request = urllib.request.Request(url, data=body, headers=headers, method=TARGET_METHOD)
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            payload = response.read()[:500].decode("utf-8", "replace")
            ok, note = judge(payload)
            return ok, "HTTP %s %s%s" % (response.status, note, payload)
    except urllib.error.HTTPError as exc:
        return False, "HTTP %s %s" % (exc.code, exc.read()[:300].decode("utf-8", "replace"))
    except Exception as exc:  # noqa: BLE001
        return False, "%s: %s" % (type(exc).__name__, exc)


def masked(url):
    """打日志时把 token/key 遮掉。"""
    if "?" in url:
        head, _, query = url.partition("?")
        keep = "&".join(
            part for part in query.split("&") if part.split("=")[0] in ("timestamp", "sign")
        )
        return "%s?%s...(已隐藏)" % (head, (keep + "&") if keep else "")
    return url


# ---------------------------------------------------------------------------
# HTTP 服务
# ---------------------------------------------------------------------------


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 进 docker logs
        sys.stderr.write("[webhook-relay] %s - %s\n" % (self.address_string(), fmt % args))

    def _reply(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # 健康检查：curl http://127.0.0.1:<port>/
        self._reply(200, {"ok": True, "service": SERVICE, "version": VERSION, "target_type": TARGET_TYPE})

    def do_POST(self):
        if (self.path or "/").split("?")[0] not in ("/", "/hook", "/webhook"):
            self._reply(404, {"ok": False, "error": "post to / "})
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        text = extract_text(raw)
        if not text:
            print("[webhook-relay] %s empty body -> 400" % self.path, flush=True)
            self._reply(400, {"ok": False, "error": "empty body"})
            return
        keyword = drop_hit(text)
        if keyword:
            print(
                "[webhook-relay] %s dropped (命中 %r) in=%dB text=%d"
                % (self.path, keyword, len(raw), len(text)),
                flush=True,
            )
            self._reply(200, {"ok": True, "dropped": True, "keyword": keyword})
            return
        truncated = len(text) > MAX_TEXT_LEN
        if truncated:
            text = text[:MAX_TEXT_LEN] + "…"
        if TEXT_PREFIX:
            text = TEXT_PREFIX + text
        ok, detail = send(text)
        print(
            "[webhook-relay] %s in=%dB text=%d -> %s %s"
            % (self.path, len(raw), len(text), "OK" if ok else "FAIL", detail),
            flush=True,
        )
        self._reply(200 if ok else 502, {"ok": ok, "detail": detail, "truncated": truncated})

    def do_PUT(self):  # 有些服务用 PUT 发 webhook
        self.do_POST()


def describe():
    try:
        url, body, headers = build_request("（自检文本）")
    except ValueError as exc:
        return "配置有问题：%s" % exc
    return "目标类型=%s url=%s headers=%s body=%r 丢弃词=%s" % (
        TARGET_TYPE,
        masked(url),
        sorted(headers.keys()),
        body[:120],
        ",".join(DROP_KEYWORDS) if DROP_KEYWORDS else "(关)",
    )


def main():
    args = sys.argv[1:]
    if "--describe" in args:
        print("[webhook-relay] 监听端口 %s" % LISTEN_PORT)
        print("[webhook-relay] %s" % describe())
        return 0
    if "--self-test" in args:
        print("[webhook-relay] %s" % describe())
        marker = os.environ.get("SELF_TEST_TEXT") or "ferryman 自检消息（收到即说明投递链路通）"
        ok, detail = send((TEXT_PREFIX or "") + marker)
        print("[webhook-relay] 自检 %s %s" % ("OK" if ok else "FAIL", detail))
        return 0 if ok else 1

    try:
        build_request("x")  # 启动前先校验配置
    except ValueError as exc:
        print("[webhook-relay] 配置不完整，退出：%s" % exc, file=sys.stderr, flush=True)
        return 2
    port = int(LISTEN_PORT)
    print("[webhook-relay] %s v%s listening 0.0.0.0:%d" % (SERVICE, VERSION, port), flush=True)
    print("[webhook-relay] %s" % describe(), flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), RelayHandler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
# ferryman 一键安装
#
# 干什么：起一个常驻小容器，收任意 webhook，抽成纯文本，按你配的目标发出去。
#         典型用途：把某个服务的通知推到 IM / 另一个中转 / 你的 agent。
#
# 怎么用（三种填法，挑一种）：
#   1) 问答：    bash install.sh              # 在终端里跑就逐项问你，直接回车用默认值
#   2) 一条命令：bash install.sh --type wecom --wecom-key <KEY>
#                bash install.sh --type generic --url http://10.0.0.9:8000/hook
#   3) 文件：    编辑 relay.env 再 bash install.sh   （脚本在非终端环境跑时也只走这条）
#
# 其它参数：--ask 强制问答 / --dry-run 只校验+自检不启动 / --no-test 自检不真发消息
#          RELAY_DIR=<目录> CONTAINER_NAME=<名字> 可覆盖安装目录与容器名
# 幂等：重复执行＝重写 compose + 重建容器，不叠加。

if [ -z "${BASH_VERSION:-}" ]; then
  if [ -f "$0" ]; then exec bash "$0" "$@"; fi
  printf '请用 bash 运行：bash install.sh\n' >&2
  exit 2
fi

set -euo pipefail

DRY_RUN=0
NO_TEST=0
ASK=0
FROM_ARGS=0
P_TYPE=""; P_URL=""; P_BODY=""; P_HEADERS=""; P_METHOD=""; P_PORT=""; P_PREFIX=""; P_MAXLEN=""; P_DROP=""
P_AGENT_ID=""; P_CHANNEL=""; P_USER=""; P_SESSION=""; P_QWENPAW_URL=""
P_WECOM_KEY=""; P_DT_TOKEN=""; P_DT_SECRET=""; P_FEISHU_TOKEN=""

usage() {
  cat <<'TXT'
用法：bash install.sh [选项]
  --ask                 逐项问答填配置（终端里默认就会问）
  --dry-run             只做校验和自检，不启动容器
  --no-test             自检不真发消息，只打印将要用到的配置
  --type <t>            generic | qwenpaw | wecom | dingtalk | feishu
  --url <url>           generic 的目标 URL
  --body <tmpl>         generic 的 body 模板，如 '{"text": "{{{message}}}"}'
  --headers <spec>      额外请求头，如 'Authorization=Bearer xxx' 或 {"k":"v"}
  --method <m>          请求方法，默认 POST
  --port <n>            监听端口，默认 8311
  --prefix <s>          消息前缀
  --max-len <n>         最长转发字符数，默认 1500
  --drop-keywords <s>   正文含这些词的整条吞掉，逗号分隔（可空）
  --agent-id <id>       qwenpaw：用哪个 agent 的身份发
  --channel <c>         qwenpaw：渠道，如 qq
  --user <u>            qwenpaw：target_user
  --session <sid>       qwenpaw：target_session，如 qq:c2c:xxxx
  --qwenpaw-url <url>   qwenpaw：接口地址
  --wecom-key <k>       wecom：群机器人 key
  --dingtalk-token <t>  dingtalk：access_token
  --dingtalk-secret <s> dingtalk：加签密钥（可选）
  --feishu-token <t>    feishu：机器人 token
TXT
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-test) NO_TEST=1 ;;
    --ask) ASK=1 ;;
    --type|--url|--body|--headers|--method|--port|--prefix|--max-len|--agent-id|--channel|--user|--session|--qwenpaw-url|--wecom-key|--dingtalk-token|--dingtalk-secret|--feishu-token|--drop-keywords)
      [ $# -ge 2 ] || { printf '%s 后面要跟一个值\n' "$1" >&2; exit 2; }
      FROM_ARGS=1
      case "$1" in
        --type) P_TYPE="$2" ;;
        --url) P_URL="$2" ;;
        --body) P_BODY="$2" ;;
        --headers) P_HEADERS="$2" ;;
        --method) P_METHOD="$2" ;;
        --port) P_PORT="$2" ;;
        --prefix) P_PREFIX="$2" ;;
        --max-len) P_MAXLEN="$2" ;;
        --agent-id) P_AGENT_ID="$2" ;;
        --channel) P_CHANNEL="$2" ;;
        --user) P_USER="$2" ;;
        --session) P_SESSION="$2" ;;
        --qwenpaw-url) P_QWENPAW_URL="$2" ;;
        --wecom-key) P_WECOM_KEY="$2" ;;
        --dingtalk-token) P_DT_TOKEN="$2" ;;
        --dingtalk-secret) P_DT_SECRET="$2" ;;
        --feishu-token) P_FEISHU_TOKEN="$2" ;;
        --drop-keywords) P_DROP="$2" ;;
      esac
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数：%s（-h 看用法）\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELAY_DIR="${RELAY_DIR:-$SCRIPT_DIR}"
CONTAINER_NAME="${CONTAINER_NAME:-ferryman}"   # v1.0.1 及更早叫 webhook-relay
RELAY_IMAGE="python:3.12-alpine"
ENV_FILE="$RELAY_DIR/relay.env"
INSTALLED=0

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

# 给 relay.env 里的值加单引号（shell 和 docker compose 都按字面取）
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

command -v docker >/dev/null 2>&1 || die "找不到 docker，这个脚本要在装了 docker 的机器上跑"
docker info >/dev/null 2>&1 || die "docker 不可用（权限或守护进程问题）"
[ -f "$SCRIPT_DIR/relay.py" ] || die "$SCRIPT_DIR 下没有 relay.py"

# --- 1. 问答填配置 -----------------------------------------------------------
ask() { # ask <变量名> <提示> [默认值]
  local ans
  printf '  %s' "$2"
  [ -n "${3:-}" ] && printf ' [%s]' "$3"
  printf ': '
  IFS= read -r ans || ans=""
  [ -z "$ans" ] && ans="${3:-}"
  printf -v "$1" '%s' "$ans"
}

ask_required() { # 必填，空就重问
  local v
  while :; do
    ask "$1" "$2" "${3:-}"
    printf -v v '%s' "${!1}"
    [ -n "$v" ] && return 0
    say "  这项不能空，再来一次"
  done
}

do_ask() {
  say "逐项填，直接回车用括号里的默认值。"
  local t
  ask t "目标类型 1=generic(任意URL) 2=qwenpaw 3=企业微信 4=钉钉 5=飞书" "1"
  case "$t" in
    2|q|qwenpaw)
      TARGET_TYPE=qwenpaw
      ask QWENPAW_URL "QwenPaw 接口地址（必须和本机同机）" "http://127.0.0.1:8088/api/messages/send"
      ask_required AGENT_ID "用哪个 agent 的身份发（填你 QwenPaw 里已有 agent 的 id）" ""
      ask CHANNEL "渠道" "qq"
      ask_required TARGET_USER "target_user"
      ask_required TARGET_SESSION "target_session（形如 qq:c2c:xxxx）"
      ;;
    3|w|wecom)
      TARGET_TYPE=wecom
      ask_required WECOM_KEY "企业微信群机器人 key"
      ;;
    4|d|dingtalk)
      TARGET_TYPE=dingtalk
      ask_required DINGTALK_TOKEN "钉钉机器人 access_token"
      ask DINGTALK_SECRET "加签密钥（机器人安全设置没选加签就回车）" ""
      ;;
    5|f|feishu)
      TARGET_TYPE=feishu
      ask_required FEISHU_TOKEN "飞书机器人 token"
      ;;
    *)
      TARGET_TYPE=generic
      ask_required TARGET_URL "目标 URL（收到后往哪儿 POST）"
      ask TARGET_BODY "body 模板（{{{message}}} 会被正文替换）" '{"text": "{{{message}}}"}'
      ask TARGET_HEADERS "额外请求头，可空（如 Authorization=Bearer xxx）" ""
      ;;
  esac
  ask LISTEN_PORT "监听端口" "8311"
  ask MAX_TEXT_LEN "最长转发字符数" "1500"
  ask TEXT_PREFIX "消息前缀，可空" ""
  ask DROP_KEYWORDS "正文里含这些词就吞掉，逗号分隔，可空" ""
}

# --- 2. 写 relay.env ---------------------------------------------------------
write_env() {
  if [ -f "$ENV_FILE" ]; then
    if [ "$ASK" -eq 1 ] || [ "$FROM_ARGS" -eq 1 ]; then
      cp "$ENV_FILE" "$ENV_FILE.bak"
      say "原配置已备份：$ENV_FILE.bak"
    fi
  fi
  local type="${TARGET_TYPE:-generic}"
  local body="${TARGET_BODY:-}"
  [ -z "$body" ] && body='{"text": "{{{message}}}"}'
  {
    printf '# 由 install.sh 生成（%s）。改完执行：docker compose up -d --force-recreate\n' "$(date +%F)"
    printf 'LISTEN_PORT=%s\n' "$(sq "${LISTEN_PORT:-8311}")"
    printf 'MAX_TEXT_LEN=%s\n' "$(sq "${MAX_TEXT_LEN:-1500}")"
    printf 'TEXT_PREFIX=%s\n' "$(sq "${TEXT_PREFIX:-}")"
    printf 'DROP_KEYWORDS=%s\n' "$(sq "${DROP_KEYWORDS:-}")"
    printf 'TARGET_TYPE=%s\n' "$(sq "$type")"
    case "$type" in
      generic)
        printf 'TARGET_URL=%s\n' "$(sq "${TARGET_URL:-}")"
        printf 'TARGET_BODY=%s\n' "$(sq "$body")"
        printf 'TARGET_HEADERS=%s\n' "$(sq "${TARGET_HEADERS:-}")"
        printf 'TARGET_METHOD=%s\n' "$(sq "${TARGET_METHOD:-POST}")"
        ;;
      qwenpaw)
        printf 'QWENPAW_URL=%s\n' "$(sq "${QWENPAW_URL:-http://127.0.0.1:8088/api/messages/send}")"
        printf 'AGENT_ID=%s\n' "$(sq "${AGENT_ID:-}")"
        printf 'CHANNEL=%s\n' "$(sq "${CHANNEL:-qq}")"
        printf 'TARGET_USER=%s\n' "$(sq "${TARGET_USER:-}")"
        printf 'TARGET_SESSION=%s\n' "$(sq "${TARGET_SESSION:-}")"
        ;;
      wecom)
        printf 'WECOM_KEY=%s\n' "$(sq "${WECOM_KEY:-}")"
        printf 'WECOM_URL=%s\n' "$(sq "${WECOM_URL:-}")"
        ;;
      dingtalk)
        printf 'DINGTALK_TOKEN=%s\n' "$(sq "${DINGTALK_TOKEN:-}")"
        printf 'DINGTALK_URL=%s\n' "$(sq "${DINGTALK_URL:-}")"
        printf 'DINGTALK_SECRET=%s\n' "$(sq "${DINGTALK_SECRET:-}")"
        ;;
      feishu)
        printf 'FEISHU_TOKEN=%s\n' "$(sq "${FEISHU_TOKEN:-}")"
        printf 'FEISHU_URL=%s\n' "$(sq "${FEISHU_URL:-}")"
        ;;
    esac
  } > "$ENV_FILE"
  say "已写入 $ENV_FILE"
}

# --- 3. 取配置 ---------------------------------------------------------------
mkdir -p "$RELAY_DIR"
if [ "$SCRIPT_DIR/relay.py" != "$RELAY_DIR/relay.py" ]; then
  cp "$SCRIPT_DIR/relay.py" "$RELAY_DIR/relay.py"
fi

if [ "$FROM_ARGS" -eq 1 ]; then
  # 一条命令形态：参数为准，能给默认的给默认
  TARGET_TYPE="${P_TYPE:-generic}"
  TARGET_URL="$P_URL"
  TARGET_BODY="$P_BODY"
  TARGET_HEADERS="$P_HEADERS"
  TARGET_METHOD="${P_METHOD:-POST}"
  LISTEN_PORT="${P_PORT:-8311}"
  TEXT_PREFIX="$P_PREFIX"
  MAX_TEXT_LEN="${P_MAXLEN:-1500}"
  [ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }  # 没传的项沿用旧文件
  # 参数覆盖文件
  [ -n "$P_TYPE" ] && TARGET_TYPE="$P_TYPE"
  [ -n "$P_URL" ] && TARGET_URL="$P_URL"
  [ -n "$P_BODY" ] && TARGET_BODY="$P_BODY"
  [ -n "$P_HEADERS" ] && TARGET_HEADERS="$P_HEADERS"
  [ -n "$P_METHOD" ] && TARGET_METHOD="$P_METHOD"
  [ -n "$P_PORT" ] && LISTEN_PORT="$P_PORT"
  [ -n "$P_MAXLEN" ] && MAX_TEXT_LEN="$P_MAXLEN"
  [ -n "$P_PREFIX" ] && TEXT_PREFIX="$P_PREFIX"
  [ -n "$P_DROP" ] && DROP_KEYWORDS="$P_DROP"
  QWENPAW_URL="${P_QWENPAW_URL:-${QWENPAW_URL:-http://127.0.0.1:8088/api/messages/send}}"
  [ -n "$P_AGENT_ID" ] && AGENT_ID="$P_AGENT_ID"
  [ -n "$P_CHANNEL" ] && CHANNEL="$P_CHANNEL"
  [ -n "$P_USER" ] && TARGET_USER="$P_USER"
  [ -n "$P_SESSION" ] && TARGET_SESSION="$P_SESSION"
  [ -n "$P_WECOM_KEY" ] && WECOM_KEY="$P_WECOM_KEY"
  [ -n "$P_DT_TOKEN" ] && DINGTALK_TOKEN="$P_DT_TOKEN"
  [ -n "$P_DT_SECRET" ] && DINGTALK_SECRET="$P_DT_SECRET"
  [ -n "$P_FEISHU_TOKEN" ] && FEISHU_TOKEN="$P_FEISHU_TOKEN"
  # 上面这些可能是未定义的，统一兜底
  for v in TARGET_URL TARGET_BODY TARGET_HEADERS TARGET_METHOD LISTEN_PORT TEXT_PREFIX MAX_TEXT_LEN DROP_KEYWORDS \
           AGENT_ID CHANNEL TARGET_USER TARGET_SESSION WECOM_KEY WECOM_URL DINGTALK_TOKEN DINGTALK_URL \
           DINGTALK_SECRET FEISHU_TOKEN FEISHU_URL; do
    [ -n "${!v:-}" ] || printf -v "$v" '%s' ""
  done
  write_env
elif [ -f "$ENV_FILE" ]; then
  if [ "$ASK" -eq 1 ]; then do_ask; write_env; fi
elif [ "$ASK" -eq 1 ] || [ -t 0 ]; then
  do_ask
  write_env
else
  if [ -f "$SCRIPT_DIR/relay.env.example" ]; then
    cp "$SCRIPT_DIR/relay.env.example" "$ENV_FILE"
  else
    touch "$ENV_FILE"
  fi
  say "已生成配置文件：$ENV_FILE"
  say ""
  say "这是非终端环境，没法问答。两种继续方式："
  say "  1) 编辑 $ENV_FILE 里的 TARGET_TYPE 和对应参数，然后重跑本脚本"
  say "  2) 或者带上参数直接跑，例如： bash $0 --type generic --url http://10.0.0.9:8000/hook"
  exit 0
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# --- 4. 校验配置 -------------------------------------------------------------
TARGET_TYPE="$(printf '%s' "${TARGET_TYPE:-generic}" | tr 'A-Z' 'a-z')"
LISTEN_PORT="${LISTEN_PORT:-8311}"

case "$TARGET_TYPE" in
  generic)  [ -n "${TARGET_URL:-}" ] || die "TARGET_TYPE=generic 需要 TARGET_URL（--url 或 relay.env）" ;;
  qwenpaw)  [ -n "${TARGET_USER:-}" ] && [ -n "${TARGET_SESSION:-}" ] \
              || die "TARGET_TYPE=qwenpaw 需要 TARGET_USER 和 TARGET_SESSION（形如 qq:c2c:xxxx）" ;;
  wecom)    [ -n "${WECOM_KEY:-}" ] || [ -n "${WECOM_URL:-}" ] || die "TARGET_TYPE=wecom 需要 WECOM_KEY 或 WECOM_URL" ;;
  dingtalk) [ -n "${DINGTALK_TOKEN:-}" ] || [ -n "${DINGTALK_URL:-}" ] || die "TARGET_TYPE=dingtalk 需要 DINGTALK_TOKEN 或 DINGTALK_URL" ;;
  feishu)   [ -n "${FEISHU_TOKEN:-}" ] || [ -n "${FEISHU_URL:-}" ] || die "TARGET_TYPE=feishu 需要 FEISHU_TOKEN 或 FEISHU_URL" ;;
  *)        die "TARGET_TYPE=$TARGET_TYPE 不认识（generic/qwenpaw/wecom/dingtalk/feishu）" ;;
esac
say "目标类型：$TARGET_TYPE"

# --- 5. 端口占用 -------------------------------------------------------------
port_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
  else
    return 1
  fi
}
if port_busy "$LISTEN_PORT"; then
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    die "端口 $LISTEN_PORT 已被别的进程占用。换一个：--port 8312，或改 relay.env 的 LISTEN_PORT"
  fi
fi
say "监听端口：$LISTEN_PORT（空闲或本来就是本服务的容器）"

# --- 6. 写 compose -----------------------------------------------------------
cat > "$RELAY_DIR/docker-compose.yml" <<YAML
# ferryman —— 收 webhook，抽纯文本，按 relay.env 的目标发出去
#
# 配置：$ENV_FILE（改完 docker compose up -d --force-recreate）
# 日志：docker logs -f $CONTAINER_NAME
# 健康检查：curl http://127.0.0.1:$LISTEN_PORT/
# 自检：docker run --rm --network host --env-file relay.env -v ./relay.py:/app/relay.py:ro $RELAY_IMAGE python /app/relay.py --self-test
# 卸载：bash $RELAY_DIR/uninstall.sh
services:
  $CONTAINER_NAME:
    image: $RELAY_IMAGE
    container_name: $CONTAINER_NAME
    command: ["python", "-u", "/app/relay.py"]
    restart: unless-stopped
    # host 网络：目标是本机服务（例如 QwenPaw 只认 127.0.0.1）时必须这样
    network_mode: host
    env_file:
      - $ENV_FILE
    volumes:
      - $RELAY_DIR/relay.py:/app/relay.py:ro
    labels:
      purpose: "webhook 中转：抽取纯文本并按 relay.env 的目标转发（TARGET_TYPE=$TARGET_TYPE, 端口 $LISTEN_PORT）"
      owner: "ferryman installer"
      created: "$(date +%F)"
      note: "无业务逻辑，纯转发；改配置只改 relay.env"
YAML
docker compose -f "$RELAY_DIR/docker-compose.yml" config -q || die "compose 文件校验失败"
say "已写入 $RELAY_DIR/docker-compose.yml"

# --- 7. 自检 -----------------------------------------------------------------
say ""
say "== 自检 =="
if [ "$NO_TEST" -eq 1 ]; then
  docker run --rm --network host --env-file "$ENV_FILE" \
    -v "$RELAY_DIR/relay.py:/app/relay.py:ro" "$RELAY_IMAGE" \
    python /app/relay.py --describe
else
  say "（会真发一条测试消息到目标）"
  set +e
  docker run --rm --network host --env-file "$ENV_FILE" \
    -v "$RELAY_DIR/relay.py:/app/relay.py:ro" "$RELAY_IMAGE" \
    python /app/relay.py --self-test
  TEST_RC=$?
  set -e
  if [ "$TEST_RC" -ne 0 ]; then
    say ""
    say "自检没通过：目标没收下这条消息。按上面的报错改配置（URL / token / 会话 id）再重跑。"
    say "现在不启动常驻容器。"
    exit "$TEST_RC"
  fi
fi

# --- 8. 起容器 ---------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  say ""
  say "== --dry-run：校验和自检都过了，不启动容器 =="
  say "正式安装：bash $0"
  exit 0
fi

say ""
say "== 启动 =="
docker compose -f "$RELAY_DIR/docker-compose.yml" up -d
INSTALLED=1
sleep 3
docker logs --tail 15 "$CONTAINER_NAME" 2>&1 || true
if command -v curl >/dev/null 2>&1; then
  say ""
  say "健康检查："
  curl -s --max-time 5 "http://127.0.0.1:$LISTEN_PORT/" || say "（健康检查没回应，看上面的日志）"
fi
say ""
say "装好了。把要发通知的那个服务的 webhook 指向 http://<本机地址>:$LISTEN_PORT/ 即可。"
say "看日志：docker logs -f $CONTAINER_NAME"

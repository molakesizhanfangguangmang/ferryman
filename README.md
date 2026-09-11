# ferryman

一个极小的 webhook 中转：把收到的请求抽成一条纯文本，按你配的目标发出去。没有 Web 界面，没有数据库，没有队列，没有第三方依赖——整个项目就是一个 Python 文件加一个安装脚本，跑成一个容器。

名字取自摆渡人。河把两岸断开，船再把两岸接上。
上游递来什么，它载什么；下游要什么，它送什么。
不问乘客姓名，不留过客行李。

## 轻到什么程度

依赖是零。`relay.py` 里 import 的全是标准库，单文件约 400 行含注释。镜像直接用官方 `python:3.12-alpine`，仓库里没有 Dockerfile，不自己构建。配置是一个六七行的文本文件。

没有 Web 界面，没有数据库、队列、定时任务、状态文件。进程不落盘，重启不留痕，常驻的只有一个 HTTP server，占一个 TCP 端口。内存是十几 MB 的量级（同一台机器上，骨架更简单的旧版实测 15.6 MiB）。

不做 Web 界面是有意的：配置就那几项，多一个前端就多一份依赖、一份资源、一份攻击面。要看状态，用 `docker logs`、`curl` 健康检查、`docker ps`；改配置就改文件，再 `docker compose up -d --force-recreate`。

那些能拖流程的转换层（n8n、Node-RED、Huginn）能做的事比它多得多，代价是自带前端和数据库，镜像和常驻开销都高出量级。ferryman 只做转发这一件事。

## 什么时候用得上

目标服务能直接吃源服务发的东西，就不需要它。比如 bili-sync 原生支持 Telegram 和 SMTP，配个通知器就完事，中间不用加东西。

三种情况，中一条就值得加：

- 源服务把多行文本塞进 JSON 壳里发，接收方解析不了。bili-sync 的默认模板 `{"text": "{{{message}}}"}` 就是这样，正文带真换行，发出去是非法 JSON，接收方直接 422。
- 源服务只会 POST 一个固定 URL，而你要推到它不认识的地方：QQ、微信、自建的 bot、另一个中转。
- 源服务发完不看状态码，失败一声不吭，你想有一层能看日志的。

## 做和不做

收 POST（GET 留给健康检查）。抽正文时按 `text` / `message` / `content` / `msg` / `desp` / `body` 这几个字段名找，含一层嵌套；裸文本直接用；字符串数组按行拼；像 HTML 的会剥掉标签。非法 JSON 里的裸换行会先修回来。之后超长截断、加上前缀、按目标类型拼成合法请求发出去，结果写日志，返回 200 或 502。

不判断内容，不过滤，不重试，不排队。收到什么转什么，一条一条来，失败就如实报失败。

## 安装

三种填法，挑一种。在终端里跑会直接问；非终端环境（脚本、CI、管道）不会卡在提问上，而是生成 `relay.env` 让你填，或者补命令行参数。

```sh
# 1) 问答：逐项问，直接回车用括号里的默认值
bash install.sh

# 2) 一条命令：参数直接给（适合写进文档让别人照抄）
bash install.sh --type wecom --wecom-key <KEY>
bash install.sh --type generic --url http://10.0.0.9:8000/hook
bash install.sh --type qwenpaw --agent-id <agent> --channel qq --user <openid> --session qq:c2c:<openid>

# 3) 文件：编辑 relay.env 再跑（非终端环境只走这条）
bash install.sh
```

参数没给全的项沿用 `relay.env` 里的旧值；`--ask` 强制走问答（会先把旧配置备份成 `relay.env.bak`）。全部选项看 `bash install.sh --help`。

安装脚本做这几件事：校验配置是否齐全，检查端口是否被占（撞了就停下让你换，不硬上），写 `docker-compose.yml`，**自检**——用你的配置真发一条测试消息，收到才算过——然后起容器。自检不过就不启动，改完配置直接重跑，`relay.env` 和 compose 都还在，不用重填。

| 常用命令 | |
| --- | --- |
| 改配置 | 改 `relay.env`，然后 `docker compose up -d --force-recreate` |
| 看日志 | `docker logs -f webhook-relay` |
| 健康检查 | `curl http://127.0.0.1:8311/` |
| 单独自检 | `docker run --rm --network host --env-file relay.env -v ./relay.py:/app/relay.py:ro python:3.12-alpine python /app/relay.py --self-test` |
| 只看配置不发送 | 上面那条加 `--describe`，或 `bash install.sh --no-test` |
| 只校验不启动 | `bash install.sh --dry-run` |
| 卸载 | `bash uninstall.sh`（加 `--purge` 连文件一起删） |

端口默认 `8311`，被占用就在 `relay.env` 里改，或者 `--port 8312`。容器名默认 `webhook-relay`，`CONTAINER_NAME=` 可覆盖。

## 目标类型

要改的就一个文件 `relay.env`。`TARGET_TYPE` 选下面之一：

| 类型 | 用在 | 必填 |
| --- | --- | --- |
| `generic` | 任意 HTTP 端点：另一个中转、别人的 agent、你自己写的脚本、推送服务 | `TARGET_URL`；可选 `TARGET_BODY`（模板）、`TARGET_HEADERS`、`TARGET_METHOD` |
| `qwenpaw` | 投到 QwenPaw 的某个会话，以指定 agent 的身份发 | `QWENPAW_URL`、`AGENT_ID`、`CHANNEL`、`TARGET_USER`、`TARGET_SESSION` |
| `wecom` | 企业微信群机器人 | `WECOM_KEY`（或整条 `WECOM_URL`） |
| `dingtalk` | 钉钉群机器人 | `DINGTALK_TOKEN`（或 `DINGTALK_URL`）；选了「加签」再加 `DINGTALK_SECRET` |
| `feishu` | 飞书自定义机器人 | `FEISHU_TOKEN`（或 `FEISHU_URL`） |

五档发出去的请求长这样：

```http
# generic —— 方法可用 TARGET_METHOD 改，Content-Type 默认 application/json
POST <TARGET_URL>
<TARGET_HEADERS 里的头>
{"text": "<正文>"}                      # TARGET_BODY 模板，默认这个

# qwenpaw —— 投递，不唤醒模型、不烧 token
POST <QWENPAW_URL>
Content-Type: application/json
X-Agent-Id: <AGENT_ID>
{"channel":"<CHANNEL>","target_user":"<TARGET_USER>","target_session":"<TARGET_SESSION>","text":"<正文>"}

# wecom
POST https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<WECOM_KEY>
{"msgtype":"text","text":{"content":"<正文>"}}

# dingtalk —— 配了 DINGTALK_SECRET 时自动加签
POST https://oapi.dingtalk.com/robot/send?access_token=<TOKEN>&timestamp=..&sign=..
{"msgtype":"text","text":{"content":"<正文>"}}

# feishu
POST https://open.feishu.cn/open-apis/bot/v2/hook/<FEISHU_TOKEN>
{"msg_type":"text","content":{"text":"<正文>"}}
```

群机器人那三档会看对方返回的 `errcode` / `code` / `StatusCode`：HTTP 200 但码不为 0（key 失效、机器人被移出群、加签不对）算失败，错误原文写进日志。

### body 模板规则

- `{{{message}}}` 原样替换；`{{message}}` 做 HTML 转义（跟 Handlebars 一样）。
- 模板去掉占位符后**仍然是合法 JSON**（比如 `{"text": "{{{message}}}"}`）时，正文会先按 JSON 字符串转义再塞进去，所以多行文本不会把 JSON 弄坏。
  判断方法：把占位符换成一个不带引号的小写 `x`，看模板还是不是合法 JSON。所以 JSON 模板里的占位符要带引号；写成 `{"n": {{{message}}}}` 这种不带引号的，会被当成非 JSON 模板、按原样替换。
- 只写 `{{{message}}}` 一个占位符时是原样替换——它虽然以 `{` 开头，但不算 JSON 壳。
- 模板里一个占位符都没有 → 正文接在模板后面。

常见配方：

```ini
# 指到另一个中转
TARGET_TYPE=generic
TARGET_URL=http://10.0.0.50:8311/
TARGET_BODY='{{{message}}}'

# Server酱（推到微信）
TARGET_URL=https://sctapi.ftqq.com/<SENDKEY>.send
TARGET_BODY='{"title": "通知", "desp": "{{{message}}}"}'

# PushPlus（推到微信）
TARGET_URL=http://www.pushplus.plus/send
TARGET_BODY='{"token": "<TOKEN>", "title": "通知", "content": "{{{message}}}", "template": "txt"}'

# 需要鉴权的端点（两种写法都行）
TARGET_HEADERS='{"Authorization": "Bearer <TOKEN>"}'
TARGET_HEADERS=Authorization=Bearer <TOKEN>
```

### 到微信的那一层

微信本身没有开放的群机器人接口。实际能走通的尽头通常是这几条，按你的条件选：

- **企业微信群机器人**：`TARGET_TYPE=wecom`。企业微信侧能收到，微信里要收到得靠企业微信的互通设置。
- **第三方推送服务**：Server酱、PushPlus 这类，注册后给你一个 key，微信关注它的服务号 → 用 `generic` 套模板。
- **自己的机器人**：有能收 http 的 QQ / 微信机器人，就当 `generic` 的 URL 用。

### qwenpaw 类型

要填 5 项：`QWENPAW_URL`、`AGENT_ID`（用哪个 agent 的身份发，QwenPaw 里要已经存在这个 agent）、`CHANNEL`（`qq` / `telegram` / …）、`TARGET_USER` 和 `TARGET_SESSION`（形如 `qq:c2c:<用户ID>`）。

几个容易踩的地方：

- **地址填你自己那台**：QwenPaw 官方默认端口是 `8088`，`QWENPAW_URL` 就写 `http://127.0.0.1:8088/api/messages/send`；你如果改过端口就写改过的。
- **必须和 QwenPaw 同机**：那个接口的免鉴权白名单只有 `127.0.0.1`，所以容器用 host 网络（compose 里已经这么写了）。跨机就得给它配鉴权头，那还不如直接用 `generic`。
- **它可能假成功**：投递失败也回 `{"success": true}`。所以日志里看到 `OK` 不代表对方一定收到了。要确认的话，把 `TARGET_URL` 换成能验证的端点再试。
- 会话 id 怎么找：`GET /api/sessions`（带鉴权头）列出来，或者翻 QwenPaw 的日志找 `session_id=qq:c2c:xxxx` 这种行。

## 源服务那侧（以 bili-sync 为例）

1. 设置页加一个 webhook 通知器，地址填 `http://<ferryman 所在主机>:8311/`。
2. **模板改成 `{{{message}}}`**。默认那个 `{"text": "{{{message}}}"}` 碰上多行正文就是非法 JSON——ferryman 能修回来，但填 `{{{message}}}` 更干净。
3. 请求头留空，除非你的目标要鉴权。
4. 保存即生效（配置版本一变，模板缓存就重建），不用重启 bili-sync。

换别的源服务一样：任何能往外 POST 一个 URL 的服务都行——qBittorrent 下载完成、Uptime Kuma 掉线、Gitea / GitHub 的事件、Docker 事件通知、群晖的通知外发，等等。

一条限制：只收 POST 和 PUT。GET 留给健康检查，所以「GET 带 query 参数」那种 webhook 接不了。

## 排查

| 现象 | 原因 / 处理 |
| --- | --- |
| 自检 FAIL，HTTP 401 / 404 | URL 或 token 抄错 |
| 自检 FAIL，HTTP 200 但带 errcode/code≠0 | 机器人 key 失效、机器人被移出群、加签密钥不对——日志里带了对方返回的说明 |
| 日志 `empty body -> 400` | 源服务发的是空 body（有的服务先发一条探活） |
| 日志 `OK` 但对方没收到 | 对方接口假成功。把 `TARGET_URL` 换成能确认的端点验证 |
| 端口起不来 | `LISTEN_PORT` 被占，改一个 |
| QwenPaw 返回 401 | 没和 QwenPaw 同机，或者没走 `127.0.0.1` |
| 正文被截断 | 调大 `MAX_TEXT_LEN` |
| 收到的是整段 JSON | 源服务的字段名不在认得的那几个里，退化成整段文本发出来了 |

## 文件

| 文件 | 作用 |
| --- | --- |
| `relay.py` | 中转本体，纯标准库单文件。`--describe` 打印配置，`--self-test` 发一条测试 |
| `relay.env.example` | 配置模板，首次运行会拷成 `relay.env` |
| `install.sh` | 校验 + 端口检查 + 自检 + 写 compose + 起容器 |
| `uninstall.sh` | 停容器 / 连文件一起删 |
| `docker-compose.yml` | 由 `install.sh` 生成，不用手写 |

## 设计取舍

不重试。重试要配退避、要落盘、要不重复投递，那就不是 400 行了。发送方拿不到 200 就该知道失败，日志里看得见原因。

不排队。每条请求进来立刻发，源服务的通知量不是这个量级。

用 host 网络，唯一原因是要走 `127.0.0.1` 打到宿主机上的服务。不接本机目标的话，改回 bridge 也行。

每个请求单独一个线程（标准库 `ThreadingHTTPServer`），一条慢请求不堵后面的。

不落盘。进程重启不留痕，配置全在 `relay.env` 里。

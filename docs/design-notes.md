# 磁力筛选器（MagnetPicker）— 关键信息

**仓库**：https://github.com/Xananr/magnet-picker （公开，MIT）
**安装位置**：`/Applications/磁力筛选器.app`（ad-hoc 签名、已去隔离属性，双击即用）
**Release**：https://github.com/Xananr/magnet-picker/releases/tag/v1.1 （`MagnetPicker-1.1.zip`）

原生 SwiftUI App，部署目标 macOS 13，无第三方依赖，不依赖 Python / libtorrent。源码即本仓库，构建只需 Xcode 命令行工具。

## 它做什么

粘贴一批 magnet / ed2k（或整页 HTML），先探测每条链接的**真实做种数**，再按**片源质量**打分排序，挑出最值得下的线路；支持分段（按片名 / 按分辨率）、批量复制导出，并可一键发送到 aria2。

## 界面（扁平风格）

- 顶栏：共 N 条 / 有做种 N、参数面板、清空、Aria 状态、开始探测（探测中变停止 + 进度）
- 输入区：粘贴框 58pt（可展开）；右侧网址栏 +「抓取」；导入文件 / 读剪贴板
- 筛选栏（单行）：搜片名、分辨率、分组（片名/分辨率/不分段）、去枪版、做种≥N、复制菜单、导出菜单
- 结果区：`# 分数 做种 分辨率 来源 体积 版本`，按综合分降序；点行右侧滑出详情（片源标签、综合/可用性/质量/做种、每条 tracker 通断、发送到 Aria）
- 状态栏：进度、状态文案、显示数、收起详情

视觉规范：单层底色 + 1px hairline 分隔，6pt 圆角，行高 30、表头 26，无阴影无渐变；最小窗口 1040×640。

## 探测与评分口径

- 做种优先 **scrape（BEP 48，只读）**；不支持才退回 announce（`numwant=0`，不占 peer 名额）；HTTP 超时不再补 announce，避免耗时翻倍
- 多条 tracker 取**最大值**，不求和（同一 swarm 会被重复计数）
- 无 tracker 数据时才用 **DHT get_peers** 兜底
- 体积优先取 magnet 的 `xl`，缺失时从网页锚文本补齐
- 可用性 = `min(1, log10(1+做种)/log10(51)) * 100`；综合分 = 可用性 × 权重(默认 0.6) + 质量 × 0.4
- 枪版 CAM/TS 质量 -30、总分乘 0.35；3D -8；合集/剧集 -4；体积偏离该分辨率常见区间扣分
- ed2k 只解析与参与评分，源数标「未知」、不参与排序

## aria2 集成

JSON-RPC（`addUri` / `getVersion` / `getGlobalStat`），密钥以 `token:` 前缀注入；发送时磁力已合并全部 tracker。

```bash
aria2c --enable-rpc --rpc-listen-port=6800 --rpc-secret=你的密钥
```

App 顶栏 `Aria ▾ → 连接设置…` 填 RPC 地址（`http://127.0.0.1:6800/jsonrpc`）、密钥、保存目录。

## 运行参数与实测

- 默认：tracker 超时 5s、DHT 4s、每条最多 10 个 tracker、并发 16、单条内 4 并发、公共 tracker 启用、可用性权重 0.6、缓存 6h
- 公共 tracker（现役 6 个）：opentrackr / torrent.eu / open.stealth.si / open.demonii / exodus / dler
- 缓存：`~/Library/Caches/MagnetPicker/probe-cache.json`（删掉即强制重新探测）
- 实测：49 条链接约 75s 出全量，命中缓存 0s
- 体积：app 2.3 MB、release 二进制约 1.6 MB；探测完空闲常驻约 100 MB、CPU 归零
- 自检（不弹窗）：`/Applications/磁力筛选器.app/Contents/MacOS/MagnetPicker --selftest`

## 调试启动参数

`--load-url <网页地址>`、`--load <txt/html 路径>`、`--autoprobe`、`--aria-url <url>`、`--aria-secret <密钥>`、`--send-top3`。

`build-app.sh --install` 会编译 release、strip、ad-hoc 签名、校验签名并装进 `/Applications`（**顺序必须是 strip → codesign**，反过来签名会失效、启动即 SIGKILL）。

## 已知边界

- 走 TUN 代理（Clash / Surge）时 UDP 常被拦，UDP tracker 与 DHT 大面积失败；让 App 走直连或换 HTTP tracker
- PT 私有站需 passkey，公网探不到，会显示 0 做种（正常）
- 探测纯只读：不加入下载队列、不改种子文件，只有点「发送到 Aria」才真的建任务

## 实测样例（xbgame.net/951.html，《奇异博士2》）

49 个唯一种子、36 个有做种；TOP1 `2160p WEB-DL DDP5.1 Atmos HDR H.265-EVO 22.0GB`（56 做种，94.0 分），TOP2 `2160p BluRay REMUX 26.9GB`（32 做种，91.8 分），TOP3 `1080p WEBRip 7.3GB`（54 做种，86.4 分）。

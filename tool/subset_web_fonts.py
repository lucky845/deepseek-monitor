#!/usr/bin/env python3
"""为 Flutter Web 生成随包托管的最小字体子集（可离线重跑）。

背景
----
Flutter Web 在引擎硬编码的固定路径上按需拉取兜底字体（`fontFallbackBaseUrl`
+ `notosanssc/v36/<hash>.ttf`）。路径写死在引擎里，不能改文件名，只能原地替换内容。

原始 Noto Sans SC 字重约 17.8 MB（变量）/ 10.5 MB（静态），按 GB2312 全量子集后
仍有 2 MB，而本项目界面实际只用到 600 余个字符。

更隐蔽的一坑：早期母本只截取了汉字区 U+4E00–U+9FA0，**不含任何标点**。
于是界面上的 `、。，「」（），：；→` 全部落成 .notdef —— 渲染为一道全角空白，
句子黏连但不算难读，因此长期没被当成缺陷报出来。本脚本的母本包含 CJK 符号、
全角与通用标点区，并把字符集配对写进 test/ 守卫。

字体分工
--------
    Roboto  —— Latin 与 ASCII：数字、邮箱、模型名
    Noto SC —— CJK 汉字与中文标点（缺失时由 Flutter 回落到此处）

用法
----
    uv run --no-project --with fonttools python tool/subset_web_fonts.py
    uv run --no-project --with fonttools python tool/subset_web_fonts.py --check
    # 换母本（需要一份完整 Noto Sans SC；下载见下方 SOURCE 注释）
    uv run --no-project --with fonttools python tool/subset_web_fonts.py --refresh-master <完整字体.ttf>

产物
----
    web/fonts/notosanssc/v36/<hash>.ttf     引擎硬编码路径，内容为子集
    web/fonts/notosanssc/glyph-charset.txt  规范字符集（子集与守卫的单一事实源）
    web/fonts/roboto/v20/<hash>.ttf         Latin 主字体，去掉 TT hinting
    web/fonts/SUBSET_INFO.txt               产物哈希，供 test/ 校验配对关系

母本存放在 `tool/font_src/`，保证离线可复现：重建与 `--check` 都只依赖仓库内文件。

SOURCE（母本来源，2026-11 下载，OFL-1.1）
    Noto Sans SC 变量字体，Google Fonts 官方仓库 glyf 版本：
    https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf
    Roboto 静态 TTF：Flutter 引擎自带的 fonts/roboto/v20 资源，未做改动，仅去 hinting。
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import pathlib
import sys
import urllib.parse
import urllib.request

try:
    from fontTools import subset
    from fontTools.ttLib import TTFont
except ModuleNotFoundError:
    sys.exit("缺少 fontTools：uv run --no-project --with fonttools python tool/subset_web_fonts.py")

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "lib"
FONTS = ROOT / "web" / "fonts"
SRC = ROOT / "tool" / "font_src"
CHARSET_PATH = FONTS / "notosanssc" / "glyph-charset.txt"
INFO_PATH = FONTS / "SUBSET_INFO.txt"

# ── Flutter ≥3.45 的 v37 分片兜底 ──────────────────────────────────────────
# 3.45 起引擎把 Noto Sans SC 从「单文件 v36 ttf」换成「v37 多分片 .woff2」
# （按字形切割、浏览器按需加载）。分片文件名里的 hash 同样由引擎硬编码，
# 来源是该版本 flutter_web_sdk 里的 font_fallback_data.dart；内容只能原地替换。
# 我们用 lib/ 真实用字对每片求交集子集化，随包托管，避免引擎去 gstatic 拉全量
# 100MB 分片 —— 提供与 v36 单文件方案同等的最小字体链路。
#
# 每个分片 = NotoFont('Noto Sans SC N', 'notosanssc/v37/<hash>.<n>.woff2')。
# 96 片以内分片号有空洞（15-20、92-96 不存在），N 不代表连续；这里保 <hash>.<n> 原名。
V37_BASE_URL = "https://fonts.gstatic.com/s/"
WANT_EVERY_NTH_VERIFY = True  # 重建后强制校验覆盖（不依赖网络再次拉取）
SLICE_ROOT = FONTS / "notosanssc" / "v37"

# 母本覆盖的码位区间。汉字走 GB2312 全量（6763 字，覆盖全部简体常用字），
# 再加所有中文排版会用到的符号区，这样以后新增标点类文案不需要回头换母本。
#
# 注意不要按 U+4E00–U+9FA0 整块取：那是约 20900 个码位，比 GB2312 多出一万四千余字，
# 母本会从 2.5 MB 涨到 7 MB，而多出来的字本项目永远不会渲染。
MASTER_RANGES = [
    (0x3000, 0x303F),  # CJK 符号和标点：、。〈〉《》「」『』【】〜
    (0xFF00, 0xFFEF),  # 全角形式：（），：；！？＂＃￥％
    (0x2000, 0x206F),  # 通用标点：— – … · • ‥ ※ † ‡ § ¶
    (0x2190, 0x21FF),  # 箭头：← ↑ → ↓ ↔ ⇧ ⇩
    (0x2460, 0x24FF),  # 带圈数字：①②③
    (0x25A0, 0x25FF),  # 几何图形：■ □ ◆ ◇ ● ○ ▲ △ ▼ ▽
    (0x2600, 0x26FF),  # 杂项符号：★ ☆ ⚠
    (0x2700, 0x27BF),  # 装饰符号：✓ ✔ ✗ ✘
    (0x00A0, 0x00FF),  # Latin-1 补充：¥ · ÷
]

# 母本 → 产物。文件名里的 hash 由 Flutter 引擎硬编码，必须原样保留。
TARGETS = {
    "noto": {
        "src": SRC / "NotoSansSC-Regular.ttf",
        "dst": FONTS / "notosanssc" / "v36" / "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYxNbPzS5HE.ttf",
        "role": "CJK 兜底字体",
        "cjk_only": True,
    },
    "roboto": {
        "src": SRC / "Roboto-Regular.ttf",
        "dst": FONTS / "roboto" / "v20" / "KFOmCnqEu92Fr1Me5WZLCzYlKw.ttf",
        "role": "Latin 主字体",
        "cjk_only": False,
    },
}

# 安全垫：常见符号，避免以后文案里多一个「——」或「《》」就渲染成方块。
# 汉字一律由 lib/ 扫描得出，这里只补符号。
#
# 注意 ↕(U+2195) 与 ⓪(U+24EA)：Web 端 3.45+ 用的 Noto Sans SC v37 分片里
# **完全不存在**这两个字形（101 片全查过），只有旧 v36 单文件才有。为了让
# 「字符集」等于「3.45 生产实际能渲染的字符」，这两个符号不再进安全垫。
PAD = (
    "！＂＃＄％＆＇（）＊＋，－．／０１２３４５６７８９：；＜＝＞？＠［＼］＾＿｀｛｜｝～"
    "、。〃〈〉《》「」『』【】〔〕〖〗〝〞“”‘’"
    "¥￥€$¢£¤％‰°±×÷≈≠≤≥∞∑∏√∫"
    "—–‐‑‒―…·•‥※†‡§¶©®™←↑→↓↔⇧⇩✓✔✗✘★☆●○◆◇■□▲△▼▽"
    "①②③④⑤⑥⑦⑧⑨⑩"
)


# Flutter ≥3.45 引擎绕过的 v37 分片（无后续版本依赖时内建；有 --sdk 则自动提取）。
# 名称 = <引擎 hash>.<片号>.woff2，片号有空洞，排序必须在函数内按数字处理。
import re as _re
re_PART = _re.compile(r"^(.+)\.(\d+)\.woff2$")
SLICES: list[str] = [
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.4.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.5.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.6.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.21.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.22.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.23.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.24.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.25.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.26.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.27.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.28.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.29.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.30.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.31.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.32.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.33.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.34.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.35.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.36.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.37.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.38.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.39.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.40.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.41.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.42.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.43.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.44.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.45.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.46.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.47.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.48.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.49.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.50.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.51.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.52.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.53.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.54.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.55.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.56.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.57.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.58.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.59.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.60.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.61.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.62.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.63.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.64.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.65.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.66.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.67.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.68.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.69.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.70.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.71.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.72.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.73.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.74.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.75.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.76.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.77.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.78.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.79.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.80.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.81.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.82.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.83.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.84.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.85.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.86.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.87.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.88.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.89.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.90.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.91.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.97.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.98.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.99.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.100.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.101.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.102.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.103.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.104.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.105.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.106.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.107.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.108.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.109.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.110.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.111.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.112.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.113.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.114.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.115.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.116.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.117.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.118.woff2",
    "k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.119.woff2",
]


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def lib_chars() -> set[str]:
    """lib/ 中所有非 ASCII 字符——即界面真正可能渲染的汉字与符号。"""
    chars: set[str] = set()
    for p in LIB.rglob("*.dart"):
        for ch in p.read_text(encoding="utf-8"):
            if ord(ch) > 0x7F:
                chars.add(ch)
    return chars


def charset() -> str:
    """规范字符集 = lib/ 真实用字 ∪ ASCII ∪（安全垫 ∩ 字体链路实际能提供的符号）。

    安全垫按母本 cmap 过滤：把字体根本不存在的符号写进字符集，只会制造一个
    永远无法满足的红灯（Noto Sans SC 就没有 ✓✔✗✘ 这类 Dingbats）。
    """
    chars = lib_chars()
    chars.update(chr(c) for c in range(0x20, 0x7F))  # ASCII 可打印，交由 Roboto
    feasible = master_union()
    chars.update(ch for ch in PAD if ord(ch) in feasible)
    return "".join(sorted(chars))


def noto_charset(text: str) -> str:
    """Noto 只承担非 ASCII：拉丁与数字由 Roboto 负责，避免两处重复携带字形。"""
    return "".join(c for c in text if ord(c) > 0x7F)


def subset_options(*, hinting: bool, keep_layout: bool) -> subset.Options:
    opts = subset.Options()
    opts.layout_features = ["*"] if keep_layout else []
    if not keep_layout:
        opts.drop_tables += ["GSUB", "GPOS"]
    opts.hinting = hinting          # CanvasKit/Skia 不用 TT hinting
    opts.glyph_names = False        # post 表降为 format 3
    opts.notdef_outline = True
    opts.recommended_glyphs = True
    opts.name_IDs = ["*"]           # 保留 OFL 版权与许可声明（合规要求）
    opts.name_legacy = True
    opts.name_languages = ["*"]
    opts.recalc_bounds = False
    opts.canonical_order = True
    return opts


def build(src: pathlib.Path, dst: pathlib.Path, *, hinting: bool, keep_layout: bool,
          unicodes: list[int] | None = None, text: str | None = None) -> None:
    opts = subset_options(hinting=hinting, keep_layout=keep_layout)
    font = subset.load_font(str(src), opts)
    ss = subset.Subsetter(options=opts)
    if text is not None:
        ss.populate(text=text)
    else:
        ss.populate(unicodes=unicodes or [])
    ss.subset(font)
    dst.parent.mkdir(parents=True, exist_ok=True)
    subset.save_font(font, str(dst), opts)
    font.close()


def gb2312_hanzi() -> list[int]:
    """GB2312 两字节区的全部汉字（一级 3755 + 二级 3008 = 6763）。

    比按码位截取 CJK 区更贴近「简体常用字」这个概念，母本也小得多。
    """
    out: list[int] = []
    for hi in range(0xB0, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                out.append(ord(bytes([hi, lo]).decode("gb2312")))
            except UnicodeDecodeError:
                continue
    return out


def master_codepoints() -> list[int]:
    return gb2312_hanzi() + [cp for lo, hi in MASTER_RANGES for cp in range(lo, hi + 1)]


_MASTER_UNION: set[int] | None = None


def master_union() -> set[int]:
    """两个母本字体的 cmap 并集——即这套字体链路**理论上**能渲染的字符。"""
    global _MASTER_UNION
    if _MASTER_UNION is not None:
        return _MASTER_UNION
    covered: set[int] = set()
    for cfg in TARGETS.values():
        if not cfg["src"].exists():
            sys.exit(f"缺少母本 {cfg['src'].relative_to(ROOT)}（子集必须能离线复现）")
        font = TTFont(str(cfg["src"]), lazy=True)
        covered |= set(font.getBestCmap().keys())
        font.close()
    _MASTER_UNION = covered
    return covered


def refresh_master(full_font: pathlib.Path) -> None:
    """从一份完整的 Noto Sans SC 变量字体重新生成母本（一次性操作）。"""
    if not full_font.exists():
        sys.exit(f"找不到完整字体 {full_font}")
    from fontTools.varLib import instancer

    tmp = SRC / "_master-instance.ttf"
    tmp.parent.mkdir(parents=True, exist_ok=True)
    font = TTFont(str(full_font))
    axes = {a.axisTag: a for a in font["fvar"].axes}
    print(f"完整字体：{full_font.name}  {full_font.stat().st_size/1024/1024:.1f} MB  "
          f"glyphs={len(font.getGlyphOrder())} cmap={len(font.getBestCmap())}")
    print(f"变量轴：{[(k, v.minValue, v.defaultValue, v.maxValue) for k, v in axes.items()]}")
    instancer.instantiateVariableFont(font, {"wght": 400}, inplace=True, updateFontNames=True)
    font.save(str(tmp))
    font.close()
    print(f"已实例化 wght=400 → {tmp.name}  {tmp.stat().st_size/1024/1024:.1f} MB")

    dst = TARGETS["noto"]["src"]
    build(tmp, dst, hinting=False, keep_layout=True, unicodes=master_codepoints())
    tmp.unlink()
    print(f"母本已更新 → {dst.relative_to(ROOT)}  {dst.stat().st_size/1024/1024:.2f} MB"
          f"（{len(master_codepoints())} 个码位区间覆盖）")


def coverage(font_paths: list[pathlib.Path], text: str) -> list[str]:
    """并集覆盖：每个字符至少有一个产物字体提供字形，否则界面上就是方块。"""
    covered: set[int] = set()
    for p in font_paths:
        font = TTFont(str(p), lazy=True)
        covered |= set(font.getBestCmap().keys())
        font.close()
    return [ch for ch in text if ord(ch) not in covered and ch != "\n"]


# ── Flutter ≥3.45 的 v37 分片支持 ──────────────────────────────────────────
def slices_from_sdk(sdk_dir: pathlib.Path) -> list[str]:
    """从 flutter_web_sdk 的 font_fallback_data.dart 提取 notosanssc v37 分片路径。

    这份文件由 flutter 构建时生成（dev/roll_fallback_fonts.dart），是排序后的
    NotoFont 清单，分片号就是浏览器按需取字的关键。任一 Flutter 升级若改了
    hash 或分片切法，传新的 SDK 路径即可自动跟进，不靠脚本硬编码。
    """
    data = sdk_dir / "lib" / "ui" / "src" / "engine" / "font_fallback_data.dart"
    if not data.exists():
        sys.exit(f"找不到字体回退清单 {data}（--sdk 应指向 flutter_web_sdk 目录）")
    src = data.read_text(encoding="utf-8")
    paths = []
    for m in __import__("re").finditer(r"'([^']*notosanssc[^']*)'", src):
        p = m.group(1)
        if "/v37/" in p:
            paths.append(p)  # 保留 notosanssc/v37/ 前缀，URL 与产物名都用它
    if not paths:
        sys.exit(f"{data} 里没有 notosanssc/v37 分片——该 SDK 版本不切分片，不需要本功能")
    return paths


def _rel(p: str) -> str:
    """把分片名规范成引擎请求的完整相对路径（notosanssc/v37/<file>）。

    内置清单只写文件名（省 97 行重复前缀），SDK 提取出来是完整路径，两者在这里统一。
    """
    return p if "/" in p else "notosanssc/v37/" + p


def _base(p: str) -> str:
    return p.rsplit("/", 1)[-1]


def fetch_slice(rel: str) -> pathlib.Path:
    """下载一个 v37 分片到临时目录并返回路径（若已存在则直接复用）。"""
    name = _base(rel)
    tmp = SRC / "_slices" / name
    if tmp.exists():
        return tmp
    tmp.parent.mkdir(parents=True, exist_ok=True)
    url = V37_BASE_URL + urllib.parse.quote(_rel(rel), safe="/")
    print(f"  下载 {name}")
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) "
                      "Chrome/126.0 Safari/537.36",
        "Accept": "*/*",
    })
    with urllib.request.urlopen(req, timeout=60) as resp:
        tmp.write_bytes(resp.read())
    return tmp


def slices_needed() -> set[str]:
    """需保留的分片（返回完整相对路径）：与 lib/ 非 ASCII 用字有交集的分片。

    分片按字形切割，每个字符只落在一片里；只有「该片里有我们要用的字形」才值得
    随包托管。无编号闭环片（字体 PM 签名）不带字形，一律跳过。
    """
    wanted_cps = {ord(c) for c in noto_charset(charset())}
    keep: set[str] = set()
    for raw in SLICES:
        rel = _rel(raw)
        # 无编号片（如 <hash>.woff2 的 FrYtHbQ）也是引擎真实会请求的片——
        # 它装着 ‘ ’ † 这类排版符号，跳过它会让引号在页面上变方块。
        src = fetch_slice(rel)
        font = TTFont(str(src), lazy=True)
        cmap = set(font.getBestCmap().keys())
        font.close()
        if cmap & wanted_cps:
            keep.add(rel)
    return keep


def refresh_slices(sdk_dir: pathlib.Path | None = None) -> int:
    """重新生成 v37 分片集合（从 SDK 清单下载 → 求交集子集化 → 写入 v37/）。"""
    global SLICES
    if sdk_dir is not None:
        SLICES = slices_from_sdk(sdk_dir)
    elif not SLICES:
        sys.exit("--sdk 未指定且未内置分片清单，无法生成 v37 分片")

    text = charset()
    keep = slices_needed()
    print(f"根据清单 {len(SLICES)} 个 v37 分片，其中 {len(keep)} 个含本项目用字。")

    SLICE_ROOT.mkdir(parents=True, exist_ok=True)
    # 清掉上一次生成的多余分片，避免引擎期望清单变化后留下过期文件
    keep_names = {_base(r) for r in keep}
    for stale in SLICE_ROOT.glob("*.woff2"):
        if stale.name not in keep_names:
            stale.unlink()
    for rel in sorted(keep, key=lambda r: _slice_num(_base(r))):
        src = fetch_slice(rel)
        dst = SLICE_ROOT / _base(rel)
        # 只保留本片 与 本项目用字 的交集，进一步压小体积
        rd = TTFont(str(src), lazy=True)
        cmap = set(rd.getBestCmap().keys())
        rd.close()
        use = sorted({ord(c) for c in text})  # 字符集全集，按片裁剪
        want_cp = {cp for cp in use if cp in cmap}
        build(src, dst, hinting=False, keep_layout=True, unicodes=sorted(want_cp))
    total = sum((SLICE_ROOT / _base(r)).stat().st_size for r in keep)
    print(f"v37 分片已生成 {len(keep)} 片，合计 {total/1024:.0f} KB "
          f"→ {SLICE_ROOT.relative_to(ROOT)}")
    upsert_slice_info()
    return check()


def slice_info_lines() -> list[str]:
    """v37 分片的记录行：片数、总字节、每片名与字节。供 test/ 守卫生效。"""
    files = sorted(SLICE_ROOT.glob("*.woff2"))
    if not files:
        return []
    return [
        f"slices.count={len(files)}",
        f"slices.bytes={sum(f.stat().st_size for f in files)}",
        f"slices.dir={SLICE_ROOT.relative_to(ROOT)}",
        *(f"slices.file.{f.name}={f.stat().st_size}" for f in files),
    ]


def upsert_slice_info() -> None:
    """只替换 SUBSET_INFO.txt 里的 slices.* 段，其它行原样保留。"""
    if not INFO_PATH.exists():
        return
    head = [ln for ln in INFO_PATH.read_text(encoding="utf-8").splitlines()
            if not ln.startswith("slices.")]
    INFO_PATH.write_text("\n".join(head + slice_info_lines()) + "\n", encoding="utf-8")


def _slice_num(name: str) -> int:
    m = re_PART.match(_base(name))
    return int(m.group(2)) if m else 0


def parse_info() -> dict[str, str]:
    if not INFO_PATH.exists():
        return {}
    out = {}
    for line in INFO_PATH.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


def check() -> int:
    problems: list[str] = []
    info = parse_info()
    if not info:
        problems.append(f"缺少 {INFO_PATH.relative_to(ROOT)}——请先运行本脚本重建子集")

    committed = set()
    if not CHARSET_PATH.exists():
        problems.append(f"缺少 {CHARSET_PATH.relative_to(ROOT)}")
    else:
        committed = set(CHARSET_PATH.read_text(encoding="utf-8").rstrip("\n"))
        missing = sorted(lib_chars() - committed)
        if missing:
            problems.append("lib/ 里出现了字符集之外的字符（会渲染成方块）：" + "".join(missing))
        if committed != set(charset()):
            problems.append("glyph-charset.txt 与「lib/ 扫描 + 标点安全垫」的结果不一致，请重跑本脚本")

    for name, cfg in TARGETS.items():
        if not cfg["dst"].exists():
            problems.append(f"{name}: 缺少产物 {cfg['dst'].relative_to(ROOT)}")
            continue
        recorded, actual = info.get(f"{name}.sha256"), sha256(cfg["dst"])
        if recorded and recorded != actual:
            problems.append(f"{name}: 产物哈希与 {INFO_PATH.name} 不匹配"
                            f"（记录 {recorded[:12]}，实际 {actual[:12]}）——字体被手工改过或子集未重建")

    live = [cfg["dst"] for cfg in TARGETS.values() if cfg["dst"].exists()]
    # 3.45+ 的 web 构建走 v37 分片（web 上引擎不再请求 v36 ttf）；把它们并入覆盖集，
    # 这样「v36 桌面」与「v37 web」两套链路任一满足 lib 用字都算通过。
    slices = sorted(SLICE_ROOT.glob("*.woff2"))
    recorded_slices = {k[len("slices.file."):]: int(v)
                       for k, v in info.items() if k.startswith("slices.file.")}
    actual_slices = {f.name: f.stat().st_size for f in slices}
    if recorded_slices and recorded_slices != actual_slices:
        only_rec = sorted(set(recorded_slices) - set(actual_slices))[:3]
        only_act = sorted(set(actual_slices) - set(recorded_slices))[:3]
        changed = sorted(n for n in set(recorded_slices) & set(actual_slices)
                         if recorded_slices[n] != actual_slices[n])[:3]
        problems.append(
            "v37 分片与 SUBSET_INFO.txt 记录不一致"
            f"（缺 {only_rec} 多 {only_act} 变 {changed}）——分片被手工改过或未重跑 --refresh-slices")
    live += slices
    if live and committed:
        missing = coverage(live, "".join(sorted(committed)))
        if missing:
            problems.append(f"产物字体都不覆盖 {len(missing)} 个字符，界面上会是空白：{''.join(missing[:60])}")

    # 单独校验 v37：3.45+ 的浏览器只请求分片，v36 ttf 根本不在请求链上。
    # 少了这条断言，v36 会把 v37 的缺口一起「证明」为已覆盖，线上却是方块。
    if slices:
        lib_missing = coverage(slices, "".join(sorted(lib_chars())))
        if lib_missing:
            problems.append(f"v37 分片缺 {len(lib_missing)} 个 lib/ 用字（v36 掩盖不了）："
                            f"{''.join(lib_missing[:60])}")

    if problems:
        print("字体子集校验失败：")
        for p in problems:
            print(f"  ✗ {p}")
        print("\n修复：uv run --no-project --with fonttools python tool/subset_web_fonts.py")
        return 1

    total = sum(TARGETS[n]["dst"].stat().st_size for n in TARGETS)
    total += sum(p.stat().st_size for p in slices)
    print(f"字体子集校验通过：字符集 {len(committed)} 字符全部有字形，"
          f"产物 {total/1024:.0f} KB（含 v37 分片 {len(slices)} 片），哈希与记录一致。")
    return 0


def rebuild() -> int:
    for name, cfg in TARGETS.items():
        if not cfg["src"].exists():
            sys.exit(f"缺少母本 {cfg['src'].relative_to(ROOT)}（子集必须能离线复现）")

    text = charset()
    rows: list[tuple[str, str, int, int]] = []
    for name, cfg in TARGETS.items():
        before = cfg["src"].stat().st_size
        if cfg["cjk_only"]:
            build(cfg["src"], cfg["dst"], hinting=False, keep_layout=True,
                  text=noto_charset(text))
        else:
            # Latin 主字体保留母本全部 cmap 覆盖：邮箱、模型名一旦缺字形无处回落，
            # 不值得为几十 KB 冒这个风险。
            cmap = sorted(TTFont(str(cfg["src"]), lazy=True).getBestCmap().keys())
            build(cfg["src"], cfg["dst"], hinting=False, keep_layout=False, unicodes=cmap)
        rows.append((name, cfg["role"], before, cfg["dst"].stat().st_size))

    CHARSET_PATH.parent.mkdir(parents=True, exist_ok=True)
    CHARSET_PATH.write_text(text, encoding="utf-8")

    lines = [
        "# 由 tool/subset_web_fonts.py 生成，请勿手工编辑。",
        "# 校验：uv run --no-project --with fonttools python tool/subset_web_fonts.py --check",
        "#       flutter test test/web_font_subset_test.dart",
        f"charset.chars={len(text)}",
        f"charset.sha256={sha256(CHARSET_PATH)}",
    ]
    print(f"{'字体':<8} {'角色':<14} {'母本':>10} {'随包产物':>10} {'降幅':>8} {'gzip':>9}")
    print("-" * 70)
    for name, role, before, after in rows:
        cut = f"−{(1 - after / before) * 100:.1f}%" if before else "—"
        gz = len(gzip.compress(TARGETS[name]["dst"].read_bytes(), 9))
        print(f"{name:<8} {role:<14} {before/1024:9.1f}K {after/1024:9.1f}K {cut:>8} {gz/1024:8.1f}K")
        lines.append(f"{name}.src={TARGETS[name]['src'].relative_to(ROOT)}")
        lines.append(f"{name}.src.sha256={sha256(TARGETS[name]['src'])}")
        lines.append(f"{name}.dst={TARGETS[name]['dst'].relative_to(ROOT)}")
        lines.append(f"{name}.dst.sha256={sha256(TARGETS[name]['dst'])}")
        lines.append(f"{name}.bytes={after}")
    lines.extend(slice_info_lines())
    INFO_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("-" * 62)
    print(f"字符集 {len(text)} 字符 → {CHARSET_PATH.relative_to(ROOT)}")
    print(f"产物记录 → {INFO_PATH.relative_to(ROOT)}")
    print()
    print("⚠ 这两个 ttf 的文件名由引擎在构建时写死，内容换了名字也不会变，而它们带着")
    print("  max-age=14400 —— 直接部署的话，回访用户最长 4 小时还会拿到旧字体。")
    print("  部署后去 Cloudflare 清一次缓存（Caching → Configuration → Purge Cache）：")
    print("    /")
    print("    /main.dart.js")
    print("    /flutter_bootstrap.js")
    for name in TARGETS:
        print(f"    /{TARGETS[name]['dst'].relative_to(ROOT / 'web')}")
    print("  或者直接 Purge Everything。浏览器自己那份删不掉（10 分钟，可接受）。")
    return check()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="只校验，不写文件")
    ap.add_argument("--refresh-master", metavar="完整字体.ttf",
                    help="从完整 Noto Sans SC 变量字体重建 tool/font_src 母本")
    ap.add_argument("--refresh-slices", action="store_true",
                    help="重建 3.45+ 的 v37 分片（从 --sdk 或内置清单取片名，下载后子集化写入 v37/）")
    ap.add_argument("--sdk", metavar="flutter_web_sdk路径",
                    help="从该版本的 font_fallback_data.dart 提取 v37 分片名（Flutter 升级后 hash 变了用这个）")
    args = ap.parse_args()
    if args.refresh_master:
        refresh_master(pathlib.Path(args.refresh_master))
        return rebuild()
    if args.refresh_slices:
        return refresh_slices(pathlib.Path(args.sdk) if args.sdk else None)
    return check() if args.check else rebuild()


if __name__ == "__main__":
    sys.exit(main())

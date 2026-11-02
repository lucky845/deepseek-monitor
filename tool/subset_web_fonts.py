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
PAD = (
    "！＂＃＄％＆＇（）＊＋，－．／０１２３４５６７８９：；＜＝＞？＠［＼］＾＿｀｛｜｝～"
    "、。〃〈〉《》「」『』【】〔〕〖〗〝〞“”‘’"
    "¥￥€$¢£¤％‰°±×÷≈≠≤≥∞∑∏√∫"
    "—–‐‑‒―…·•‥※†‡§¶©®™←↑→↓↔↕⇧⇩✓✔✗✘★☆●○◆◇■□▲△▼▽"
    "①②③④⑤⑥⑦⑧⑨⑩⓪"
)


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
    if live and committed:
        missing = coverage(live, "".join(sorted(committed)))
        if missing:
            problems.append(f"两个产物字体都不覆盖 {len(missing)} 个字符，界面上会是空白：{''.join(missing[:60])}")

    if problems:
        print("字体子集校验失败：")
        for p in problems:
            print(f"  ✗ {p}")
        print("\n修复：uv run --no-project --with fonttools python tool/subset_web_fonts.py")
        return 1

    total = sum(TARGETS[n]["dst"].stat().st_size for n in TARGETS)
    print(f"字体子集校验通过：字符集 {len(committed)} 字符全部有字形，"
          f"产物 {total/1024:.0f} KB，哈希与记录一致。")
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
    args = ap.parse_args()
    if args.refresh_master:
        refresh_master(pathlib.Path(args.refresh_master))
        return rebuild()
    return check() if args.check else rebuild()


if __name__ == "__main__":
    sys.exit(main())

# 字体源文件

`tool/subset_web_fonts.py` 的输入。这些 `.ttf` **不入库**（见仓库根 `.gitignore`），
因为原始文件合计 2.4MB，而子集产物只有 132KB，已经提交在 `web/fonts/` 下。
只有需要重新生成子集时才要在这里放源文件。

| 文件 | 来源 |
| --- | --- |
| `NotoSansSC-Regular.ttf` | Google Fonts — Noto Sans SC v36 Regular（2.2MB） |
| `Roboto-Regular.ttf` | Google Fonts — Roboto v20 Regular（167KB） |

## 重新获取

两个文件就是 `web/fonts/` 里那两个子集文件的前身，文件名和内容与 Google Fonts 上的一致：

- Noto Sans SC v36：`https://fonts.gstatic.com/s/notosanssc/v36/k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYxNbPzS5HE.ttf`
- Roboto v20：`https://fonts.gstatic.com/s/roboto/v20/KFOmCnqEu92Fr1Me5WZLCzYlKw.ttf`

直接 `curl -o` 到本目录即可，文件名保持上表那样。

## 重新生成子集

```bash
python3 tool/subset_web_fonts.py
```

脚本会扫描 `lib/` 里真实用到的字符，重裁两个 ttf，覆盖 `web/fonts/` 下的产物，
并更新 `web/fonts/SUBSET_INFO.txt` 和 `web/fonts/notosanssc/glyph-charset.txt`。

改完跑一遍守护测试，它会逐字验证没有缺字形：

```bash
fvm flutter test test/web_font_subset_test.dart
```

## 注意

字体文件名里的 hash 由 Flutter 引擎写死，**内容换了名字也不会变**。
所以部署后回访用户最长 4 小时内仍会看到旧字体，需要到 Cloudflare 清一次缓存
（`Caching → Configuration → Purge Cache`）。清单见 `docs/web-and-proxy.md`。
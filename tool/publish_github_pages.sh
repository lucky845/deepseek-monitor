#!/usr/bin/env bash
# 建仓 → 推送 → 开启 GitHub Pages → 等一次部署跑完。
#
# 前置条件只有一条：`gh auth login` 已经成功（脚本会自己检查）。
# 用法：
#   bash tool/publish_github_pages.sh                 # 仓库名默认 deepseek-monitor
#   REPO_NAME=my-repo bash tool/publish_github_pages.sh
set -euo pipefail

REPO_NAME="${REPO_NAME:-deepseek-monitor}"
BRANCH="${BRANCH:-main}"
cd "$(dirname "$0")/.."

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 1. 认证
say "检查 gh 认证"
OWNER="$(gh api user --jq .login 2>/dev/null)" \
  || die "gh 未认证。先跑：gh auth login -h github.com -p https -w"
[ -n "$OWNER" ] || die "gh api user 没返回登录名"
echo "  已认证：$OWNER"

# 2. 仓库
FULL="$OWNER/$REPO_NAME"
say "准备仓库 $FULL"
if gh repo view "$FULL" >/dev/null 2>&1; then
  echo "  仓库已存在，跳过创建"
else
  gh repo create "$FULL" --public \
    --description "DeepSeek 余额与用量的跨平台监控面板（Flutter，六端）" \
    --disable-wiki
  echo "  已创建（public）"
fi

# remote 指向它（幂等）
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "https://github.com/$FULL.git"
else
  git remote add origin "https://github.com/$FULL.git"
fi
echo "  origin -> $(git remote get-url origin)"

# 3. 推送
say "推送 $BRANCH"
git push -u origin "$BRANCH"

# 4. Pages 源设为 GitHub Actions
say "把 Pages 的源设为 GitHub Actions"
if gh api "repos/$FULL/pages" >/dev/null 2>&1; then
  gh api --method PUT "repos/$FULL/pages" -f build_type=workflow >/dev/null
  echo "  已更新现有 Pages 配置"
else
  gh api --method POST "repos/$FULL/pages" -f build_type=workflow >/dev/null
  echo "  已启用 Pages（build_type=workflow）"
fi

# 5. 等部署
say "等待构建工作流开始"
sleep 5
RUN_ID=""
for _ in $(seq 1 20); do
  RUN_ID="$(gh run list --repo "$FULL" --workflow=build.yml --branch "$BRANCH" \
            --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
  [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && break
  sleep 6
done
[ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] || die "没看到工作流启动，去 Actions 页面看一眼"

echo "  run: https://github.com/$FULL/actions/runs/$RUN_ID"
say "跟踪部署（verify → build-web → deploy-web，几分钟）"
gh run watch "$RUN_ID" --repo "$FULL" --exit-status \
  || die "工作流失败，看日志：gh run view $RUN_ID --repo $FULL --log-failed"

# 6. 回报
URL="https://$OWNER.github.io/$REPO_NAME/"
say "完成"
echo "  站点：$URL"
echo "  仓库：https://github.com/$FULL"
echo
echo "  首次发布 Pages 需要几十秒生效，之后刷新即可。"

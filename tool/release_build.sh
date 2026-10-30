#!/usr/bin/env bash
# =============================================================================
# release_build.sh — DeepSeek Monitor 分端打包脚本
#
# 用途：在本机上为各平台打包，将产物收集到 dist/ 目录，方便一次性
#       上传到 GitHub Release。Web 端继续由 GitHub Actions 部署到 Pages，
#       不在此脚本中处理。
#
# 用法：
#   ./tool/release_build.sh              # 全平台打包（Android/iOS/macOS/Linux）
#   ./tool/release_build.sh android      # 仅打包 Android
#   ./tool/release_build.sh ios          # 仅打包 iOS（模拟器，--no-codesign）
#   ./tool/release_build.sh macos        # 仅打包 macOS
#   ./tool/release_build.sh linux        # 仅打包 Linux
#   ./tool/release_build.sh clean        # 清理 dist/ 和 build/
#
# 环境要求：
#   - Flutter SDK 已加入 PATH（或设置 FLUTTER_ROOT）
#   - iOS/macOS 构建需 Xcode 工具链
#   - Android 构建需 Android SDK + 兼容的 JDK
#   - Linux 构建需 clang/cmake/ninja/gtk
# =============================================================================
set -euo pipefail

# --- 路径定义 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"
FLUTTER="${FLUTTER:-/tmp/flutter/bin/flutter}"

# --- 颜色输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# --- 检查 Flutter ---
check_flutter() {
  if ! command -v "$FLUTTER" >/dev/null 2>&1; then
    error "Flutter 未找到: $FLUTTER（请设置 FLUTTER_ROOT 或加入 PATH）"
    exit 1
  fi
  info "Flutter: $($FLUTTER --version 2>/dev/null | head -1)"
}

# --- 清理 ---
do_clean() {
  info "清理 dist/ 和 build/ ..."
  rm -rf "$DIST_DIR"
  rm -rf "$PROJECT_ROOT/build"
  info "清理完成。"
}

# --- 创建 dist 目录 ---
prepare_dist() {
  mkdir -p "$DIST_DIR"
}

# --- Android ---
build_android() {
  info "=== 打包 Android (APK, release) ==="
  cd "$PROJECT_ROOT"
  if ! "$FLUTTER" build apk --release; then
    warn "Android Gradle 构建失败"
    return 1
  fi
  local apk="$PROJECT_ROOT/build/app/outputs/flutter-apk/app-release.apk"
  if [[ -f "$apk" ]]; then
    cp "$apk" "$DIST_DIR/deepseek_monitor-android.apk"
    info "Android APK -> dist/deepseek_monitor-android.apk"
  else
    warn "Android APK 未找到: $apk"
    return 1
  fi
}

# --- iOS ---
build_ios() {
  info "=== 打包 iOS (模拟器, release, --no-codesign) ==="
  cd "$PROJECT_ROOT"
  if ! "$FLUTTER" build ios --release --no-codesign; then
    warn "iOS 构建失败"
    return 1
  fi
  local app="$PROJECT_ROOT/build/ios/iphoneos/Runner.app"
  if [[ -d "$app" ]]; then
    cp -r "$app" "$DIST_DIR/DeepSeekMonitor-iOS.app"
    info "iOS App -> dist/DeepSeekMonitor-iOS.app"
  else
    warn "iOS App 未找到: $app"
    return 1
  fi
}

# --- macOS ---
build_macos() {
  info "=== 打包 macOS (release) ==="
  cd "$PROJECT_ROOT"
  if ! "$FLUTTER" build macos --release; then
    warn "macOS 构建失败"
    return 1
  fi
  local app="$PROJECT_ROOT/build/macos/Build/Products/Release/deepseek_monitor.app"
  if [[ -d "$app" ]]; then
    cp -r "$app" "$DIST_DIR/DeepSeekMonitor-macOS.app"
    info "macOS App -> dist/DeepSeekMonitor-macOS.app"
  else
    warn "macOS App 未找到: $app"
    return 1
  fi
}

# --- Linux ---
build_linux() {
  info "=== 打包 Linux (release bundle) ==="
  cd "$PROJECT_ROOT"
  if ! "$FLUTTER" build linux --release; then
    warn "Linux 构建失败"
    return 1
  fi
  local bundle="$PROJECT_ROOT/build/linux/x64/release/bundle"
  if [[ -d "$bundle" ]]; then
    cp -r "$bundle" "$DIST_DIR/deepseek_monitor-linux"
    info "Linux bundle -> dist/deepseek_monitor-linux/"
  else
    warn "Linux bundle 未找到: $bundle"
    return 1
  fi
}

# --- Windows ---
build_windows() {
  info "=== 打包 Windows (release) ==="
  cd "$PROJECT_ROOT"
  if ! "$FLUTTER" build windows --release; then
    warn "Windows 构建失败"
    return 1
  fi
  local exe="$PROJECT_ROOT/build/windows/x64/runner/Release/deepseek_monitor.exe"
  if [[ -f "$exe" ]]; then
    cp "$exe" "$DIST_DIR/deepseek_monitor-windows.exe"
    info "Windows EXE -> dist/deepseek_monitor-windows.exe"
  else
    warn "Windows EXE 未找到: $exe"
    return 1
  fi
}

# --- 平台构建（失败不中断，记录后继续） ---
build_platform() {
  local name="$1"; shift
  info ">>> 开始构建平台: $name"
  if "$@"; then
    info ">>> 平台 $name 构建成功"
    return 0
  else
    local code=$?
    warn ">>> 平台 $name 构建失败 (exit $code)，跳过，继续下一平台"
    return $code
  fi
}

# --- 主流程 ---
main() {
  local target="${1:-all}"

  check_flutter

  local failed=()

  case "$target" in
    clean)
      do_clean
      ;;
    all)
      prepare_dist
      build_platform android build_android || failed+=("android")
      build_platform ios build_ios || failed+=("ios")
      build_platform macos build_macos || failed+=("macos")
      build_platform linux build_linux || failed+=("linux")
      build_platform windows build_windows || failed+=("windows")
      ;;
    android)
      prepare_dist
      build_android || failed+=("android")
      ;;
    ios)
      prepare_dist
      build_ios || failed+=("ios")
      ;;
    macos)
      prepare_dist
      build_macos || failed+=("macos")
      ;;
    linux)
      prepare_dist
      build_linux || failed+=("linux")
      ;;
    windows)
      prepare_dist
      build_windows || failed+=("windows")
      ;;
    *)
      error "未知目标: $target"
      echo "用法: $0 [all|android|ios|macos|linux|windows|clean]"
      exit 1
      ;;
  esac

  echo ""
  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "打包部分完成。以下平台失败：${failed[*]}"
    info "产物目录: $DIST_DIR"
    ls -lh "$DIST_DIR" 2>/dev/null || true
    exit 1
  else
    info "打包全部完成。产物目录: $DIST_DIR"
    ls -lh "$DIST_DIR" 2>/dev/null || true
  fi
}

main "$@"

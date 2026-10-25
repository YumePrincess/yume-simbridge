#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/Mac/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_AUTO_UPDATE=1
cd "$(dirname "$0")/.."
MODE="${1:---check}"
[ "$(uname -m)" = arm64 ] || { echo 'Apple M-series chips are required'; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || { echo 'macOS 26 or later is required'; exit 1; }

check() {
 printf '[1/4] 检查 macOS 与编译工具\n'
 [ "$(uname -s)" = Darwin ] || { echo '需要 macOS'; return 1; }
 xcode-select -p >/dev/null || { echo '请先运行 xcode-select --install'; return 1; }
 command -v swiftc >/dev/null
 printf '[2/4] 检查 Python、libusb 与 pyusb\n'
 command -v python3.12 >/dev/null || { echo '缺少 Python 3.12'; return 1; }
 [ -f /opt/homebrew/lib/libusb-1.0.dylib ] || [ -f /usr/Mac/lib/libusb-1.0.dylib ] || { echo '缺少 libusb'; return 1; }
 [ -x Mac/.venv/bin/python ] && Mac/.venv/bin/python -c 'import usb.core' || { echo '缺少项目 Python 环境 / pyusb'; return 1; }
 printf '[3/4] 检查 Go 与 Git\n'
 command -v go >/dev/null && command -v git >/dev/null
 printf '[4/4] 依赖已就绪；客户端运行不依赖 Node.js\n'
}
install() {
 command -v brew >/dev/null || { echo '请先从 https://brew.sh 安装 Homebrew，再重新运行此向导'; exit 1; }
 xcode-select -p >/dev/null || { echo '请先运行 xcode-select --install，完成后重新运行向导'; exit 1; }
 echo '[1/4] 安装或确认 Python、Go、libusb'
 brew install python@3.12 go libusb
 echo '[2/4] 安装隔离的 Python 依赖'
 [ -x Mac/.venv/bin/python ] || python3.12 -m venv Mac/.venv
 Mac/.venv/bin/python -m pip install -r Mac/requirements.txt
 echo '[3/4] 构建 Go、CoreAudio 和原生客户端'
 scripts/build-mac.sh --install
 echo '[4/4] 安装完成；请在向导中重启客户端'
}
verify_repo() {
 local remote
 remote=$(git remote get-url origin)
 case "$remote" in https://github.com/YumePrincess/yume-simhub.git|git@github.com:YumePrincess/yume-simhub.git) ;; *) echo '更新已停止：origin 不是指定项目仓库'; exit 1;; esac
 [ "$(git branch --show-current)" = main ] || { echo '更新已停止：仅 main 分支可自动更新'; exit 1; }
}
case "$MODE" in
 --check) check ;;
 --install) install ;;
 --check-update)
  verify_repo
  git fetch origin main
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]; then echo '当前项目已是最新版本'; else git log --oneline HEAD..origin/main; echo '发现项目更新，可安装更新'; fi
  ;;
 --update)
  verify_repo
  [ -z "$(git status --porcelain --untracked-files=normal)" ] || { echo '更新已停止：项目有本地修改，请先提交或自行保存。不会覆盖本地文件。'; exit 1; }
  echo '[1/4] 获取 GitHub main 更新'
  git fetch origin main
  git merge --ff-only origin/main
  install
  ;;
 *) echo '参数：--check / --install / --check-update / --update'; exit 2;;
esac

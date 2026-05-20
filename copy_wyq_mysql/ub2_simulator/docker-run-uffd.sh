#!/bin/bash
# 快速运行 uffd_shm_demo 的 Docker 脚本

IMAGE_NAME="${1:-ubuntu:22.04}"  # 默认使用 Ubuntu 22.04
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "使用镜像: $IMAGE_NAME"
echo "工作目录: $SCRIPT_DIR"

# 检查是否在 Docker 容器内
if [ -f /.dockerenv ]; then
    echo "警告: 您已经在 Docker 容器内！"
    echo "请使用以下命令之一重新启动容器："
    echo ""
    echo "方法 1 (privileged):"
    echo "  docker run --privileged -it -v $SCRIPT_DIR:/workspace -w /workspace $IMAGE_NAME"
    echo ""
    echo "方法 2 (cap-add, 推荐):"
    echo "  docker run --cap-add=SYS_PTRACE --cap-add=SYS_ADMIN -it -v $SCRIPT_DIR:/workspace -w /workspace $IMAGE_NAME"
    echo ""
    exit 1
fi

# 检查可执行文件是否存在
if [ ! -f "$SCRIPT_DIR/uffd_shm_demo" ]; then
    echo "错误: 找不到 uffd_shm_demo 可执行文件"
    echo "请先编译: make uffd_shm_demo 或 gcc -o uffd_shm_demo uffd_shm_demo.c"
    exit 1
fi

# 运行容器（使用 privileged 模式）
echo "启动 Docker 容器（privileged 模式）..."
docker run --privileged --rm \
    -v "$SCRIPT_DIR:/workspace" \
    -w /workspace \
    "$IMAGE_NAME" \
    ./uffd_shm_demo

exit_code=$?

if [ $exit_code -ne 0 ]; then
    echo ""
    echo "如果遇到权限错误，请尝试："
    echo "  1. 确保 Docker 有足够权限"
    echo "  2. 检查内核版本是否支持 userfaultfd (需要 4.3+)"
    echo "  3. 查看 DOCKER_USERFAULTFD.md 了解更多选项"
fi

exit $exit_code



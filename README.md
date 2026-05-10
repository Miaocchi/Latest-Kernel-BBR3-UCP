# 最新内核 BBR3 + Cloudflare TCP 优化 + UCP

这个仓库用于自动构建最新 stable Linux 内核，并集成三类 TCP 相关改动：

- Google BBRv3
- Cloudflare `tcp_collapse_max_bytes` 接收队列优化
- UCP TCP 拥塞控制模块

构建流程基于 GitHub Actions。工作流会从 kernel.org 获取当前最新 stable 版本，拉取对应 Linux stable 源码，切换到 Google BBRv3 分支，应用 Cloudflare TCP patch 和 UCP 集成脚本，最后为 `x86_64` 和 `arm64` 构建 Debian 内核包。

## 集成内容

### Google BBRv3

工作流会拉取：

```text
https://github.com/google/bbr
```

并 checkout `google-bbr/v3`，最终系统里 BBRv3 的拥塞控制名称仍然是：

```text
bbr
```

### Cloudflare TCP Collapse 优化

本仓库集成 Cloudflare 文章中提到的 TCP 接收队列 collapse 优化，对应 sysctl：

```text
net.ipv4.tcp_collapse_max_bytes
```

默认值为 `0`，表示保持 Linux 原始行为。

设置为非零值后，当 TCP 接收内存占用超过这个阈值时，内核会跳过耗时的 receive queue collapse 逻辑，避免大接收队列在满载时造成明显延迟尖峰。

示例：

```bash
sudo sysctl -w net.ipv4.tcp_collapse_max_bytes=6291456
```

持久化：

```bash
echo 'net.ipv4.tcp_collapse_max_bytes=6291456' | sudo tee /etc/sysctl.d/99-tcp-collapse.conf
sudo sysctl --system
```

### Cloudflare 风格默认 TCP 行为

仓库额外提供 `scripts/apply-cloudflare-tcp-defaults.sh`，构建时会把部分 TCP 默认值改成更偏向高吞吐、低延迟的配置：

```text
net.ipv4.tcp_congestion_control = ucp
net.core.default_qdisc = fq
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_collapse_max_bytes = 6291456
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 16384 67108864
```

说明：

- UCP 作为默认拥塞控制算法，并内建进内核，不需要手动 `modprobe`。
- BBRv3 仍然内建可用，可以通过 sysctl 切换到 `bbr`。
- 默认 qdisc 从 `fq_codel` 改为 `fq`，为 BBR pacing 提供更合适的队列调度。
- SACK 默认开启，提升长距离和轻微丢包链路的恢复效率。
- TCP Fast Open 默认开启客户端和服务端能力。
- `tcp_notsent_lowat` 限制应用未发送队列，减少应用层堆积导致的延迟。
- `tcp_adv_win_scale=-2` 减少自动调优为接收窗口预留的比例，降低 bufferbloat 风险。
- `tcp_rmem/tcp_wmem` 保留自动调优，但把最大值提高到 64 MiB，适合高 BDP 链路。

### UCP 拥塞控制

UCP 源码来自：

```text
https://github.com/liulilittle/ucp/tree/main/linux
```

构建时会复制 `linux/tcp_ucp.c` 到内核源码的 `net/ipv4/tcp_ucp.c`，并注册：

```text
CONFIG_TCP_CONG_UCP=y
```

UCP 默认内建进内核，并作为默认拥塞控制算法，不需要手动加载模块。

## Kernel 7.0 API 兼容

UCP 原始代码面向旧内核 TCP API。仓库里的 `scripts/integrate-ucp.sh` 会根据目标内核的 `include/net/tcp.h` 自动修正 `tcp_congestion_ops` 差异：

- `cong_control` 新增 `u32 ack, int flags` 参数。
- 旧的 `min_tso_segs` 回调改为目标内核可用的 `tso_segs` 回调。

这样可以避免 UCP 在新内核上因为函数签名不匹配而编译失败。

## 构建流程

GitHub Actions 工作流位于：

```text
.github/workflows/build.yml
```

工作流需要仓库的 `GITHUB_TOKEN` 具备 `contents: write` 权限，否则内核包可以构建成功，但创建 Release 时会报 `Resource not accessible by integration`。

主要步骤：

1. 从 `https://www.kernel.org` 获取最新 stable 内核版本。
2. 从 `https://github.com/gregkh/linux.git` 克隆对应 `linux-X.Y.y` 分支。
3. 添加 Google BBR remote，并 checkout `google-bbr/v3`。
4. 修改内核源码 `Makefile` 中的版本号。
5. 执行 `scripts/apply-cloudflare-tcp-collapse.sh` 注入 Cloudflare TCP 优化。
6. 执行 `scripts/integrate-ucp.sh` 集成 UCP。
7. 执行 `scripts/apply-cloudflare-tcp-defaults.sh` 修改内核 TCP 默认行为。
8. 启用 `CONFIG_TCP_CONG_UCP=y` 和 `CONFIG_DEFAULT_UCP=y`，并设置默认 qdisc 为 `fq`。
9. 执行 `make bindeb-pkg` 构建 Debian 内核包。
10. 上传构建产物并创建 GitHub Release。

Release tag 格式：

```text
<arch>-<kernel-version>
```

例如：

```text
x86_64-6.9.1
arm64-6.9.1
```

## 安装内核包

从 Release 下载当前架构对应的所有 `.deb` 文件，然后执行：

```bash
sudo dpkg -i ./*.deb
sudo reboot
```

重启后确认内核版本：

```bash
uname -r
```

## 启用 BBRv3

```bash
echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee /etc/sysctl.d/99-bbr.conf
sudo sysctl --system
```

查看当前拥塞控制算法：

```bash
sysctl net.ipv4.tcp_congestion_control
```

查看可用算法：

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

## UCP 默认启用

新内核启动后默认使用 UCP：

```bash
sysctl net.ipv4.tcp_congestion_control
```

期望输出：

```text
net.ipv4.tcp_congestion_control = ucp
```

如果想临时切回 BBRv3：

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
```

## 本地验证

已在 WSL Debian 环境中基于 `google/bbr` 的 `v3` 分支做过验证：

```bash
make olddefconfig
make net/ipv4/tcp_ucp.o -j$(nproc)
make net/ipv4/tcp_input.o net/ipv4/tcp_ipv4.o -j$(nproc)
```

验证结果：

- UCP `tcp_ucp.o` 编译通过。
- UCP 可作为 `CONFIG_TCP_CONG_UCP=y` 内建，并设置为默认拥塞控制。
- Cloudflare 修改涉及的 `tcp_input.o` 编译通过。
- Cloudflare 修改涉及的 `tcp_ipv4.o` 编译通过。

## 目录说明

```text
.github/workflows/build.yml
```

GitHub Actions 自动构建与发布流程。

```text
scripts/apply-cloudflare-tcp-collapse.sh
```

按当前内核源码结构注入 Cloudflare `tcp_collapse_max_bytes` 支持。相比直接 `git apply` 旧 patch，这个脚本对新版内核更稳。

```text
scripts/integrate-ucp.sh
```

拉取 UCP 源码，复制 `tcp_ucp.c`，修改内核 `Makefile` 和 `Kconfig`，并自动处理新旧 TCP API 差异。

```text
scripts/apply-cloudflare-tcp-defaults.sh
```

修改内核默认 TCP 参数和默认 qdisc，使新内核开箱即采用更接近 Cloudflare 文章建议的 TCP 行为。

```text
patches/cloudflare-tcp-collapse-max-bytes.patch
```

Cloudflare 原始 patch，保留为来源参考。

```text
.config
```

内核构建配置。

## 注意事项

- UCP 是第三方拥塞控制实现，生产环境使用前建议自行压测和审计。
- `net.ipv4.tcp_collapse_max_bytes` 默认为 `0`，不会改变默认行为，只有手动配置后才生效。
- 本仓库当前会把 `net.ipv4.tcp_collapse_max_bytes` 的内核默认值改为 `6291456`，如果希望保持完全上游默认行为，可以删除 workflow 中的 `Apply Cloudflare-oriented TCP defaults` 步骤，或修改 `scripts/apply-cloudflare-tcp-defaults.sh`。
- 如果未来 Linux TCP API 再次变化，需要同步更新 `scripts/integrate-ucp.sh`。
- 构建完整内核耗时较长，GitHub Actions 的 runner 性能和限额可能影响构建时间。

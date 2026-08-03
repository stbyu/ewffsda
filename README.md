# ImmortalWrt Raspberry Pi 3：GitHub Actions 编译

这个仓库模板会在 GitHub Actions 中完成两件事：

1. 使用 ImmortalWrt 24.10.6 SDK 编译 SSR Plus+、Guest WiFi、GoWebDAV 和 wrtbwmon。
2. 使用同版本 ImageBuilder 生成 Raspberry Pi 3 的 ext4 固件。

最终固件和自定义 IPK 会作为 Actions Artifact 提供下载，不需要本地 Linux 编译机。

## 使用方法

1. 在 GitHub 新建一个空仓库。
2. 把本模板中的全部文件上传到仓库根目录，隐藏目录 `.github` 也必须保留。
3. 确认 `.github/workflows/build-immortalwrt.yml` 已位于默认分支。
4. 打开仓库的 **Actions** 页面。
5. 左侧选择 **Build ImmortalWrt RPi3**，点击 **Run workflow**。
6. 选择下载镜像和流量分载模式，然后再次点击 **Run workflow**。
7. 编译完成后，在该次运行页面底部下载 `immortalwrt-rpi3-24.10.6`。

Artifact 中包含：

- `firmware/*rpi-3-ext4-factory.img.gz`：首次写入 SD 卡使用。
- `firmware/*rpi-3-ext4-sysupgrade.img.gz`：以后同版本体系升级使用。
- `custom-ipks/*.ipk`：本次 SDK 编译出的第三方插件。
- `SHA256SUMS`：文件校验值。
- `build-info.txt`：版本、目标和构建参数。

## 两个运行选项

### 下载源

- `official`：ImmortalWrt 官方源。
- `zju`：浙江大学镜像；国内网络通常更快。

无论选择哪个，工作流都会用固定 SHA-256 校验 SDK 和 ImageBuilder。

### 流量分载

- `disabled`（默认）：关闭流量分载，wrtbwmon 统计更准确。
- `software`：启用软件 flow offloading。
- `hardware`：同时启用软件和硬件 flow offloading。

wrtbwmon 上游明确提示它与 Flow Offloading/NAT 存在兼容问题，所以默认关闭。若更重视转发性能，可选择 `software` 或 `hardware`，但流量统计可能偏低。

## 已固定的版本

| 项目 | 版本/提交 |
|---|---|
| ImmortalWrt | 24.10.6 |
| Target | `bcm27xx/bcm2710` |
| Profile | `rpi-3` |
| fw876/helloworld | `744f2a4a01e87cfba4cbf973e65525902c39de2a` |
| luci-app-guest-wifi | `58dcd53a04d8790b75e93da2df3876b54a701374` |
| openwrt-ext / GoWebDAV | `53b06fc4651497ebd6edbf138707dec3c6a13432` |
| wrtbwmon | `f82f9b393842d2113c3253a4902af50bfc757e1a` |
| luci-app-wrtbwmon | `f1b59b2309a0bc45511a1e7432c6c72f080a47d7` |

## 修改软件包

编辑 `packages.txt`，每行写一个要放入固件的软件包。以 `#` 开头的是注释。

自定义软件包由 `scripts/build.sh` 中的 `scripts/config --module` 选择。如果要增加第三方源码，需要同时完成：

1. 在 `prepare_custom_feed` 中拉取或复制源码。
2. 用 `scripts/config --module PACKAGE_软件包名` 将它设为模块。
3. 在 `packages.txt` 中加入最终要安装到固件的包名。

## 常见问题

### 看不到 Run workflow

工作流必须已经存在于默认分支，并且账号对仓库有写权限。进入 Actions 页面后刷新一次。

### SDK 阶段失败

展开 `Build custom IPKs and firmware`。工作流会在并行编译失败后自动用单线程重试，日志中第一次出现的 `Error` 通常才是真正原因。

### ImageBuilder 显示 Unknown package

检查 `packages.txt` 中的名字是否与 `custom-ipks/` 内实际 IPK 名称一致。第三方仓库改名时尤其容易出现。

### 内核依赖不匹配

不要把其他版本、其他 target 或 snapshot 的 IPK 上传到本工程。SDK 与 ImageBuilder 必须保持同为 24.10.6、`bcm27xx/bcm2710`。

### 编译超时

本工作流超时设置为 330 分钟。首次下载最多，通常后续上游网络正常时会更快。代理核心过多时，可在 `scripts/build.sh` 中减少手动选择的后端。

## 刷写和迁移

用 Raspberry Pi Imager 或 balenaEtcher 把 `ext4-factory.img.gz` 直接写入备用 SD 卡。首次启动后立即设置 root 密码。

不要把旧固件的整个 `/etc/config/`、旧 IPK、内核模块或 iptables 脚本复制到新系统。应手工迁移代理节点、DDNS、共享目录、WireGuard Peer、静态租约和 Wi-Fi 参数。


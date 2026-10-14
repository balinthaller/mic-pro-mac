# Mic Pro Mac

为 Insta360 Mic Pro 做的原生 macOS 小工具。菜单栏、侧边停靠条与控制面板，把设备状态、录音文件和墨水屏壁纸放到电脑上操作。

**公开开发预览版 · 基于 0.8.0 · Swift / AppKit · MIT**

[项目介绍与交互演示](https://george-wyy.github.io/mic-pro-mac/)

这是个人开发的非官方项目，与 Insta360、腾讯或 OpenAI 无隶属关系。核心功能在一台 Mic Pro TX、固件 **2.0.2.4** 上实机验证；公开版的设备配置与数据目录改造通过离线测试和构建，尚未验证更多设备/固件。适合愿意自行构建和反馈的开发者。

## 可以做什么

- **查看设备状态**：电量、充电/供电、电脑收音占用、设备内录和数据新鲜度。设备电量优先，macOS 缓存后备。
- **原生 Mac 界面**：菜单栏、侧边自动收起的停靠条、⌃⌥M 控制面板、独立输入/输出音频选择。
- **设备提示**：短暂切换降噪并恢复来触发震动；LED 整体切换并恢复来闪灯。它们不是独立马达或任意颜色控制。
- **墨水屏图片**：导入自己的图片，预览、裁切、六色量化；先完整备份，再上传、完整读回校验，支持恢复已验证备份。
- **内录导出**：蓝牙列出/下载已结束的 OGG 内录；USB 浏览与校验复制 OGG/WAV，支持进度和取消。原录音保留。
- **本机 Agent 接口**：用 `micpro` CLI 查询状态、触发提示、导出录音或管理壁纸；通过本机文件收发请求，没有网络监听。

充电状态约30秒短连接读取，断连/过期显示未知。低于100%且设备报告供电时显示“充电中”；100%接电仅显示“已接电源”。它不独立检测热保护或充电暂停。短时间电量不变不等于没有耗电，不推算精确剩余续航。

## 构建与配置

需要 macOS、支持当前系统的 Xcode Command Line Tools、Python 3。部分收音占用信息依赖 macOS 14.2+ API；其他系统版本与 Intel Mac 尚未做实机覆盖。没有厂商 SDK、第三方 Swift 依赖或随包固件。

```sh
python3 scripts/setup-local-signing.py
./build.sh
open 'build/Mic Pro Probe.app'
```

首次启动按系统提示授予蓝牙权限。**尚未配置时不会自动选择或控制麦克风**，会打开控制面板提示配置。

1. 先在 macOS 蓝牙设置中配对自己的 Mic Pro。
2. 列出已配对的 Mic Pro 名称和地址：

```sh
python3 scripts/configure-device.py --list
```

3. 用你自己的蓝牙地址与设备名称末尾六位配置。下面是虚构示例，不能直接用于真实设备：

```sh
python3 scripts/configure-device.py --address AA:BB:CC:DD:EE:01 --suffix TEST01
```

4. 退出并重新打开小工具。匹配同时要求已配对设备的地址和名称后缀；厂商协议读取还会核对设备身份。若需要物理确认，遵循设备与应用提示。

配置、日志、导出录音与壁纸备份保存在 `~/Library/Application Support/MicProMac/`。配置文件是 `config.json`，权限为0600。测试/开发可通过 `MICPRO_CONFIG` 指定其他配置文件，修改配置后需重启。公开版使用独立的应用标识，不覆盖其他原型应用的授权和偏好。

默认使用每位使用者自己生成的本地固定签名，密钥只留在 `.signing/`。开发者也可 `MICPRO_ADHOC=1 ./build.sh` 做临时构建检查；公开预览未做 Apple 公证，不提供开发者签名身份。

## Agent 使用

```sh
./micpro status
./micpro vibrate
./micpro blink --duration 2
./micpro recordings-list
./micpro recordings-list --transport usb
./micpro wallpaper-backup
```

下载时使用列表实际返回的 file_id 或相对路径，不复用示例编号。上传/恢复要求可验证的完整备份；参数详见 `./micpro --help`。一次设备控制事务完成后再发下一次，不在内录进行中做蓝牙下载。

## 可选与实验功能

Codex 额度模块默认关闭；启用 `config.json` 中的 `codex_quota_enabled: true` 后重启。它使用已安装的官方 Codex app-server 读取登录账户额度，不读取认证文件或导出凭据，也不会运行模型请求。

会议模式切换、交互式音频实验和旧诊断命令默认关闭；高级开发者可设 `experimental_features_enabled: true`。Mac/手机无重启接管和未知固件兼容性没有普遍验证，不作为公开版的功能承诺。

## 开发与验证

```sh
python3 scripts/test-public.py
```

离线覆盖显式设备配置、协议消息关联、充电数据解析/过期、提示参数恢复、USB复制与取消、耗电日志过滤、交接模型及布局；最后检查完整源码编译。脚本不会扫描、连接或写入蓝牙设备。

[隐私与边界](PRIVACY.md) · [公开版改动](CHANGELOG.md) · [协议研究来源](ACKNOWLEDGEMENTS.md)

本包没有录音、个人壁纸、原始日志、设备身份、旧 Git 历史、签名密钥、厂商固件或官方 App 图片。Insta360、Mic Pro、腾讯会议及 Codex 名称仅用于说明互操作对象；商标属于相应权利人。MIT 许可证适用于本项目自有源码。

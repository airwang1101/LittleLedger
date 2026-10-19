# 小账本 · LittleLedger

一个用 SwiftUI、AppKit 和 Swift Charts 编写的 macOS 本地记账工具。当前版本为 1.3.0（build 4）。界面语言为中文。

[English](README.en.md) · [隐私说明](PRIVACY.md) · [参与开发](CONTRIBUTING.md)

## 功能

- 多个独立账本，各自保存记录、设置和输入草稿。
- 输入金额后按回车记账，支持 `+100-20+50` 连续加减。
- 支持 CNY、USD、HKD、EUR、TWD，提供自动汇率和手动汇率。
- 金额框内用 Q/W/E/R 切换绑定的账本，用 C/U/H/O/T 切换币种。
- 账本选择页显示余额、当天余额变化和最近七天趋势。
- 统计图表、分类、搜索、撤销、导入和导出。
- 新手教程可修改快捷键绑定。

“余额涨幅”随入账和出账变化，不表示投资收益。缺少汇率时不显示不完整的折算总额。

## 从源码构建

需要 macOS 13 或更新版本，以及提供 macOS SDK 的 Xcode Command Line Tools。构建使用本机架构，支持 Apple silicon 和 Intel。当前本机验证结果见下方。

```sh
xcode-select --install
git clone https://github.com/airwang1101/LittleLedger.git
cd LittleLedger
./scripts/build.sh
open build/小账本.app
```

已安装开发工具时可跳过第一行。构建产物位于 `build/小账本.app`，使用本地临时签名。当前仓库提供源码构建，没有经过 Apple 公证的发布安装包。

## 测试

```sh
./scripts/test.sh
```

脚本重新构建后，在临时目录运行现有的金额、币种、统计、账本迁移、数据隔离和快捷键回归测试，不读取个人账目。临时测试数据在退出时清理。

本机已验证 Apple silicon 构建与两组回归测试。最低系统版本为构建目标，macOS 13 和 Intel 实机兼容性仍需验证。当前编译器会输出部分 SwiftUI 和 Charts API 弃用提示。

## 数据与网络

账目默认存放在 `~/Library/Application Support/LittleLedger/`，以 JSON 文件保存，未做应用层加密。首次启用多账本会沿用旧账目，其他账本位于 `books/<UUID>/`。

自动汇率会请求 ExchangeRate-API 的公开 USD 汇率接口。请求不包含账目、备注或金额。可以在设置中改用手动汇率。完整行为见 [PRIVACY.md](PRIVACY.md)。

本地工作区中的 `work/`、历史安装包、真实账目备份和编译缓存均不进入 Git 仓库。仓库只收录源码、构建资源、脚本与开源文档。

## 目录

```text
outputs/小账本源码/  Swift 源码，保留现有目录和功能
Resources/           应用图标与 Info.plist
scripts/             构建和隔离测试入口
.github/workflows/   macOS 自动构建与测试
```

## 许可

采用 [MIT License](LICENSE)。外部服务和平台框架说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

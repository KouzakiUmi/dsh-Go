# Magpie 与本地选择器补丁整合

## 基线与取舍

- 当前上游基线：`ae200e69`（`1.1.0`）。上游在 `ca3c4202` 之后重写了历史（旧 `d9fac50d` 线不再是祖先）；本轮合并清理了 28 个旧历史残留文件，合并结果与上游的差异收敛为 43 个补丁文件。
- 旧本地补丁栈保存在 `backup/pre-upstream-model-selector`（`4264c88`）、`backup/pre-1.0.16-sync`（`88ca1fb2`）及 `backup/pre-1.1.0-sync`（`2fb5acd9`，1.0.16 适配合并），仅用于回查。
- 保留的本地补丁：Magpie 一键 Provider 接入、模型选择器重写+玻璃浮层+键盘顶起、插件设置页回退删除与诊断包 `plugins.json`。PRoot `5.1.107.102` pin 已被上游收编（含 x86_64 哈希与测试对齐），本地补丁退役。

## 保留的模型选择器改动

- `95daabf3`：模型选择器重写，包含搜索、下拉渠道和扁平卡片。
- `c1a994ef`：思考深度胶囊与模型卡同列，弹层文案使用 l10n。

## Magpie 接收端补丁

- `b83b2ea1`：Magpie Provider 三协议接入。
- `7ac6063d`：供应商模型 ID 处理。
- `e69af1a5`：PRoot 包版本与哈希。
- `4ee77f2e`：供应商分组、元数据、并发 revision 和超时处理。
- `438890dd`：过滤 DSH 不支持的模态。
- `f4013375`：按实际写入模型数统计。
- `673c766e`：保留 `auto/...` 并独立为 Auto Routing。
- `5ef0b9af`：供应商 slug、稳定哈希和协议组成唯一路由 ID，旧 Group 清理校验归属。

## 验证（2026-11-16 · 上游 `ae200e69` / 1.1.0）

- `python3 app/tool/l10n_merge.py --check` / `guide_sync.py --check`：通过（75 parts, 8324 keys）。
- 依赖用上游 `app/pubspec.lock` + `flutter pub get --enforce-lockfile`（pub.dev 官方源）锁定；`flutter analyze --no-pub`：0 issues。
- `flutter test --no-pub test/arch/import_direction_test.dart test/diagnostics/ test/providers/ test/plugin_config/ test/plugins/seats/ test/chat/model_sheet_test.dart test/chat/chat_features_test.dart test/chat/chat_screen_test.dart`：1037 项全过，goldens 无需重生成。
- `dart analyze && dart test`：`dsh_client` 串行 911 项全过（31 skip）、`dsh_remote` 499 项（4 skip）、`dsh_tavern` 2949 项（1 skip）。
- 运行时桥接 JS 测试（宿主原生 prefix + `--target android` 补丁）：1930 项，1928 过 / 1 skip；唯一失败为 node 路径含空格的环境性断言，无空格路径复跑通过。
- `arm64-v8a` 运行时与 `libtawcroot.so` 重建：`r15-dsh0.2.2-rc.1-node24.22.1-ubuntu24.04.5-cadbacc49597`（150 项 Android 补丁）；Android JVM 单测 2368 项全过；release APK `1.1.0+11162245` 构建通过（SHA-256 `be60f7101f5c7badd818f73b1d044d793c2f6cf5c35d3a7d96ff30b3840e6dd0`）。

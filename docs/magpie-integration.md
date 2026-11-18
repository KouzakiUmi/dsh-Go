# Magpie 与本地选择器补丁整合

## 基线与取舍

- 当前上游基线：`0a15d4ce`（`1.2.0`）。本轮上游未改动补丁涉及的生产代码，合并零冲突；另把上一轮未提交的 1.1.0 合并落为提交 `26dd6ad2`。合并结果与上游的差异为 48 个补丁文件。
- 旧本地补丁栈保存在 `backup/pre-upstream-model-selector`（`4264c88`）、`backup/pre-1.0.16-sync`（`88ca1fb2`）、`backup/pre-1.1.0-sync`（`2fb5acd9`）及 `backup/pre-1.2.0-sync`（`26dd6ad2`），仅用于回查。
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

## 验证（2026-11-19 · 上游 `0a15d4ce` / 1.2.0）

- `python3 app/tool/l10n_merge.py --check` / `guide_sync.py --check`：通过（75 parts, 8343 keys）。
- 依赖按上游 `app/pubspec.lock` + `flutter pub get --enforce-lockfile`（pub.dev 官方源）锁定；`flutter analyze --no-pub`：0 issues。
- `flutter test --no-pub test/arch/import_direction_test.dart test/diagnostics/ test/providers/ test/plugin_config/ test/plugins/seats/ test/chat/model_sheet_test.dart test/chat/chat_features_test.dart test/chat/chat_screen_test.dart`：1038 项全过，goldens 无需重生成。
- `dart analyze && dart test`：`dsh_remote` 499 项（4 skip）、`dsh_tavern` 2984 项（1 skip）全过；`dsh_client` 中既有 flaky 的 `dsh_go_heartbeat_test` 一项时序断言偶发失败（隔离连跑 3 次通过）。
- `arm64-v8a` 运行时与 `libtawcroot.so` 重建：`r15-dsh0.2.2-rc.1-node24.22.1-ubuntu24.04.5-bac9fd213adc`（153 项 Android 补丁，含新增 `deepseek-refusal`、`deepseek-unnamed-stream-error`、`web-empty-reply-notice`）；Android JVM 单测 2374 项全过；release APK `1.2.0+11190651` 构建通过（SHA-256 `adcb7903290cc8107a47269ae59e205d141a5c4efe09268fa4692569446d8984`）。

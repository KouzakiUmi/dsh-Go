# Magpie 与本地选择器补丁整合

## 基线与取舍

- 当前上游基线：`d9fac50d`（`1.0.16` 及后续修复，原 `aa0daddb` 之后的合并已合入当前分支）。
- 旧本地补丁栈保存在 `backup/pre-upstream-model-selector`（`4264c88`）及 `backup/pre-1.0.16-sync`（`88ca1fb2`），仅用于回查。
- 保留的本地补丁经逐一核查均仍有必要：Magpie 一键 Provider 接入、模型选择器重写+玻璃浮层+键盘顶起、插件设置页回退删除与诊断包 `plugins.json`、以及 PRoot `5.1.107.102` pin（Termux 仓库已无 `5.1.107.98`）。

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

## 验证（2026-11-14 · 上游 `d9fac50d`）

- `python3 app/tool/l10n_merge.py --check` / `guide_sync.py --check`：通过。
- `flutter analyze --no-pub`：0 issues。
- `flutter test --no-pub test/arch/import_direction_test.dart test/diagnostics/ test/providers/ test/plugin_config/ test/plugins/seats/ test/chat/model_sheet_test.dart test/chat/chat_features_test.dart test/chat/chat_screen_test.dart`：984 项全过。
- `dart analyze && dart test`：`dsh_remote` 499 项全过、`dsh_tavern` 2736 项（1 skip）全过；`dsh_client` 除既有的 `dsh_go_heartbeat_test.dart` 外其余 862 项全过。
- `arm64-v8a` 运行时与 `libtawcroot.so` 重建：`r15-dsh0.2.2-rc.1-node24.22.1-ubuntu24.04.5-bbec3b3db879`；release APK `app-arm64-release.apk`（`1.0.16+11140222`）构建通过。

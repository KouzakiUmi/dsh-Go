# Magpie 与本地选择器补丁整合

## 基线与取舍

- 当前上游基线：`aa0daddb`。
- 旧本地补丁栈保存在 `backup/pre-upstream-model-selector`（`4264c88`），仅用于回查，不继续合并。
- 已由上游覆盖的旧修复不再重复维护；未保留其它旧 UI、运行时、远程、分享和测试补丁。
- 保留的本地功能仅为模型选择器重写与思考档位布局。

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

## 验证

- `python3 app/tool/l10n_merge.py --check`：通过。
- `flutter analyze`：通过。
- `flutter test test/chat/model_sheet_test.dart test/providers/magpie_models_test.dart`：通过。
- `dart analyze`：通过。
- `dart test test/provider_stream_idle_test.dart`：通过。
- arm64 运行时与 APK 构建结果在完成后补充。

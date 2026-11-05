# 高速构建

开发迭代的耗时几乎都花在两处：打包整个 Linux 运行时（rootfs 压缩），和为 APK 重跑 Gradle。
下面按「最少步骤」组织，先判断这次改动是否真的需要重建运行时。

## 1. 先判断能不能不重建

| 改动 | 需要的步骤 |
|---|---|
| 文档、`docs/guide/`、`.arb` 文案 | 生成器 + 检查，见 `CONTRIBUTING.md`，不构建 |
| 纯 Dart 逻辑（`packages/dsh_client`、`packages/dsh_remote`） | `dart test`；进 App 才需要 APK |
| Flutter 界面（`app/lib`） | 只构建 APK，**不重建运行时** |
| 桥接、引擎补丁、`runtime/boot`、`runtime/direct` | 重建**对应 ABI** 的运行时，再构建 APK |
| DSH 版本、Node、Ubuntu、pnpm 等钉死输入 | 重建运行时并按需重记 pins |

`app/android/app/build.gradle.kts` 直接读取 `runtime/out/<abi>/`，所以**只要该 ABI 的产物存在且输入没变，构建 APK 不会碰运行时**。改界面时跳过运行时构建，是从十几分钟降到几分钟的关键。

桥接改动除了重建运行时，还可以先用 x86_64 运行时在主机上验证，不必先出手机包：`runtime/test-host.sh` 用 bubblewrap 跑通 rootfs、`dsh plugin`、令牌、路由守卫、原生桥等段落。

## 2. 运行时

```bash
runtime/build-runtime.sh x86_64      # 模拟器
runtime/build-runtime.sh arm64-v8a   # 真机
```

- **只构建需要的 ABI。** 不带参数会构建两个 ABI，每个 ABI 各自付一次 `npm ci`（约 4 分钟）。
- **保留 `runtime/.cache`。** 下载件都有钉死哈希，每次仍会校验；删掉只会重新下载。
- **压缩档是主要成本。** 需要更快时单独加环境变量：

  ```bash
  COMPRESS=gz runtime/build-runtime.sh x86_64        # 换时间，包明显更大
  XZ_THREADS=8 runtime/build-runtime.sh x86_64       # 输出与线程数无关，可直接加
  XZ_PRESET=1 runtime/build-runtime.sh x86_64        # 更快的 xz，包更大
  ```

- `RUNTIME_OUT=/path` 把产物放到 `runtime/out` 之外（不参与打包），适合并行试验。
- 实测样本（单机，xz -6、4 线程，arm64）：全程约 14 分钟，其中 `npm ci` 约 4 分钟、rootfs 打包约 8.5 分钟。数值随机器变化，用来看比例，不作为承诺。

**补丁、桥接、版本这类改动尽量合并成一批再构建**，因为每个 ABI 的下载与 `npm ci` 是固定开销。

## 3. APK

```bash
tooling/build-apk.sh --release -f x64  --keep-daemon -- --no-pub   # 模拟器
tooling/build-apk.sh --release -f arm64 --keep-daemon -- --no-pub  # 真机
```

- `-- --no-pub`：`pubspec.yaml` 没变时跳过 `flutter pub get`。
- `--keep-daemon`：保留 Gradle 守护进程，连续构建省掉冷启动；不加时脚本结束会 `gradlew --stop`。
- `-f x64`：只给模拟器出包，界面迭代不用付 arm64 的成本；`-f all` 只在需要同构建号双包时使用。
- `--dry-run`：只打印将要执行的命令，确认参数后再构建。
- 构建号默认取构建分钟；用 `-n` 固定可复用同一 versionCode 反复安装。脚本只校验取值范围，不要低于设备上已装的版本，否则系统会拒绝降级安装。

实测样本（单机）：arm64 release 的 Gradle 阶段约 274 秒，加上 Flutter 前端编译约 5 分钟出一包。

更快的界面迭代可以走 `flutter run` 直接装到模拟器/真机（flavor 对应 `x64` 或 `arm64`，且该 ABI 的 `runtime/out/` 已存在），改动由热重载承接，不必每次出包。

## 4. 不要做的

- 不要用 `flutter clean`、删 `app/build/`、删 `runtime/out/` 来「排障」：这些是下一次构建的复用基础，删掉等于从头付全部成本。
- 不要在只改 `app/lib` 时重建运行时。
- 不要用 `-f all` 代替按需出包。
- 不要为了快而改 `pins.json`、跳补丁或跳过 ABI 校验：校验失败就是失败，构建成功不等于行为正确。

## 5. 交付记录

报告里写清实际执行的构建命令、ABI、Android 版本与设备类型。模拟器或桌面结果不能替代真机结论；涉及 PRoot、直接启动、手机操控、更新安装的改动仍需真机验证。

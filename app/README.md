# app — 星黎监控 Flutter 客户端

Android 客户端。整体架构、agent 部署、release 流程见根目录 [README.md](../README.md)。

## 本地开发

```bash
# 装 Flutter 依赖
flutter pub get

# debug 跑（solid 玻璃风格，避免 frosted blur 在低端机掉帧）
flutter run --dart-define=GLASS_STYLE=solid

# 切到 frosted（带 backdrop blur 毛玻璃）
flutter run --dart-define=GLASS_STYLE=frosted
```

## Build APK

```bash
# release APK（arm64-only，~19MB）
flutter build apk --release \
  --target-platform android-arm64 \
  --dart-define=GLASS_STYLE=solid

# 产物
ls -la build/app/outputs/flutter-apk/app-release.apk
```

## 项目结构

```
app/lib/
├── main.dart              # 入口、PopScope 双击退、_MonitorAppState
├── store.dart             # MonitorStore (ChangeNotifier)，管 servers + polling
├── api.dart               # AgentClient，每台 server 一个直连
├── trusted_certs.dart     # TOFU cert pin (SharedPreferences)
├── add_server_dialog.dart # 添加/编辑服务器对话框
├── overview_page.dart     # 总览页（iOS 风格拖动排序）
├── dynamic_server_page.dart # 详情页（自适应 NAS / VPS 布局）
├── models.dart            # 数据模型（jsonDecode → typed）
├── widgets.dart           # 通用 widget（GlassCard / UsageBar / StatusBadge）
├── toast.dart             # AppToast（OverlayEntry 实现，替代 SnackBar）
├── errors.dart            # 中文错误翻译
├── check_update.dart      # GitHub releases/latest 升级检查
└── about_page.dart        # 关于页
```

## 状态持久化

| Key | 内容 | 存储 |
|---|---|---|
| `monitor_servers_v2` | server 列表 JSON（id/name/host/port/disk aliases） | SharedPreferences |
| `token:<id>` | 每个 server 的 agent token | flutter_secure_storage (Android Keystore) |
| `trusted_certs_v1` | TOFU 信任的 cert SHA-256 | SharedPreferences |
| `first_launch_shown` | 首次启动「添加服务器」对话框是否弹过 | SharedPreferences |

## Build 注意事项

- 项目 keystore 路径：`app/android/keystore/release.keystore`（gitignored）
- 凭据文件：`app/android/keystore/CREDENTIALS.txt`（chmod 600，gitignored）
- 不要在代码里 hardcode 任何 server 名称 / IP / 真实 token，公共 repo 会被抓

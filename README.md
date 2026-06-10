# MiniMail — 跨平台网页套壳工具

将任意网页包装成原生桌面应用。支持 macOS 和 Windows 双平台。

## 项目结构

```
minimail/
├── shared/
│   └── config.json          # 跨平台共享配置（URL、窗口大小等）
├── platforms/
│   ├── macos/               # macOS 原生版本（Swift + WKWebView）
│   │   ├── MiniMail.swift   # 主代码
│   │   ├── Makefile         # 构建脚本
│   │   ├── Info.plist       # 应用信息
│   │   ├── gen_icon.swift   # 图标生成
│   │   └── AppIcon.icns     # 应用图标
│   └── windows/             # Windows 版本（Electron）
│       ├── src/
│       │   ├── main/        # 主进程（窗口、托盘、Cookie）
│       │   ├── preload/     # 预加载脚本
│       │   └── renderer/    # 渲染页面
│       ├── package.json     # 依赖和构建配置
│       └── dist/            # 构建输出
└── README.md
```

## 共享配置

编辑 `shared/config.json` 修改两个平台共用的配置：

```json
{
  "targetURL": "https://mail.chinamobile.com/...",
  "windowTitle": "中国移动邮箱",
  "windowWidth": 1200,
  "windowHeight": 800,
  "showNavigationBar": false,
  "customUserAgent": null
}
```

## macOS 版本

### 依赖
- macOS 13+
- `swiftc`（Xcode Command Line Tools）
- `make`

### 构建

```bash
cd platforms/macos
make         # 编译 .app 包
make run     # 编译并运行
make clean   # 清理
make dmg     # 打包 DMG 安装包
```

### 特性
- WKWebView 渲染（与 Safari 同核）
- 菜单栏图标模式（无 Dock）
- Cookie 持久化（跨启动保持登录）
- 单实例保护
- 后退/前进快捷键（可配置）
- 未读邮件角标轮询

## Windows 版本

### 依赖
- Windows 10/11
- Node.js 18+

### 构建

```bash
cd platforms/windows
npm install

npm run start        # 开发模式运行
npm run build        # 构建安装包 + 便携版
npm run build:dir    # 仅构建未打包版本
```

构建输出在 `platforms/windows/dist/`：
- `小邮箱 Setup 1.0.0.exe` — NSIS 安装程序
- `MiniMail-Portable.exe` — 便携版（无需安装）
- `win-unpacked/` — 未打包的完整目录

### 特性
- 系统托盘图标
- Cookie 持久化（JSON 文件）
- 单实例保护
- Alt+← / Alt+→ 后退前进
- 未读邮件轮询
- 新窗口在当前窗口打开

## 技术栈

| 平台 | 语言 | 渲染引擎 | 构建工具 |
|------|------|----------|----------|
| macOS | Swift | WKWebView | swiftc + make |
| Windows | JavaScript | Chromium | Electron |

## 双平台功能对照

| 功能 | macOS | Windows |
|------|-------|---------|
| 网页渲染 | WKWebView | Chromium (Electron) |
| 系统托盘 | NSStatusItem | Tray API |
| 单实例保护 | PID 文件锁 | requestSingleInstanceLock |
| Cookie 持久化 | JSON + WKHTTPCookieStore | JSON + session.cookies |
| 后退/前进 | ⌘[ / ⌘] | Alt+← / Alt+→ |
| 未读轮询 | executeJavaScript | executeJavaScript |
| 新窗口拦截 | setWindowOpenHandler | setWindowOpenHandler |
| JS Alert | NSAlert | 自定义 DOM overlay |
| 打包格式 | .app / .dmg | .exe (NSIS) / 便携版 |

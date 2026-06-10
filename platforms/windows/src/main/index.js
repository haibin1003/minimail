/**
 * MiniMail Windows 版本 - 主进程入口
 *
 * 功能对应 macOS 版本：
 * - WKWebView → BrowserWindow + webContents
 * - 系统托盘 → Tray API
 * - 单实例保护 → requestSingleInstanceLock
 * - Cookie 持久化 → cookies.js (JSON 文件)
 * - 快捷键 → renderer 内监听 + IPC
 * - 未读轮询 → executeJavaScript
 * - 新窗口拦截 → setWindowOpenHandler
 * - JS alert → IPC + dialog
 */

const { app, BrowserWindow, dialog, ipcMain, session } = require('electron');
const path = require('path');
const fs = require('fs');

const cookieManager = require('./cookies');
const trayManager = require('./tray');

// ========== 全局状态 ==========
let mainWindow = null;
let isQuitting = false;

// ========== 配置加载 ==========
const CONFIG_PATH = path.join(__dirname, '../../../shared/config.json');
const APP_CONFIG = loadConfig();
global.appConfig = APP_CONFIG;

function loadConfig() {
  try {
    const data = fs.readFileSync(CONFIG_PATH, 'utf8');
    return JSON.parse(data);
  } catch (err) {
    console.error('[Config] 加载失败，使用默认配置:', err.message);
    return {
      appName: 'MiniMail',
      productName: '小邮箱',
      targetURL: 'https://mail.chinamobile.com',
      windowWidth: 1200,
      windowHeight: 800,
      showNavigationBar: false,
      unreadPollInterval: 30000,
      folders: { inbox: { id: '1' }, sent: { id: '3' }, unread: { id: '0' } }
    };
  }
}

// ========== 单实例保护 ==========
const gotTheLock = app.requestSingleInstanceLock();

if (!gotTheLock) {
  console.log('[单实例] 已有实例运行，退出');
  app.quit();
  process.exit(0);
}

// 第二个实例尝试启动时，聚焦已有窗口
app.on('second-instance', () => {
  console.log('[单实例] 检测到第二个实例，聚焦已有窗口');
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    trayManager.showWindow();
  }
});

// ========== 窗口创建 ==========
function createWindow() {
  // 决定启动 URL
  const launchURL = cookieManager.loadLastURL() || APP_CONFIG.targetURL;
  console.log(`[启动] 加载 URL: ${launchURL}`);

  mainWindow = new BrowserWindow({
    width: APP_CONFIG.windowWidth,
    height: APP_CONFIG.windowHeight,
    minWidth: 600,
    minHeight: 400,
    title: APP_CONFIG.windowTitle || APP_CONFIG.productName,
    show: false, // 先不显示，等 ready-to-show
    icon: path.join(__dirname, '../../build/icon.ico'),
    // 隐藏默认菜单栏（按 Alt 键也不显示）
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      // 允许同源策略放松（类似 macOS 的 NSAllowsArbitraryLoads）
      webSecurity: true
    }
  });

  // 彻底移除默认菜单栏（File/Edit/View/Window/Help）
  mainWindow.setMenu(null);

  // 恢复 cookies
  const cookieStore = mainWindow.webContents.session.cookies;
  cookieManager.restoreCookies(cookieStore).then(() => {
    // 等 300ms 让网络进程同步（对应 macOS 版本）
    setTimeout(() => {
      mainWindow.loadURL(launchURL, {
        userAgent: APP_CONFIG.customUserAgent || undefined
      });
    }, 300);
  });

  // 窗口准备好后显示
  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
    mainWindow.focus();
  });

  // ========== 导航事件 ==========

  // 页面标题变化
  mainWindow.webContents.on('page-title-updated', (event, title) => {
    mainWindow.setTitle(title || APP_CONFIG.windowTitle);
  });

  // 页面加载完成
  mainWindow.webContents.on('did-finish-load', () => {
    console.log('[导航] 页面加载完成');

    // 保存 URL 和 cookies
    const currentURL = mainWindow.webContents.getURL();
    if (currentURL.includes('/webmail/se/mail/')) {
      cookieManager.saveLastURL(currentURL);
      cookieManager.saveCookies(cookieStore);
    }

    // 启动未读轮询
    trayManager.startUnreadPolling(APP_CONFIG.unreadPollInterval);
  });

  // 页面加载失败
  mainWindow.webContents.on('did-fail-load', (event, errorCode, errorDescription) => {
    console.error('[导航] 加载失败:', errorCode, errorDescription);
    const errorHTML = `
      <html>
        <head><meta charset="utf-8"></head>
        <body style="display:flex;align-items:center;justify-content:center;
                     font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
                     background:#f5f5f7;margin:0;height:100vh;">
          <div style="text-align:center;color:#666">
            <h2>⚠️ 加载失败</h2>
            <p>${errorDescription}</p>
            <button onclick="location.reload()" style="padding:10px 20px;margin-top:20px;
                     cursor:pointer;font-size:14px;border-radius:6px;border:1px solid #ccc;">
              重新加载
            </button>
          </div>
        </body>
      </html>
    `;
    mainWindow.webContents.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(errorHTML));
  });

  // ========== 新窗口处理 ==========
  // 新窗口链接在当前窗口打开（对应 macOS 的 createWebViewWith）
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    console.log('[窗口] 拦截新窗口:', url);
    mainWindow.loadURL(url);
    return { action: 'deny' };
  });

  // ========== JS Alert 处理 ==========
  // 对应 macOS 版本的 runJavaScriptAlertPanelWithMessage
  mainWindow.webContents.on('console-message', (event, level, message) => {
    // 通过 preload 注入的 alert 拦截会通过 IPC 处理
  });

  // ========== 快捷键处理 (IPC) ==========
  ipcMain.on('navigate-back', () => {
    if (mainWindow.webContents.canGoBack()) {
      mainWindow.webContents.goBack();
      console.log('[快捷键] 后退');
    }
  });

  ipcMain.on('navigate-forward', () => {
    if (mainWindow.webContents.canGoForward()) {
      mainWindow.webContents.goForward();
      console.log('[快捷键] 前进');
    }
  });

  // ========== 窗口事件 ==========
  mainWindow.on('close', (event) => {
    if (!isQuitting) {
      // 关闭时隐藏而不是退出（对应 macOS 的 applicationShouldTerminateAfterLastWindowClosed = false）
      event.preventDefault();
      trayManager.hideWindow();
    } else {
      // 真正退出时保存 cookies
      cookieManager.saveCookies(cookieStore);
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  // 窗口显示/隐藏时更新托盘菜单
  mainWindow.on('show', () => trayManager.updateTrayMenu());
  mainWindow.on('hide', () => trayManager.updateTrayMenu());

  return mainWindow;
}

// ========== 应用生命周期 ==========

app.whenReady().then(() => {
  console.log('[App] 准备就绪');

  const win = createWindow();

  // 创建系统托盘
  trayManager.createTray(win, APP_CONFIG);

  app.on('activate', () => {
    // 对应 macOS 的 applicationShouldHandleReopen
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    } else {
      trayManager.showWindow();
    }
  });
});

// 所有窗口关闭时不退出（菜单栏应用模式）
app.on('window-all-closed', () => {
  // Windows 上通常退出，但我们要保持菜单栏模式
  // 不调用 app.quit()，保持托盘运行
});

// 退出前保存 cookies
app.on('before-quit', () => {
  isQuitting = true;
  if (mainWindow && !mainWindow.isDestroyed()) {
    cookieManager.saveCookies(mainWindow.webContents.session.cookies);
  }
});

app.on('quit', () => {
  trayManager.destroyTray();
});

// ========== 日志 ==========
function logToFile(msg) {
  const ts = new Date().toLocaleTimeString('zh-CN');
  const logDir = app.getPath('logs') || app.getPath('userData');
  const logFile = path.join(logDir, APP_CONFIG.logFileName || 'MiniMail_debug.log');

  try {
    fs.appendFileSync(logFile, `[${ts}] ${msg}\n`, 'utf8');
  } catch (err) {
    // 忽略日志写入失败
  }
}

// 暴露日志函数到全局
global.logToFile = logToFile;

console.log('[App] MiniMail Windows 版本已启动');
console.log('[App] 配置:', JSON.stringify(APP_CONFIG, null, 2));

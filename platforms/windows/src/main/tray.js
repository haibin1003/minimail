/**
 * 系统托盘控制器
 * 对应 macOS 版本的 StatusBarController
 */

const { Tray, Menu, dialog } = require('electron');
const path = require('path');

let tray = null;
let mainWindow = null;
let unreadCount = 0;
let unreadPollTimer = null;

// 图标路径
const ICON_NORMAL = path.join(__dirname, '../../build/tray-icon.png');
const ICON_UNREAD = path.join(__dirname, '../../build/tray-icon-unread.png');

/**
 * 创建系统托盘
 * @param {Electron.BrowserWindow} win - 主窗口
 * @param {Object} config - 应用配置
 */
function createTray(win, config) {
  mainWindow = win;

  // 使用默认图标（如果没有自定义图标）
  tray = new Tray(ICON_NORMAL);
  tray.setToolTip(config.productName || 'MiniMail');

  updateTrayMenu();

  // 点击托盘图标切换窗口显示/隐藏
  tray.on('click', () => {
    toggleWindow();
  });

  return tray;
}

/**
 * 更新托盘菜单（根据当前状态）
 */
function updateTrayMenu() {
  if (!tray) return;

  const config = global.appConfig || {};
  const folders = config.folders || {};
  const windowVisible = mainWindow && mainWindow.isVisible();

  const template = [
    {
      label: windowVisible ? '隐藏窗口' : '显示窗口',
      click: toggleWindow
    },
    { type: 'separator' },
    {
      label: unreadCount > 0 ? `未读邮件 (${unreadCount})` : '未读邮件',
      click: () => {
        showWindow();
        setTimeout(() => clickFolder('unread'), 300);
      }
    },
    {
      label: folders.inbox?.name || '收件箱',
      click: () => {
        showWindow();
        setTimeout(() => clickFolder('inbox'), 300);
      }
    },
    {
      label: folders.sent?.name || '已发送',
      click: () => {
        showWindow();
        setTimeout(() => clickFolder('sent'), 300);
      }
    },
    { type: 'separator' },
    {
      label: '刷新',
      click: () => {
        if (mainWindow && !mainWindow.isDestroyed()) {
          mainWindow.webContents.reload();
        }
      }
    },
    { type: 'separator' },
    {
      label: '快捷键设置...',
      click: showShortcutSettings
    },
    { type: 'separator' },
    {
      label: '退出',
      click: () => {
        global.isQuitting = true;
        require('electron').app.quit();
      }
    }
  ];

  tray.setContextMenu(Menu.buildFromTemplate(template));
}

/**
 * 显示窗口
 */
function showWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.show();
  mainWindow.focus();
  updateTrayMenu();
}

/**
 * 隐藏窗口
 */
function hideWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.hide();
  updateTrayMenu();
}

/**
 * 切换窗口显示/隐藏
 */
function toggleWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (mainWindow.isVisible()) {
    hideWindow();
  } else {
    showWindow();
  }
}

/**
 * 点击邮件文件夹
 * @param {string} folderKey - 'inbox' | 'sent' | 'unread'
 */
function clickFolder(folderKey) {
  if (!mainWindow || mainWindow.isDestroyed()) return;

  const config = global.appConfig || {};
  const folders = config.folders || {};
  const folder = folders[folderKey];
  if (!folder) return;

  const js = `document.getElementById('span_${folder.id}').click();`;

  mainWindow.webContents.executeJavaScript(js, true)
    .then(() => {
      console.log(`[导航] 点击 ${folder.name}(id=${folder.id})`);
      // 1秒后查询未读数
      setTimeout(() => queryUnreadCount(), 1000);
    })
    .catch(err => {
      console.log(`[导航] ${folder.name} 失败: ${err.message}`);
    });
}

/**
 * 查询未读邮件数量
 */
function queryUnreadCount() {
  if (!mainWindow || mainWindow.isDestroyed()) return;

  const js = `
    (function() {
      var el = document.querySelector('[data-unread]');
      if (el) {
        var n = parseInt(el.getAttribute('data-unread'));
        if (!isNaN(n)) return String(n);
      }
      return '0';
    })()
  `;

  mainWindow.webContents.executeJavaScript(js, true)
    .then(result => {
      const count = parseInt(result) || 0;
      if (count !== unreadCount) {
        unreadCount = count;
        console.log(`[未读] 更新未读数: ${count}`);
        updateTrayMenu();
      }
    })
    .catch(err => {
      console.log(`[未读] 查询失败: ${err.message}`);
    });
}

/**
 * 启动未读邮件轮询
 * @param {number} interval - 轮询间隔（毫秒）
 */
function startUnreadPolling(interval = 30000) {
  stopUnreadPolling();
  // 首次查询
  setTimeout(() => queryUnreadCount(), 3000);
  // 定时轮询
  unreadPollTimer = setInterval(() => queryUnreadCount(), interval);
}

/**
 * 停止未读邮件轮询
 */
function stopUnreadPolling() {
  if (unreadPollTimer) {
    clearInterval(unreadPollTimer);
    unreadPollTimer = null;
  }
}

/**
 * 显示快捷键设置对话框
 */
function showShortcutSettings() {
  dialog.showMessageBox(mainWindow, {
    type: 'info',
    title: '快捷键设置',
    message: '快捷键设置',
    detail: '后退: Alt + ←\n前进: Alt + →\n刷新: Ctrl + R\n\n快捷键在应用窗口内全局生效。',
    buttons: ['确定']
  });
}

/**
 * 销毁托盘
 */
function destroyTray() {
  stopUnreadPolling();
  if (tray) {
    tray.destroy();
    tray = null;
  }
}

module.exports = {
  createTray,
  showWindow,
  hideWindow,
  toggleWindow,
  startUnreadPolling,
  stopUnreadPolling,
  queryUnreadCount,
  updateTrayMenu,
  destroyTray
};

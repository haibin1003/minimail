/**
 * Preload 脚本
 * 在 renderer 上下文中执行，提供安全的 IPC 桥接
 * 对应 macOS 版本的 JS bridge 功能
 */

const { contextBridge, ipcRenderer } = require('electron');

// 暴露给 renderer 的 API
contextBridge.exposeInMainWorld('electronAPI', {
  // 导航
  goBack: () => ipcRenderer.send('navigate-back'),
  goForward: () => ipcRenderer.send('navigate-forward'),

  // 获取配置
  getConfig: () => ipcRenderer.invoke('get-config'),
});

// 拦截 window.alert，通过 IPC 转发到主进程的 dialog
// 对应 macOS 版本的 runJavaScriptAlertPanelWithMessage
const originalAlert = window.alert;
window.alert = function(message) {
  // 仍然显示原生 alert（Chromium 默认不支持在 webview 中显示 alert）
  // 我们创建一个自定义的 DOM alert
  showCustomAlert(message);
};

function showCustomAlert(message) {
  // 移除已有的 alert
  const existing = document.getElementById('minimail-custom-alert');
  if (existing) existing.remove();

  const overlay = document.createElement('div');
  overlay.id = 'minimail-custom-alert';
  overlay.style.cssText = `
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.4);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 99999;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  `;

  const box = document.createElement('div');
  box.style.cssText = `
    background: white;
    padding: 24px 32px;
    border-radius: 12px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.2);
    max-width: 400px;
    text-align: center;
  `;

  const title = document.createElement('h3');
  title.textContent = '网页提示';
  title.style.cssText = 'margin: 0 0 12px 0; font-size: 16px;';

  const msg = document.createElement('p');
  msg.textContent = message;
  msg.style.cssText = 'margin: 0 0 20px 0; color: #666; font-size: 14px;';

  const btn = document.createElement('button');
  btn.textContent = '确定';
  btn.style.cssText = `
    padding: 8px 24px;
    background: #007AFF;
    color: white;
    border: none;
    border-radius: 6px;
    cursor: pointer;
    font-size: 14px;
  `;
  btn.onclick = () => overlay.remove();

  box.appendChild(title);
  box.appendChild(msg);
  box.appendChild(btn);
  overlay.appendChild(box);
  document.body.appendChild(overlay);
}

// 在页面中注入键盘快捷键监听
// 对应 macOS 版本的 KeyboardShortcutManager
document.addEventListener('keydown', (e) => {
  // 后退: Alt + ←
  if (e.altKey && e.key === 'ArrowLeft') {
    e.preventDefault();
    ipcRenderer.send('navigate-back');
  }
  // 前进: Alt + →
  else if (e.altKey && e.key === 'ArrowRight') {
    e.preventDefault();
    ipcRenderer.send('navigate-forward');
  }
});

console.log('[Preload] MiniMail preload 脚本已加载');

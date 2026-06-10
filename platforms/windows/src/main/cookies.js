/**
 * Cookie 持久化管理器
 * 对应 macOS 版本的 CookieManager
 * 保存/恢复 cookies 到 JSON 文件，session cookie 获得 30 天有效期
 */

const fs = require('fs');
const path = require('path');
const { app } = require('electron');

const DATA_DIR = path.join(app.getPath('userData'));
const COOKIE_FILE = path.join(DATA_DIR, 'cookies.json');
const URL_FILE = path.join(DATA_DIR, 'last_url.txt');
const COOKIE_MAX_AGE_DAYS = 30;

/**
 * 确保数据目录存在
 */
function ensureDataDir() {
  if (!fs.existsSync(DATA_DIR)) {
    fs.mkdirSync(DATA_DIR, { recursive: true });
  }
}

/**
 * 保存 cookies 到 JSON 文件
 * @param {Electron.Cookies} cookieStore - Electron session cookies API
 */
async function saveCookies(cookieStore) {
  try {
    const cookies = await cookieStore.get({});
    if (cookies.length === 0) return;

    const thirtyDays = Date.now() + COOKIE_MAX_AGE_DAYS * 24 * 60 * 60 * 1000;

    const serializable = cookies.map(cookie => ({
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path || '/',
      secure: cookie.secure || false,
      httpOnly: cookie.httpOnly || false,
      sameSite: cookie.sameSite || 'no_restriction',
      expirationDate: cookie.expirationDate || (thirtyDays / 1000),
      url: cookie.secure
        ? `https://${cookie.domain.startsWith('.') ? cookie.domain.slice(1) : cookie.domain}${cookie.path || '/'}`
        : `http://${cookie.domain.startsWith('.') ? cookie.domain.slice(1) : cookie.domain}${cookie.path || '/'}`
    }));

    ensureDataDir();
    fs.writeFileSync(COOKIE_FILE, JSON.stringify(serializable, null, 2), 'utf8');
    console.log(`[CookieManager] 已保存 ${cookies.length} 个 cookies`);
  } catch (err) {
    console.error('[CookieManager] 保存失败:', err.message);
  }
}

/**
 * 从 JSON 文件恢复 cookies
 * @param {Electron.Cookies} cookieStore
 */
async function restoreCookies(cookieStore) {
  try {
    if (!fs.existsSync(COOKIE_FILE)) {
      console.log('[CookieManager] 无 cookie 文件');
      return;
    }

    const data = fs.readFileSync(COOKIE_FILE, 'utf8');
    const cookies = JSON.parse(data);

    for (const cookie of cookies) {
      try {
        await cookieStore.set({
          url: cookie.url,
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path,
          secure: cookie.secure,
          httpOnly: cookie.httpOnly,
          sameSite: cookie.sameSite,
          expirationDate: cookie.expirationDate
        });
      } catch (err) {
        // 某些 cookie 可能设置失败（如域名不匹配），忽略
        console.log(`[CookieManager] 跳过 cookie ${cookie.name}: ${err.message}`);
      }
    }

    console.log(`[CookieManager] 已恢复 ${cookies.length} 个 cookies`);
  } catch (err) {
    console.error('[CookieManager] 恢复失败:', err.message);
  }
}

/**
 * 保存最后访问的 URL
 * @param {string} url
 */
function saveLastURL(url) {
  try {
    // 移除 r 参数（随机令牌）
    const urlObj = new URL(url);
    urlObj.searchParams.delete('r');
    const cleanURL = urlObj.toString();

    ensureDataDir();
    fs.writeFileSync(URL_FILE, cleanURL, 'utf8');
  } catch (err) {
    console.error('[CookieManager] 保存 URL 失败:', err.message);
  }
}

/**
 * 加载最后访问的 URL
 * @returns {string|null}
 */
function loadLastURL() {
  try {
    if (!fs.existsSync(URL_FILE)) return null;
    const data = fs.readFileSync(URL_FILE, 'utf8').trim();
    return data || null;
  } catch (err) {
    return null;
  }
}

/**
 * 清除所有 cookie 和 URL 数据
 */
function clear() {
  try {
    if (fs.existsSync(COOKIE_FILE)) fs.unlinkSync(COOKIE_FILE);
    if (fs.existsSync(URL_FILE)) fs.unlinkSync(URL_FILE);
  } catch (err) {
    console.error('[CookieManager] 清除失败:', err.message);
  }
}

module.exports = {
  saveCookies,
  restoreCookies,
  saveLastURL,
  loadLastURL,
  clear
};

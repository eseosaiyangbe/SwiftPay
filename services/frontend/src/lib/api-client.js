// ============================================
// API URL Configuration - Environment-Aware
// ============================================
// Supports multiple deployment scenarios:
// 1. Relative URL (/api) - Works with ingress, nginx proxies to api-gateway
// 2. Full URL (http://api-gateway:3000/api) - Direct service communication (internal)
// 3. External URL (https://api.swiftpay.com/api) - Production with real domain
// 4. Default (/api) - Local and container default through nginx
//
// How it works:
// - Relative URLs (/api): Browser makes request to same origin, nginx proxies it
// - Absolute URLs: Direct fetch to specified endpoint
// - Environment variable REACT_APP_API_URL can be set per environment
const getApiBaseUrl = () => {
  const envUrl = process.env.REACT_APP_API_URL;

  if (!envUrl) {
    return '/api';
  }

  if (envUrl.startsWith('/')) {
    return envUrl;
  }

  if (envUrl.startsWith('http://') || envUrl.startsWith('https://')) {
    return envUrl;
  }

  return `/${envUrl}`;
};

const API_BASE_URL = getApiBaseUrl();
const SESSION_KEYS = ['accessToken', 'refreshToken', 'user'];

const formatLockoutWait = (lockedUntil) => {
  if (!lockedUntil) return null;

  const lockedUntilTime = new Date(lockedUntil).getTime();
  if (Number.isNaN(lockedUntilTime)) return null;

  const remainingMs = lockedUntilTime - Date.now();
  if (remainingMs <= 0) return 'Please try again now.';

  const remainingMinutes = Math.ceil(remainingMs / 60000);
  if (remainingMinutes < 60) {
    return `Please try again in about ${remainingMinutes} minute${remainingMinutes === 1 ? '' : 's'}.`;
  }

  const remainingHours = Math.ceil(remainingMinutes / 60);
  return `Please try again in about ${remainingHours} hour${remainingHours === 1 ? '' : 's'}.`;
};

const buildErrorMessage = (error, fallback) => {
  if (error.lockedUntil) {
    const waitMessage = formatLockoutWait(error.lockedUntil);
    return waitMessage
      ? `Account locked after too many failed attempts. ${waitMessage}`
      : 'Account locked after too many failed attempts. Please try again later.';
  }

  if (typeof error.attemptsRemaining === 'number') {
    return `${error.error || fallback}. ${error.attemptsRemaining} attempt${error.attemptsRemaining === 1 ? '' : 's'} remaining before lockout.`;
  }

  return error.error || error.message || fallback;
};

class SessionStore {
  static migrateFromLocalStorage() {
    SESSION_KEYS.forEach((key) => localStorage.removeItem(key));
  }

  static get(key) {
    return sessionStorage.getItem(key);
  }

  static set(key, value) {
    sessionStorage.setItem(key, value);
  }

  static removeAll() {
    SESSION_KEYS.forEach((key) => {
      sessionStorage.removeItem(key);
      localStorage.removeItem(key);
    });
  }
}

export class APIClient {
  static initializeSession() {
    SessionStore.migrateFromLocalStorage();
  }

  static getStoredUser() {
    const storedUser = SessionStore.get('user');
    if (!storedUser) return null;

    try {
      return JSON.parse(storedUser);
    } catch {
      this.removeToken();
      return null;
    }
  }

  static getToken() {
    return SessionStore.get('accessToken');
  }

  static setToken(token) {
    SessionStore.set('accessToken', token);
  }

  static removeToken() {
    SessionStore.removeAll();
  }

  static async request(endpoint, options = {}, isRetryAfterRefresh = false) {
    const token = this.getToken();
    const isAuthEndpoint = endpoint === '/auth/login' || endpoint === '/auth/register' || endpoint === '/auth/refresh';

    const doFetch = () =>
      fetch(`${API_BASE_URL}${endpoint}`, {
        credentials: 'include',
        headers: {
          'Content-Type': 'application/json',
          ...(token && { Authorization: `Bearer ${token}` }),
          ...options.headers,
        },
        ...options,
      });

    let response = await doFetch();

    if (response.status === 401) {
      if (isAuthEndpoint) {
        const body = await response.json().catch(() => ({}));
        throw new Error(buildErrorMessage(body, 'Invalid credentials'));
      }
      if (!isRetryAfterRefresh) {
        const refreshed = await this.tryRefreshToken();
        if (refreshed) {
          return this.request(endpoint, options, true);
        }
      }
      this.removeToken();
      window.location.href = '/';
      throw new Error('Session expired');
    }

    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Request failed' }));
      if (error.errors && Array.isArray(error.errors)) {
        const passwordErrors = error.errors
          .filter(e => e.path === 'password')
          .map(e => e.msg);
        if (passwordErrors.length > 0) {
          throw new Error(`Password requirements: ${passwordErrors.join(', ')}`);
        }
        const errorMessages = error.errors.map(e => {
          if (e.path === 'email') return `Email: ${e.msg}`;
          if (e.path === 'name') return `Name: ${e.msg}`;
          return `${e.path}: ${e.msg}`;
        }).join('. ');
        throw new Error(errorMessages || 'Validation failed');
      }
      throw new Error(buildErrorMessage(error, `HTTP ${response.status}`));
    }

    return response.json();
  }

  static async tryRefreshToken() {
    const refreshToken = SessionStore.get('refreshToken');
    if (!refreshToken) return false;

    try {
      const res = await fetch(`${API_BASE_URL}/auth/refresh`, {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refreshToken }),
      });
      if (!res.ok) return false;
      const data = await res.json();
      if (data.accessToken) {
        this.setToken(data.accessToken);
        if (data.refreshToken) SessionStore.set('refreshToken', data.refreshToken);
        return true;
      }
      return false;
    } catch {
      return false;
    }
  }

  static async login(email, password) {
    const data = await this.request('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    });
    this.setToken(data.accessToken);
    SessionStore.set('refreshToken', data.refreshToken);
    SessionStore.set('user', JSON.stringify(data.user));
    return data;
  }

  static async register(email, password, name) {
    const data = await this.request('/auth/register', {
      method: 'POST',
      body: JSON.stringify({ email, password, name }),
    });
    this.setToken(data.accessToken);
    SessionStore.set('refreshToken', data.refreshToken);
    const user = data.user || { id: data.userId, email, name, role: 'user' };
    SessionStore.set('user', JSON.stringify(user));
    return { ...data, user };
  }

  static async logout() {
    try {
      const refreshToken = SessionStore.get('refreshToken');
      await this.request('/auth/logout', {
        method: 'POST',
        body: JSON.stringify(refreshToken ? { refreshToken } : {}),
      });
    } finally {
      this.removeToken();
    }
  }

  static async changePassword(currentPassword, newPassword) {
    return this.request('/auth/change-password', {
      method: 'POST',
      body: JSON.stringify({ currentPassword, newPassword }),
    });
  }

  static async forgotPassword(email) {
    return this.request('/auth/forgot-password', {
      method: 'POST',
      body: JSON.stringify({ email }),
    });
  }

  static async resetPassword(token, newPassword) {
    return this.request('/auth/reset-password', {
      method: 'POST',
      body: JSON.stringify({ token, newPassword }),
    });
  }

  static async getWallets() {
    return this.request('/wallets');
  }

  static async getWallet(userId) {
    return this.request(`/wallets/${userId}`);
  }

  static async createTransaction(data) {
    return this.request('/transactions', {
      method: 'POST',
      body: JSON.stringify({
        fromUserId: data.from,
        toUserId: data.to,
        amount: parseFloat(data.amount),
      }),
    });
  }

  static async getTransactions(userId = null) {
    const query = userId ? `?userId=${userId}` : '';
    return this.request(`/transactions${query}`);
  }

  static async getNotifications(userId) {
    return this.request(`/notifications/${userId}`);
  }

  static async markNotificationRead(notificationId) {
    return this.request(`/notifications/${notificationId}/read`, {
      method: 'PUT',
      body: JSON.stringify({}),
    });
  }

  static async deleteNotification(notificationId) {
    return this.request(`/notifications/${notificationId}`, {
      method: 'DELETE',
    });
  }

  static async getMetrics() {
    return this.request('/metrics');
  }
}

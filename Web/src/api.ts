// Тонка обгортка над fetch для бекенду PassBy.
// Токен зберігається в sessionStorage (лише для тестового фронтенду).

const BASE = import.meta.env.VITE_API_URL ?? '';
const TOKEN_KEY = 'passby_token';

export const ROLES = {
  DeliveryRequester: 'DeliveryRequester',
  Deliverer: 'Deliverer'
};

export const ROLE_LABELS = {
  DeliveryRequester: 'Відправник',
  Deliverer: "Кур'єр"
};

export function getToken() {
  try {
    return sessionStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setToken(token) {
  try {
    if (token) sessionStorage.setItem(TOKEN_KEY, token);
    else sessionStorage.removeItem(TOKEN_KEY);
  } catch {
    /* sessionStorage недоступний */
  }
}

export function decodeJwt(token) {
  try {
    const payload = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const json = decodeURIComponent(
      atob(payload)
        .split('')
        .map((c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2))
        .join('')
    );
    return JSON.parse(json);
  } catch {
    return null;
  }
}

export function isTokenValid(token) {
  const claims = token ? decodeJwt(token) : null;
  return !!claims && typeof claims.exp === 'number' && claims.exp * 1000 > Date.now();
}

// --- журнал запитів (для тестової панелі) ---
const logListeners = new Set();
const unauthorizedListeners = new Set();

export function onRequestLog(fn) {
  logListeners.add(fn);
  return () => logListeners.delete(fn);
}

export function onUnauthorized(fn) {
  unauthorizedListeners.add(fn);
  return () => unauthorizedListeners.delete(fn);
}

function maskTokens(data) {
  if (data && typeof data === 'object' && typeof data.accessToken === 'string') {
    return { ...data, accessToken: data.accessToken.slice(0, 14) + '…' };
  }
  return data;
}

let counter = 0;

export async function api(method, path, body, { auth = true } = {}) {
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';

  const token = getToken();
  const sentToken = auth && !!token;
  if (sentToken) headers.Authorization = `Bearer ${token}`;

  let status = 0;
  let data = null;

  try {
    const res = await fetch(BASE + path, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined
    });
    status = res.status;
    const text = await res.text();
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = text;
    }
  } catch {
    data = { message: 'Немає зʼєднання з сервером' };
  }

  const entry = {
    id: ++counter,
    time: new Date().toLocaleTimeString('uk-UA'),
    method,
    path,
    status,
    data: maskTokens(data)
  };
  logListeners.forEach((fn) => fn(entry));

  if (status === 401 && sentToken) {
    unauthorizedListeners.forEach((fn) => fn());
  }

  return { ok: status >= 200 && status < 300, status, data };
}

export function errorMessage(result, fallback = 'Щось пішло не так. Спробуйте ще раз') {
  if (result.status === 0) return 'Немає зʼєднання з сервером';
  const msg = result.data && typeof result.data === 'object' ? result.data.message : null;
  return msg || fallback;
}

// --- методи API ---
export const authApi = {
  register: (emailAddress, password, phoneNumber) =>
    api('POST', '/api/auth/register', { emailAddress, password, phoneNumber }, { auth: false }),
  login: (emailAddress, password) =>
    api('POST', '/api/auth/login', { emailAddress, password }, { auth: false })
};

export const rolesApi = {
  list: () => api('GET', '/api/roles'),
  mine: () => api('GET', '/api/roles/my'),
  acquire: (role) => api('POST', '/api/roles/acquire', { role }),
  checkDeliverer: () => api('GET', '/api/roles/check/deliverer'),
  checkDeliveryRequester: () => api('GET', '/api/roles/check/delivery-requester')
};

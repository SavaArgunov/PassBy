import { useEffect, useState } from 'react';
import AuthFlow from './AuthFlow';
import VerifyModal from './VerifyModal';
import {
  ROLES, decodeJwt, errorMessage, getToken, isTokenValid, onUnauthorized,
  rolesApi, setToken, verificationApi,
} from './api.js';
import { readName } from './profile.js';

// UI-ролі (sender/courier) відповідають ролям бекенду
const ROLE_TO_API = { sender: ROLES.DeliveryRequester, courier: ROLES.Deliverer };
const API_TO_ROLE = { [ROLES.DeliveryRequester]: 'sender', [ROLES.Deliverer]: 'courier' };
const emptyProgress = { loaded: false, role: null, ownedRoles: [], documentValidated: false, identityVerified: false, paymentAdded: false };

// Локально зберігаємо лише те, чого немає на сервері: обрану активну роль і демо-позначку оплати
const localKey = (email) => `passby-progress:${email.toLowerCase()}`;
function readLocal(email) { try { return JSON.parse(localStorage.getItem(localKey(email)) || '{}'); } catch { return {}; } }
function writeLocal(email, patch) { try { localStorage.setItem(localKey(email), JSON.stringify({ ...readLocal(email), ...patch })); } catch { /* сховище недоступне */ } }

async function loadServerProgress(email) {
  const [rolesResult, documentsResult, statusResult] = await Promise.all([
    rolesApi.mine(), verificationApi.documents(), verificationApi.status(),
  ]);
  const ownedRoles = rolesResult.ok
    ? (rolesResult.data.roles || []).filter((role) => !role.isBlocked).map((role) => API_TO_ROLE[role.name]).filter(Boolean)
    : [];
  const local = readLocal(email);
  const attempt = statusResult.ok ? statusResult.data.lastAttempt : null;
  return {
    loaded: true,
    role: ownedRoles.includes(local.activeRole) ? local.activeRole : ownedRoles[0] ?? null,
    ownedRoles,
    documentValidated: documentsResult.ok && (documentsResult.data.documents || []).length > 0,
    identityVerified: attempt?.verificationCode === 'Succeeded' && (!attempt.validUntilUtc || new Date(attempt.validUntilUtc) > new Date()),
    paymentAdded: !!local.paymentAdded,
  };
}

function restoreAccount() {
  const token = getToken();
  if (!isTokenValid(token)) return null;
  const email = decodeJwt(token)?.email;
  return email ? { email, fullName: readName(email) || email.split('@')[0], phone: '' } : null;
}

function Dashboard({ account, progress, onProgress, onSelectRole, onRefresh, isDark, onToggleTheme, onLogout }) {
  const [modal, setModal] = useState('');
  const [toast, setToast] = useState('');
  function saveProgress(patch) { writeLocal(account.email, patch); onProgress({ ...progress, ...patch }); }
  function flash(message) { setToast(message); window.setTimeout(() => setToast(''), 3500); }
  function requestRole() { setToast('Для виконання дії підтвердіть роль.'); setModal('role'); window.setTimeout(() => setToast(''), 3200); }
  function tryAction(message) { if (!progress.role) requestRole(); else { setToast(message); window.setTimeout(() => setToast(''), 3000); } }
  const roleName = progress.role === 'sender' ? 'Відправник' : progress.role === 'courier' ? 'Кур’єр' : 'Роль не обрана';
  const verificationLabel = progress.identityVerified ? 'Особу підтверджено' : progress.documentValidated ? 'Підтвердьте особу' : 'Документ не перевірено';
  return <main className="dashboard-page">
    <header className="dashboard-header"><div className="brand"><img src="/passby-icon.png" alt=""/><b>PassBy</b></div><nav><button onClick={() => tryAction('Відкриваємо стрічку замовлень…')}>Замовлення</button><button onClick={() => tryAction('Відкриваємо профіль…')}>Профіль</button></nav><span className="account-chip">{account.fullName || account.email}</span><button className="theme-toggle" onClick={onToggleTheme}>{isDark ? '☀️ Світла' : '🌙 Темна'}</button><button className="header-link" onClick={onLogout}>Вийти</button></header>
    <div className="dashboard-content"><section className="dashboard-main">
      <div className="welcome-strip"><div><span className="eyebrow">ПЛАТФОРМА СПІЛЬНОЇ ДОСТАВКИ</span><h1>{progress.role ? `Вітаємо, ${account.fullName?.split(' ')[0] || 'у PassBy'}!` : 'Попередній макет PassBy'}</h1><p>{progress.role ? (progress.role === 'sender' ? 'Знайдіть попутного кур’єра для своєї посилки.' : 'Переглядайте посилки, які можна доставити дорогою.') : 'Оберіть роль, щоб відкрити робочий інтерфейс. Поки що це макет для ознайомлення.'}</p></div><div className="welcome-art">📦<span>↗</span>🚲</div></div>
      {!progress.role ? <div className="role-gate"><div className="gate-icon">✦</div><div><h2>Це демонстраційний макет</h2><p>Кнопки показують вигляд сервісу. Щоб створювати відправлення чи брати їх у доставку, підтвердьте роль у профілі.</p></div><button className="primary-button" onClick={() => setModal('role')}>Обрати роль</button></div> : <div className="active-role-banner"><span className="verified-mark">✓</span><div><b>Активний інтерфейс: {roleName.toLowerCase()}</b><small>Роль прив’язана до цього акаунта. Її можна змінити в налаштуваннях.</small></div><button className="quiet-button" onClick={() => setModal('role')}>Змінити роль</button></div>}
      <div className="content-heading"><div><h2>{progress.role === 'courier' ? 'Посилки поруч із вашим маршрутом' : 'Популярні напрямки'}</h2><p>{progress.role ? 'Приклади функцій платформи' : 'Попередній вигляд головного екрана'}</p></div><button className="quiet-button" onClick={() => tryAction('Список замовлень буде доступний після підключення сервісу.')}>Усі замовлення →</button></div>
      <div className="sample-grid">{[['Київ → Львів','Документи · 0,5 кг','250 ₴'],['Одеса → Київ','Невелика посилка · 1,2 кг','320 ₴'],['Львів → Дніпро','Особисті речі · 2 кг','410 ₴']].map(([route,details,price]) => <article className="sample-card" key={route}><span className="sample-icon">📍</span><div><b>{route}</b><small>{details}</small></div><strong>{price}</strong><button onClick={() => tryAction(progress.role === 'courier' ? 'Ви обрали це замовлення (демо).' : 'Створення відправлення доступне після підтвердження ролі.')}>{progress.role === 'courier' ? 'Доставити' : 'Деталі'}</button></article>)}</div>
      {!progress.role && <button className="create-order" onClick={() => tryAction('Для створення відправлення підтвердіть роль.')}>＋ Створити відправлення</button>}
    </section>
    <aside className="progress-panel"><div className="progress-title"><div><span className="eyebrow">НАЛАШТУВАННЯ ПРОФІЛЮ</span><h2>Підготовка акаунта</h2></div><span className="progress-count">{[progress.identityVerified,progress.paymentAdded,!!progress.role].filter(Boolean).length}/3</span></div>
      <button className="progress-item" onClick={() => setModal('verify')}><span className={`task-number ${progress.identityVerified?'done':''}`}>{progress.identityVerified?'✓':'1'}</span><span><b>Верифікація</b><small>{verificationLabel}</small><em>{progress.documentValidated?'Документ перевірено':'Документ і підтвердження особи'}</em></span><span className="chevron">›</span></button>
      <button className="progress-item" onClick={() => setModal('payment')}><span className={`task-number ${progress.paymentAdded?'done':''}`}>{progress.paymentAdded?'✓':'2'}</span><span><b>Спосіб оплати</b><small>{progress.paymentAdded?'Додано (демо)':'Ще не додано'}</small></span><span className="chevron">›</span></button>
      <button className="progress-item" onClick={() => setModal('role')}><span className={`task-number ${progress.role?'done':''}`}>{progress.role?'✓':'3'}</span><span><b>Вибір ролі</b><small>{roleName}</small><em>Визначає доступні можливості</em></span><span className="chevron">›</span></button><p className="demo-caption">Роль і верифікація зберігаються на сервері · спосіб оплати поки демо</p>
    </aside></div>
    {toast && <div className="toast" role="status">{toast}</div>}
    {modal && <div className="modal-backdrop" onClick={() => setModal('')}><section className="modal-card" onClick={event => event.stopPropagation()}><button className="modal-close" onClick={() => setModal('')} aria-label="Закрити">×</button>
      {modal === 'role' && <><span className="modal-kicker">КРОК 3 · ВИБІР РОЛІ</span><h2>Оберіть свою роль</h2><p>Роль визначає доступні дії: відправляти посилки чи доставляти їх попутним маршрутом. Вона прив’язується до акаунта після вибору й доступна для зміни у профілі.</p><div className="role-modal-options"><button onClick={() => {onSelectRole('sender').then(message => message && flash(message));setModal('');}}><span>📦</span><b>Я відправник</b><small>Створювати та відстежувати посилки</small></button><button onClick={() => {onSelectRole('courier').then(message => message && flash(message));setModal('');}}><span>🚲</span><b>Я кур’єр</b><small>Доставляти посилки дорогою</small></button></div></>}
      {modal === 'verify' && <VerifyModal onChanged={onRefresh} />}
      {modal === 'payment' && <><span className="modal-kicker">КРОК 2 · СПОСІБ ОПЛАТИ</span><h2>{progress.paymentAdded?'Спосіб оплати додано':'Додайте спосіб оплати'}</h2><p>Підключення платежів поки не реалізоване. Цей крок лише демонструє майбутній екран, дані картки не збираються.</p><div className="payment-placeholder">💳 <span>Банківська картка</span><small>Платіжний сервіс буде підключено пізніше</small></div>{!progress.paymentAdded ? <button className="primary-button modal-action" onClick={() => {saveProgress({paymentAdded:true});setModal('');}}>Позначити доданим (демо)</button> : <button className="quiet-button" onClick={() => {saveProgress({paymentAdded:false});setModal('');}}>Скасувати демо-позначку</button>}</>}
    </section></div>}
    <footer className="dashboard-footer">PassBy · З’єднуємо відправників і тих, кому зручно доставити дорогою</footer>
  </main>;
}

export default function App() {
  const [account, setAccount] = useState(restoreAccount);
  const [progress, setProgress] = useState(emptyProgress);
  const [notice, setNotice] = useState('');
  const [isDark, setIsDark] = useState(() => localStorage.getItem('passby-theme') === 'dark');
  const email = account?.email;

  useEffect(() => onUnauthorized(() => {
    setToken(null);
    setAccount(null);
    setProgress(emptyProgress);
    setNotice('Сесія закінчилась. Увійдіть знову.');
  }), []);

  // Після входу (або відновлення сесії) підтягуємо роль і верифікацію з сервера
  useEffect(() => {
    if (!email) return undefined;
    let active = true;
    loadServerProgress(email).then((next) => { if (active) setProgress(next); });
    return () => { active = false; };
  }, [email]);

  function enterAccount(info) { setNotice(''); setAccount(info); }
  function logout() { setToken(null); setAccount(null); setProgress(emptyProgress); setNotice(''); }
  async function refreshProgress() { if (email) setProgress(await loadServerProgress(email)); }
  async function selectRole(key) {
    const result = await rolesApi.acquire(ROLE_TO_API[key]);
    // 409 означає, що роль уже отримана: просто робимо її активною
    if (!result.ok && result.status !== 409) return errorMessage(result, 'Не вдалося зберегти роль.');
    writeLocal(email, { activeRole: key });
    await refreshProgress();
    return null;
  }
  function toggleTheme() { setIsDark(current => { const next=!current;localStorage.setItem('passby-theme',next?'dark':'light');return next; }); }

  let screen;
  if (!account) screen = <AuthFlow onComplete={enterAccount} isDark={isDark} onToggleTheme={toggleTheme} notice={notice}/>;
  else if (!progress.loaded) screen = <main className="dashboard-page"><p style={{ padding: 24 }} role="status">Завантаження…</p></main>;
  else screen = <Dashboard account={account} progress={progress} onProgress={setProgress} onSelectRole={selectRole} onRefresh={refreshProgress} isDark={isDark} onToggleTheme={toggleTheme} onLogout={logout}/>;
  return <div className={`app-theme${isDark?' theme-dark':''}`}>{screen}</div>;
}

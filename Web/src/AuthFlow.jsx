import { useState } from 'react';
import './AuthFlow.css';
import { authApi, errorMessage, setToken } from './api.js';
import { readName, saveName } from './profile.js';

const MIN_PASSWORD = 12;

// Приймає +380671234567, 380671234567, 0671234567 або 671234567
function normalizePhone(value) {
  let digits = value.replace(/\D/g, '');
  if (digits.length === 10 && digits.startsWith('0')) digits = '38' + digits;
  else if (digits.length === 9) digits = '380' + digits;
  return /^380\d{9}$/.test(digits) ? '+' + digits : null;
}

const Field = ({ label, ...props }) => <label className="auth-field">{label}<input {...props} /></label>;

export default function AuthFlow({ onComplete, isDark, onToggleTheme, notice }) {
  const [page, setPage] = useState(notice ? 'auth' : 'intro');
  const [mode, setMode] = useState(notice ? 'login' : 'register');
  const [loading, setLoading] = useState(false);
  const [fullName, setFullName] = useState('');
  const [email, setEmail] = useState('');
  const [phone, setPhone] = useState('');
  const [error, setError] = useState('');
  const update = callback => event => { setError(''); callback(event.target.value); };
  function openAuth(nextMode) { setMode(nextMode); setError(''); setPage('auth'); }
  async function submit(event) {
    event.preventDefault(); setError('');
    const form = event.currentTarget;
    const emailInput = form.querySelector('input[type="email"]');
    const password = form.querySelector('input[type="password"]');
    const nameInput = form.querySelector('[autocomplete="name"]');
    const phoneInput = form.querySelector('input[type="tel"]');
    if (mode === 'register' && fullName.trim().split(/\s+/).length < 2) { setError('Вкажіть ім’я та прізвище.'); nameInput.focus(); return; }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) { setError('Введіть коректну адресу електронної пошти.'); emailInput.focus(); return; }
    if (mode === 'register' && password.value.length < MIN_PASSWORD) { setError(`Пароль має містити щонайменше ${MIN_PASSWORD} символів.`); password.focus(); return; }
    if (mode === 'login' && !password.value) { setError('Введіть пароль.'); password.focus(); return; }
    const phoneNumber = mode === 'register' ? normalizePhone(phone) : null;
    if (mode === 'register' && !phoneNumber) { setError('Введіть номер у форматі +380 67 123 45 67.'); phoneInput.focus(); return; }

    const normalizedEmail = email.trim().toLowerCase();
    const passwordValue = password.value;
    setLoading(true);
    try {
      if (mode === 'register') {
        const registered = await authApi.register(normalizedEmail, passwordValue, phoneNumber);
        if (registered.status === 409) { setError('Користувач з таким email уже існує.'); return; }
        if (!registered.ok) { setError(errorMessage(registered, 'Не вдалося зареєструватися. Перевірте дані.')); return; }
      }
      const login = await authApi.login(normalizedEmail, passwordValue);
      if (login.status === 401) { setError('Невірний email або пароль.'); return; }
      if (login.status === 403) { setError('Акаунт заблоковано.'); return; }
      if (!login.ok || !login.data?.accessToken) { setError(errorMessage(login, 'Не вдалося увійти.')); return; }
      setToken(login.data.accessToken);
      if (mode === 'register') saveName(normalizedEmail, fullName.trim());
      onComplete({
        fullName: mode === 'register' ? fullName.trim() : readName(normalizedEmail) || normalizedEmail.split('@')[0],
        email: normalizedEmail,
        phone: phoneNumber || '',
      });
    } finally {
      setLoading(false);
    }
  }
  const themeButton = <button className="theme-toggle" type="button" onClick={onToggleTheme}>{isDark ? '☀️ Світла тема' : '🌙 Темна тема'}</button>;

  if (page === 'intro') return <main className="intro-page">
    <header className="intro-header"><a className="brand" href="#top"><img src="/passby-icon.png" alt=""/><b>PassBy</b></a><div>{themeButton}<button className="header-link" onClick={() => openAuth('login')}>Увійти</button></div></header>
    <section className="intro-hero" id="top"><div className="intro-copy"><span className="eyebrow">ПОПУТНА ДОСТАВКА ПОСИЛОК</span><h1>Посилка їде туди.<br/><em>Кур’єр — дорогою.</em></h1><p>PassBy поєднує людей, які хочуть надіслати посилку, з тими, хто вже прямує у потрібному напрямку та може доставити її дорогою.</p><div className="intro-actions"><button className="primary-button" onClick={() => openAuth('register')}>Створити акаунт <span>→</span></button><button className="quiet-button" onClick={() => openAuth('login')}>У мене вже є акаунт</button></div><div className="intro-points"><span>✓ Зручно для відправника</span><span>✓ Винагорода для кур’єра</span></div></div><div className="intro-visual"><div className="route-line"/><div className="route-point point-a">📦</div><div className="route-point point-b">🚲</div><div className="route-card"><b>Одна дорога — дві користі</b><small>Посилка знаходить попутний маршрут</small></div></div></section>
    <section className="intro-how"><div><span className="eyebrow">ЯК ЦЕ ПРАЦЮЄ</span><h2>З’єднуємо тих, кому по дорозі</h2></div><article><b>01 · Відправник</b><p>Вказує, звідки та куди потрібно доставити посилку.</p></article><article><b>02 · PassBy</b><p>Поєднує відправника з людиною на відповідному маршруті.</p></article><article><b>03 · Кур’єр</b><p>Бере посилку з собою та отримує винагороду.</p></article></section><footer className="intro-footer">PassBy · Доставка починається тут</footer>
  </main>;

  return <main className="auth-layout"><header className="auth-header"><a className="auth-brand" href="#" onClick={event => {event.preventDefault();setPage('intro');}}><img src="/passby-icon.png" alt=""/><span>PassBy</span></a><span>Сервіс попутної доставки</span>{themeButton}</header><section className="auth-panel"><button className="auth-back" onClick={() => setPage('intro')}>← На головну</button><div className="auth-step">{mode === 'register' ? 'НОВИЙ АКАУНТ' : 'ВХІД ДО PASSBY'}</div><h1>{mode === 'register' ? 'Створити акаунт' : 'З поверненням!'}</h1><p className="auth-muted">{mode === 'register' ? 'Зареєструйтеся, щоб надіслати посилку або доставити її дорогою.' : 'Увійдіть за електронною поштою та паролем.'}</p><div className="auth-tabs"><button className={mode === 'login' ? 'current' : ''} onClick={() => {setMode('login');setError('');}}>Вхід</button><button className={mode === 'register' ? 'current' : ''} onClick={() => {setMode('register');setError('');}}>Реєстрація</button></div><form className="auth-form" noValidate onSubmit={submit}>{mode === 'register' && <><Field label="Ім’я та прізвище" required autoComplete="name" placeholder="Наприклад, Анна Іваненко" value={fullName} onChange={update(setFullName)}/><Field label="Електронна пошта" required type="email" autoComplete="email" placeholder="name@example.com" value={email} onChange={update(setEmail)}/></>}{mode === 'login' && <Field label="Електронна пошта" required type="email" autoComplete="email" placeholder="name@example.com" value={email} onChange={update(setEmail)}/>}<Field label="Пароль" required type="password" minLength="12" autoComplete={mode === 'register' ? 'new-password' : 'current-password'} placeholder="Щонайменше 12 символів"/>{mode === 'register' && <Field label="Номер телефону" required type="tel" autoComplete="tel" placeholder="+380 67 123 45 67" value={phone} onChange={update(setPhone)}/>}{notice && !error && <p className="auth-error" role="status">{notice}</p>}{error && <p className="auth-error" role="alert">{error}</p>}<button className="auth-primary" type="submit" disabled={loading}>{loading ? 'Зачекайте…' : mode === 'register' ? 'Зареєструватися' : 'Увійти'} {!loading && <span>→</span>}</button></form><p className="auth-switch">{mode === 'register' ? 'Вже маєте акаунт?' : 'Ще не маєте акаунта?'} <button onClick={() => {setMode(mode === 'register' ? 'login' : 'register');setError('');}}>{mode === 'register' ? 'Увійти' : 'Зареєструватися'}</button></p><p className="auth-demo">Ім’я та прізвище поки зберігається лише на цьому пристрої: на сервері такого поля ще немає.</p></section><footer className="auth-footer">PassBy · Доставка починається тут</footer></main>;
}


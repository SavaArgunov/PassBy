import { useState } from 'react';
import Logo from '../components/Logo.jsx';
import { EyeIcon, GoogleIcon } from '../components/Icons.jsx';
import { authApi, setToken, errorMessage } from '../api.js';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const MIN_PASSWORD = 12;

function formatPhone(digits) {
  const d = digits;
  let out = '';
  if (d.length > 0) out += '(' + d.slice(0, 2);
  if (d.length >= 2) out += ')';
  if (d.length > 2) out += ' ' + d.slice(2, 5);
  if (d.length > 5) out += ' ' + d.slice(5, 7);
  if (d.length > 7) out += ' ' + d.slice(7, 9);
  return out;
}

export default function AuthPage({ onAuthenticated, notice }) {
  const [mode, setMode] = useState('register');
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [phoneDigits, setPhoneDigits] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [touched, setTouched] = useState({});
  const [serverErrors, setServerErrors] = useState({});
  const [formError, setFormError] = useState('');
  const [loading, setLoading] = useState(false);

  const isRegister = mode === 'register';

  const errors = {};
  if (isRegister && !name.trim()) errors.name = "Вкажіть імʼя та прізвище";
  if (!EMAIL_RE.test(email.trim())) errors.email = 'Некоректний формат email';
  if (isRegister && phoneDigits.length !== 9) errors.phone = 'Введіть номер у форматі (67) 123 45 67';
  if (isRegister && password.length < MIN_PASSWORD) errors.password = `Мінімум ${MIN_PASSWORD} символів`;
  if (!isRegister && !password) errors.password = 'Введіть пароль';

  const touch = (field) => setTouched((t) => ({ ...t, [field]: true }));
  const fieldError = (field) => (touched[field] && errors[field]) || serverErrors[field] || '';

  const switchMode = (next) => {
    setMode(next);
    setTouched({});
    setServerErrors({});
    setFormError('');
  };

  async function submit(e) {
    e.preventDefault();
    setFormError('');
    setServerErrors({});
    setTouched({ name: true, email: true, phone: true, password: true });
    if (Object.keys(errors).length > 0) return;

    setLoading(true);
    try {
      const normalizedEmail = email.trim().toLowerCase();
      const phone = '+380' + phoneDigits;

      if (isRegister) {
        const reg = await authApi.register(normalizedEmail, password, phone);
        if (reg.status === 409) {
          setServerErrors({ email: 'Користувач з таким email уже існує' });
          return;
        }
        if (!reg.ok) {
          setFormError(errorMessage(reg, 'Не вдалося зареєструватися'));
          return;
        }
      }

      const login = await authApi.login(normalizedEmail, password);
      if (login.status === 401) {
        setFormError('Невірний email або пароль');
        return;
      }
      if (login.status === 403) {
        setFormError('Акаунт заблоковано');
        return;
      }
      if (!login.ok || !login.data?.accessToken) {
        setFormError(errorMessage(login, 'Не вдалося увійти'));
        return;
      }

      setToken(login.data.accessToken);
      onAuthenticated({
        isNewUser: isRegister,
        name: name.trim(),
        phoneDisplay: '+380 ' + formatPhone(phoneDigits)
      });
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="auth-layout">
      <aside className="hero">
        <Logo withText />
        <h1 className="hero-title">PassBy</h1>
        <p className="hero-text">Зручна краудсорсингова доставка посилок між людьми</p>
      </aside>

      <main className="auth-main">
        <div className="auth-card">
          <div className="auth-mobile-logo">
            <Logo withText />
          </div>

          <h2 className="auth-title">{isRegister ? 'Створення акаунта' : 'Вхід в акаунт'}</h2>
          <p className="auth-subtitle">
            {isRegister ? 'Приєднуйтесь до PassBy вже сьогодні.' : 'Раді бачити вас знову.'}
          </p>

          {notice && <div className="banner banner-warn">{notice}</div>}

          <div className="tabs" role="tablist">
            <button type="button" role="tab" aria-selected={!isRegister} className={'tab' + (!isRegister ? ' active' : '')} onClick={() => switchMode('login')}>
              Вхід
            </button>
            <button type="button" role="tab" aria-selected={isRegister} className={'tab' + (isRegister ? ' active' : '')} onClick={() => switchMode('register')}>
              Реєстрація
            </button>
          </div>

          <form onSubmit={submit} noValidate>
            {isRegister && (
              <div className="field">
                <label htmlFor="name">Імʼя та прізвище</label>
                <input id="name" className={'input' + (fieldError('name') ? ' invalid' : '')} value={name} onChange={(e) => setName(e.target.value)} onBlur={() => touch('name')} placeholder="Jane Doe" autoComplete="name" />
                {fieldError('name') && <div className="field-error">{fieldError('name')}</div>}
              </div>
            )}

            <div className="field">
              <label htmlFor="email">Email</label>
              <input id="email" type="email" className={'input' + (fieldError('email') ? ' invalid' : '')} value={email} onChange={(e) => { setEmail(e.target.value); setServerErrors({}); }} onBlur={() => touch('email')} placeholder="jane@example.com" autoComplete="email" />
              {fieldError('email') && <div className="field-error">{fieldError('email')}</div>}
            </div>

            {isRegister && (
              <div className="field">
                <label htmlFor="phone">Номер телефону</label>
                <div className={'input phone-input' + (fieldError('phone') ? ' invalid' : '')}>
                  <span className="phone-prefix">+380</span>
                  <input id="phone" inputMode="numeric" value={formatPhone(phoneDigits)} onChange={(e) => setPhoneDigits(e.target.value.replace(/\D/g, '').slice(0, 9))} onBlur={() => touch('phone')} placeholder="(67) 123 45 67" autoComplete="tel-national" />
                </div>
                {fieldError('phone') && <div className="field-error">{fieldError('phone')}</div>}
              </div>
            )}

            <div className="field">
              <label htmlFor="password">Пароль</label>
              <div className={'input password-input' + (fieldError('password') ? ' invalid' : '')}>
                <input id="password" type={showPassword ? 'text' : 'password'} value={password} onChange={(e) => setPassword(e.target.value)} onBlur={() => touch('password')} autoComplete={isRegister ? 'new-password' : 'current-password'} />
                <button type="button" className="eye-btn" onClick={() => setShowPassword((v) => !v)} aria-label={showPassword ? 'Сховати пароль' : 'Показати пароль'}>
                  <EyeIcon off={showPassword} />
                </button>
              </div>
              {fieldError('password') && <div className="field-error">{fieldError('password')}</div>}
            </div>

            {formError && <div className="banner banner-error">{formError}</div>}

            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Зачекайте…' : isRegister ? 'Зареєструватися' : 'Увійти'}
            </button>
          </form>

          <div className="divider"><span>або увійдіть через</span></div>

          <button type="button" className="btn btn-outline" disabled title="Вхід через Google ще не реалізовано на бекенді">
            <GoogleIcon /> Google
          </button>

          <div className="auth-links">
            <button type="button" className="link-btn" disabled title="Відновлення пароля ще не реалізовано на бекенді">
              Забули пароль?
            </button>
            <p className="muted">
              {isRegister ? 'Вже є акаунт?' : 'Немає акаунта?'}{' '}
              <button type="button" className="link-btn strong" onClick={() => switchMode(isRegister ? 'login' : 'register')}>
                {isRegister ? 'Увійти' : 'Зареєструватися'}
              </button>
            </p>
          </div>
        </div>
      </main>
    </div>
  );
}

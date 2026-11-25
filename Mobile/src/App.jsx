import { useEffect, useRef, useState } from 'react'

const sampleOrders = [
  { id: 'PB-1048', from: 'Київ', to: 'Львів', route: 'Київ → Львів', item: 'Документи', size: '0,5 кг', price: 250, courier: 'Марко', time: 'Сьогодні, 14:30', ownerType: 'sender' },
  { id: 'PB-1051', from: 'Одеса', to: 'Київ', route: 'Одеса → Київ', item: 'Невелика посилка', size: '1,2 кг', price: 320, courier: 'Олена', time: 'Завтра, 09:00', ownerType: 'courier' },
  { id: 'PB-1055', from: 'Львів', to: 'Дніпро', route: 'Львів → Дніпро', item: 'Особисті речі', size: '2 кг', price: 410, courier: 'Андрій', time: 'Завтра, 11:20', ownerType: 'sender' },
]

const orderPool = [
  ...sampleOrders,
  ...sampleOrders.flatMap((order, routeIndex) => Array.from({ length: 23 }, (_, index) => ({
    ...order,
    id: `PB-${1100 + routeIndex * 100 + index}`,
    price: order.price + ((index % 5) - 2) * 10,
    ownerType: (index + routeIndex) % 2 ? 'courier' : 'sender',
    courier: ['Марко', 'Олена', 'Андрій', 'Ірина', 'Дмитро'][index % 5],
  }))),
]

function shuffleOrders(orders) {
  const shuffled = [...orders]
  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const other = Math.floor(Math.random() * (index + 1))
    ;[shuffled[index], shuffled[other]] = [shuffled[other], shuffled[index]]
  }
  return shuffled
}

const progressEmpty = { documentValidated: false, identityVerified: false, paymentAdded: false, role: null, roles: [] }
const mockDocumentOwner = 'Ярослав Коваленко'

async function passwordDigest(value) {
  const bytes = new TextEncoder().encode(value)
  if (globalThis.crypto?.subtle) {
    const digest = await globalThis.crypto.subtle.digest('SHA-256', bytes)
    return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')
  }
  let hash = 2166136261
  for (const byte of bytes) hash = Math.imul(hash ^ byte, 16777619)
  return `demo-${(hash >>> 0).toString(16)}`
}

function saved(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback } catch { return fallback }
}

function normalizeProgress(value) {
  const next = { ...progressEmpty, ...value }
  next.roles = Array.isArray(next.roles) ? [...new Set(next.roles)] : next.role ? [next.role] : []
  if (!next.identityVerified) {
    next.paymentAdded = false
    next.role = null
    next.roles = []
  } else if (!next.paymentAdded) {
    next.role = null
    next.roles = []
  }
  if (next.role && !next.roles.includes(next.role)) next.roles.push(next.role)
  return next
}

function Brand() {
  return <div className="brand"><img className="brand-mark" src="/passby-icon.png" alt="" /><b>PassBy</b></div>
}

function PageHeader({ title, back, right, backLabel = 'Назад', backIcon = '/figma-assets/login-icon.svg' }) {
  return <header className={`topbar ${title ? 'topbar-with-title' : ''}`}>
    <div className="brand-row"><Brand />{!title && right}</div>
    {title && <div className="topbar-title"><button className="plain-button back-button" onClick={back}><img src={backIcon} alt="" /><span>{backLabel}</span></button><b>{title}</b></div>}
  </header>
}

function Footer({ text = 'PassBy · Доставка починається тут' }) {
  return <footer className="footer">{text}<span className="gesture" /></footer>
}

function Button({ children, kind = 'primary', className = '', ...props }) {
  return <button className={`button ${kind} ${className}`.trim()} {...props}>{children}</button>
}

function Field({ label, ...props }) {
  return <label className="field"><span>{label}</span><input required {...props} /></label>
}

function Intro({ onRegister, onLogin }) {
  return <main className="screen intro-screen">
    <PageHeader right={<Button kind="outline compact" onClick={onLogin}>Увійти</Button>} />
    <section className="intro-hero">
      <span className="eyebrow">ПОПУТНА ДОСТАВКА ПОСИЛОК</span>
      <h1>Посилка їде туди.<br /><em>Кур’єр — дорогою.</em></h1>
      <p>PassBy поєднує людей, які хочуть надіслати посилку, з тими, хто вже прямує у потрібному напрямку та може доставити її дорогою.</p>
    </section>
    <Button className="wide" onClick={onRegister}>Створити акаунт <span>→</span></Button>
    <Button kind="secondary wide" onClick={onLogin}>У мене вже є акаунт</Button>
    <div className="benefits"><span>✓ Зручно для відправника</span><span>✓ Винагорода для кур’єра</span></div>
    <RouteArt />
    <section className="how-section"><span className="eyebrow">ЯК ЦЕ ПРАЦЮЄ</span><h2>З’єднуємо тих, кому по дорозі</h2>
      {[['01','Відправник','Вказує, звідки та куди потрібно доставити посилку.'],['02','PassBy','Поєднує відправника з людиною на відповідному маршруті.'],['03','Кур’єр','Бере посилку з собою та отримує винагороду.']].map(([n, title, body]) => <article className="how-card" key={n}><span>{n}</span><div><b>{title}</b><p>{body}</p></div></article>)}
    </section>
    <Footer />
  </main>
}

function RouteArt() {
  return <div className="route-art" aria-label="Посилка рухається до кур’єра">
    <div className="route-dash" /><div className="route-stop package"><img src="/figma-assets/intro-icon.svg" alt="" /></div><div className="route-stop bike"><span className="bike-icon"><img className="wheel" src="/figma-assets/intro-imgWheels.svg" alt="" /><img className="bike-frame" src="/figma-assets/intro-imgFrame.svg" alt="" /><img className="bike-fork" src="/figma-assets/intro-imgHandlebarAndFork.svg" alt="" /><img className="bike-seat" src="/figma-assets/intro-imgSeat.svg" alt="" /></span></div>
    <div className="route-caption"><b>Одна дорога — дві користі</b><small>Посилка знаходить попутний маршрут</small></div>
  </div>
}

function Auth({ mode, setMode, onBack, onRegister, onLogin, initialEmail = '', registrationNotice = false }) {
  const [email, setEmail] = useState('')
  const [phone, setPhone] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const registering = mode === 'register'
  async function submit(e) {
    e.preventDefault()
    setError('')
    const normalizedEmail = email.trim().toLowerCase()
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail)) return setError('Введіть коректну адресу електронної пошти.')
    if (password.length < 8) return setError('Пароль має містити щонайменше 8 символів.')
    if (registering && !phone.trim()) return setError('Введіть номер телефону.')
    try {
      const passwordHash = await passwordDigest(password)
      registering ? onRegister({ email: normalizedEmail, phone: phone.trim(), passwordHash }) : onLogin(normalizedEmail, passwordHash, setError)
    } catch {
      setError('Не вдалося виконати дію. Спробуйте ще раз.')
    }
  }
  useEffect(() => { if (initialEmail) setEmail(initialEmail) }, [initialEmail])
  return <main className="screen auth-screen"><PageHeader title={registering ? 'Реєстрація' : 'Вхід'} back={onBack} backLabel="На головну" backIcon={registering ? '/figma-assets/register-icon.svg' : '/figma-assets/login-icon.svg'} />
    <section className="auth-hero"><span className="eyebrow">{registering ? 'НОВИЙ АКАУНТ' : 'ВХІД ДО PASSBY'}</span><h1>{registering ? 'Створити акаунт' : 'З поверненням!'}</h1><p>{registering ? 'Зареєструйтеся, щоб надіслати посилку або доставити її дорогою.' : 'Увійдіть за електронною поштою та паролем.'}</p></section>
    {!registering && registrationNotice && <p className="success-note" role="status">Номер підтверджено. Увійдіть, щоб продовжити підготовку акаунта.</p>}
    <form id="auth-form" className="form-card" onSubmit={submit} noValidate>
      <div className="segmented"><button type="button" className={!registering ? 'selected' : ''} onClick={() => { setMode('login'); setError('') }}>Вхід</button><button type="button" className={registering ? 'selected' : ''} onClick={() => { setMode('register'); setError('') }}>Реєстрація</button></div>
      <Field label="Електронна пошта" type="email" autoComplete="email" value={email} onChange={e => setEmail(e.target.value)} placeholder="name@example.com" />
      <Field label="Пароль" type="password" autoComplete={registering ? 'new-password' : 'current-password'} value={password} onChange={e => setPassword(e.target.value)} placeholder="Щонайменше 8 символів" />
      {registering && <Field label="Номер телефону" type="tel" autoComplete="tel" value={phone} onChange={e => setPhone(e.target.value)} placeholder="+380 67 123 45 67" />}
      {error && <p className="error" role="alert">{error}</p>}
    </form>
    <p className="switch-copy">{registering ? 'Вже маєте акаунт?' : 'Ще не маєте акаунта?'} <button type="button" onClick={() => { setMode(registering ? 'login' : 'register'); setError('') }}>{registering ? 'Увійти' : 'Зареєструватися'}</button></p>
    <div className="auth-bottom"><Button className="wide" type="submit" form="auth-form">{registering ? 'Зареєструватися' : 'Увійти'} →</Button><Footer /></div>
  </main>
}

function Confirmation({ phone, onConfirm, onBack }) {
  const [code, setCode] = useState('842')
  const [error, setError] = useState('')
  const inputRefs = useRef([])
  function changeDigit(index, value) {
    const digit = value.replace(/\D/g, '').slice(-1)
    setCode(current => { const next = current.padEnd(4, ' ').split(''); next[index] = digit || ' '; return next.join('').trimEnd() })
    setError('')
    if (digit && index < 3) inputRefs.current[index + 1]?.focus()
  }
  return <main className="screen auth-screen confirmation-screen"><PageHeader title="Підтвердження" back={onBack} backIcon="/figma-assets/confirmation-icon.svg" />
    <section className="auth-hero"><h1>Підтвердження номера</h1><p>Введіть 4-значний код, надісланий на {phone}</p></section>
    <form id="confirmation-form" className="form-card otp-form" onSubmit={e => { e.preventDefault(); code === '8420' ? onConfirm() : setError('Демо-код: 8420.') }}>
      <div className="otp">{[0, 1, 2, 3].map(index => <input key={index} ref={node => { inputRefs.current[index] = node }} aria-label={`Цифра ${index + 1}`} inputMode="numeric" maxLength={1} value={(code[index] || '').trim()} onChange={e => changeDigit(index, e.target.value)} onKeyDown={e => { if (e.key === 'Backspace' && !code[index] && index > 0) inputRefs.current[index - 1]?.focus() }} />)}</div><p className="muted center">Надіслати код повторно через 00:59</p>{error && <p className="error" role="alert">{error}</p>}
    </form><div className="auth-bottom"><Button className="wide" type="submit" form="confirmation-form">Підтвердити</Button><Footer text="PassBy · З’єднуємо відправників і тих, кому зручно доставити дорогою" /></div>
  </main>
}

function nextSetupAction(progress) {
  if (!progress.identityVerified) return 'verification'
  if (!progress.paymentAdded) return 'setup-payment'
  if (!progress.role) return 'role'
  return null
}

function isSetupComplete(progress) {
  return Boolean(progress.identityVerified && progress.paymentAdded && progress.role)
}

function Progress({ progress, open, activeAction }) {
  const steps = [
    ['Верифікація', progress.identityVerified ? 'Документ перевірено' : progress.documentValidated ? 'Підтвердьте особу' : 'Документ не перевірено', 'verification'],
    ['Спосіб оплати', progress.paymentAdded ? 'Картку додано' : 'Ще не додано', 'setup-payment'],
    ['Вибір ролі', progress.role ? `Активна роль: ${roleName(progress.role)}` : 'Роль не обрана', 'role'],
  ]
  const count = [progress.identityVerified, progress.paymentAdded, !!progress.role].filter(Boolean).length
  return <section className="progress-card"><div className="progress-heading"><div><span className="eyebrow">НАЛАШТУВАННЯ ПРОФІЛЮ</span><h2>Підготовка акаунта</h2></div><b>{count}/3</b></div>
    <div className="setup-progress" role="progressbar" aria-label="Підготовка акаунта" aria-valuemin="0" aria-valuemax="3" aria-valuenow={count}><span style={{ width: `${count / 3 * 100}%` }} /></div>
    {steps.map(([title, detail, action], i) => {
      const done = i === 0 ? progress.identityVerified : i === 1 ? progress.paymentAdded : !!progress.role
      const available = action === activeAction
      return <button className="progress-row" key={title} disabled={!available} onClick={() => open(action)}>
        <span className={`step-number ${done ? 'done' : ''}`}>{done ? <img src={`/figma-assets/home-active-imgCheck${i || ''}.svg`} alt="" /> : i + 1}</span>
        <span><b>{title}</b><small>{detail}</small>{i === 0 && <em>Документ і підтвердження особи</em>}{i === 1 && !progress.identityVerified && <em>Доступно після верифікації</em>}{i === 2 && <em>{progress.paymentAdded ? 'Визначає доступні можливості' : 'Доступно після додавання картки'}</em>}</span>
        {available && <img className="chevron-icon" src={`/figma-assets/home-setup-imgChevron${i || ''}.svg`} alt="" />}
      </button>
    })}
  </section>
}

function roleName(role) { return role === 'courier' ? 'Кур’єр' : role === 'sender' ? 'Замовник' : '' }

function Home({ account, progress, open, onProfile, onOrder, toast, searchResults, onSearch, onClearSearch, isRegistered }) {
  const [visibleCount, setVisibleCount] = useState(3)
  const [randomOrders] = useState(() => shuffleOrders(orderPool))
  const setupComplete = isSetupComplete(progress)
  const activeAction = nextSetupAction(progress)
  const registeredHome = setupComplete
  const firstName = account.fullName?.trim().split(/\s+/)[0] || 'Ярослав'
  const listedOrders = searchResults?.items || randomOrders
  const listKey = searchResults?.key || 'random'
  useEffect(() => { setVisibleCount(searchResults ? 10 : 3) }, [listKey])
  return <main className="screen home-screen" data-screen={isRegistered ? 'registered-home' : 'home'}><PageHeader right={setupComplete ? <button className="avatar" aria-label="Профіль" onClick={onProfile}>Я</button> : <button className="locked-profile" aria-label="Профіль недоступний до завершення підготовки акаунта" onClick={() => toast('Завершіть верифікацію, додайте картку та оберіть роль, щоб відкрити профіль.')}><img src="/figma-assets/home-setup-icon.svg" alt="" /></button>} />
    {!setupComplete && <Progress progress={progress} open={open} activeAction={activeAction} />}
    {registeredHome ? <section className="welcome-card home-ready-card"><span className="eyebrow">ПЛАТФОРМА СПІЛЬНОЇ ДОСТАВКИ</span><h1>Вітаємо, {firstName}!</h1><p>Переглядайте посилки, які можна доставити дорогою.</p><img className="welcome-art" src="/figma-assets/home-ready-icon.svg" alt="" /></section> : <section className="welcome-card role-welcome"><span className="eyebrow">ПЛАТФОРМА СПІЛЬНОЇ ДОСТАВКИ</span><h1>{progress.role ? `Вітаємо, ${firstName}!` : 'Оберіть свою роль'}</h1><p>{progress.role ? 'Надсилайте посилки або доставляйте їх дорогою.' : 'Надсилайте посилки або доставляйте їх дорогою. Оберіть, як користуватися PassBy.'}</p><img className="welcome-art people-art" src="/role-exchange.png" alt="Замовник і кур’єр обмінюються посилкою" /></section>}
    {!progress.role && <section className="hint-card"><b>Почніть із вибору ролі</b><p>Відправник — надсилайте посилки.<br />Кур’єр — доставляйте їх дорогою.<br />Оберіть роль, щоб почати.</p><Button disabled={activeAction !== 'role'} onClick={() => open('role')}>Обрати роль</Button></section>}
    <section className="popular-section"><div className="section-heading"><div><h2>Замовлення інших</h2>{searchResults && <p>Результати пошуку · {searchResults.route}</p>}</div><div className="section-heading-actions">{searchResults && <button className="clear-search-button" onClick={onClearSearch}>Скинути</button>}<button className="search-icon-button" aria-label="Пошук замовлень" onClick={() => onSearch()}><img src="/figma-assets/home-ready-imgSearch.svg" alt="" /></button></div></div>
      {listedOrders.slice(0, visibleCount).map((order, i) => <article className="order-card" key={order.id} onClick={() => onOrder(order)}><span className="location-icon"><img src={`/figma-assets/home-ready-imgPin${i % 3 || ''}.svg`} alt="" /></span><div>{!registeredHome && <span className={`order-type-badge ${order.ownerType}`}>{order.ownerType === 'courier' ? 'Кур’єр' : 'Замовник'}</span>}<b>{order.route}</b><small>{order.item} · {order.size}</small><button className="pill-button" onClick={e => { e.stopPropagation(); onOrder(order) }}>{registeredHome ? 'Доставити' : 'Переглянути деталі'}</button></div><strong>{order.price} ₴</strong></article>)}
      {visibleCount < listedOrders.length && <button className="show-more-button" onClick={() => setVisibleCount(count => Math.min(count + 10, listedOrders.length))}>Показати ще <span>+10</span></button>}
    </section>
    {registeredHome ? <div className="home-actions"><Button kind="outline" onClick={() => toast('Створення посилки буде доступне після підключення сервера.')}><img className="home-action-icon" src="/figma-assets/home-ready-img1.svg" alt="" />+ Посилка</Button><Button onClick={() => toast('Створення замовлення буде доступне після підключення сервера.')}>+ Замовлення</Button></div> : <Button className="wide" onClick={() => progress.role ? toast('Створення відправлення доступне після підключення сервера.') : toast('Для виконання дії підтвердіть роль.')}>＋ Створити відправлення</Button>}
    <Footer text="PassBy · З’єднуємо відправників і тих, кому зручно доставити дорогою" />
  </main>
}

function Verification({ account, progress, onBack, onUpdate }) {
  const [number, setNumber] = useState('')
  const [error, setError] = useState('')
  function submitDocument(e) {
    e.preventDefault()
    const normalized = number.replace(/\s+/g, '').toUpperCase()
    if (!/^(?:[A-ZА-ЯІЇЄҐ]{2}\d{6}|\d{9})$/u.test(normalized)) {
      setError('Введіть номер у форматі AA123456 або дев’ять цифр.')
      return
    }
    setNumber(normalized)
    onUpdate({ documentValidated: true })
  }
  return <main className="screen form-screen"><PageHeader title="Верифікація" back={onBack} backIcon={progress.documentValidated ? '/figma-assets/verification-end-icon.svg' : '/figma-assets/verification-start-icon.svg'} />
    <section className="auth-hero"><span className="eyebrow">КРОК 1 · ВЕРИФІКАЦІЯ</span><h1>{progress.identityVerified ? 'Особу підтверджено' : progress.documentValidated ? 'Це ваші дані?' : 'Перевірка документа'}</h1><p>{progress.documentValidated ? 'Чи належать ці дані вам?' : 'Введіть тестовий номер документа, щоб побачити дані. Це демонстраційна перевірка.'}</p></section>
    {progress.documentValidated ? <section className="form-card verification-result"><div className="success-note">Дані документа підтверджено</div><small>Власник документа</small><b>{mockDocumentOwner}</b></section> : <form id="verification-form" className="form-card" onSubmit={submitDocument} noValidate><Field label="Номер документа" value={number} onChange={e => { setNumber(e.target.value); setError('') }} placeholder="Наприклад, AA123456" autoComplete="off" autoCapitalize="characters" />{error && <p className="error" role="alert">{error}</p>}</form>}
    {progress.documentValidated && !progress.identityVerified ? <div className="auth-bottom"><Button className="wide" onClick={() => onUpdate({ identityVerified: true, verifiedFullName: mockDocumentOwner })}>Так, це я</Button><Button kind="secondary wide" onClick={() => onUpdate({ documentValidated: false })}>Ні, перевірити інший</Button><Footer text="PassBy · З’єднуємо відправників і тих, кому зручно доставити дорогою" /></div> : !progress.documentValidated ? <div className="auth-bottom"><Button className="wide" type="submit" form="verification-form">Перевірити документ</Button><Footer text="PassBy · З’єднуємо відправників і тих, кому зручно доставити дорогою" /></div> : <Footer />}
  </main>
}

function SetupPayment({ onBack, onSave }) {
  const [card, setCard] = useState('4242424242424242')
  return <main className="screen form-screen"><PageHeader title="Спосіб оплати" back={onBack} backIcon="/figma-assets/payment-icon.svg" /><section className="auth-hero"><h1>Платіжна картка</h1><p>Додайте картку для оплати доставок у PassBy.</p></section><form id="payment-form" className="form-card payment-form" onSubmit={e => { e.preventDefault(); onSave() }}><Field label="Номер картки" inputMode="numeric" value={card.replace(/(\d{4})(?=\d)/g, '$1 ')} onChange={e => setCard(e.target.value.replace(/\D/g, '').slice(0, 16))} placeholder="4242 4242 4242 4242" /><div className="split-fields"><Field label="Термін дії (MM/YY)" defaultValue="08/28" /><Field label="CVC/CVV" inputMode="numeric" defaultValue="123" /></div><Field label="Ім’я на картці" defaultValue="Jane Doe" /></form><div className="auth-bottom"><Button className="wide" type="submit" form="payment-form">Зберегти картку</Button><Footer text="PassBy · З’єднуємо відправників і тих, кому зручно доставити дорогою" /></div></main>
}

function Role({ current, onBack, onSave }) {
  const [role, setRole] = useState(current || 'sender')
  return <main className="screen form-screen"><PageHeader title="Роль" back={onBack} backIcon="/figma-assets/role-icon.svg" /><section className="auth-hero"><h1>Оберіть вашу роль</h1><p>Ви можете змінити або поєднувати ролі пізніше в профілі.</p></section><div className="role-options"><button className={`role-option role-select ${role === 'sender' ? 'active' : ''}`} onClick={() => setRole('sender')}><span><img src="/figma-assets/role-imgPackage.svg" alt="" /></span><b>Замовник</b><small>Хочу надсилати посилки та знаходити попутних кур’єрів</small></button><button className={`role-option role-select ${role === 'courier' ? 'active' : ''}`} onClick={() => setRole('courier')}><span><img src="/figma-assets/role-imgRoute.svg" alt="" /></span><b>Кур’єр</b><small>Планую поїздки та хочу заробляти на доставці по дорозі</small></button></div><div className="auth-bottom"><Button className="wide" onClick={() => onSave(role)}>Продовжити</Button><Footer text="PassBy · З’єднуємо відправників і тих, кому зручно доставити дорогою" /></div></main>
}

function Profile({ account, progress, onBack, open, onLogout, onToast, onRoleChange }) {
  const [activeRole, setActiveRole] = useState(progress.role || 'sender')
  const roles = progress.roles?.length ? progress.roles : progress.role ? [progress.role] : []
  function chooseRole(role) { setActiveRole(role); onRoleChange(role) }
  return <main className="screen form-screen profile-screen"><PageHeader title="Мій профіль" back={onBack} backIcon="/figma-assets/profile-imgArrow.svg" />
    <section className="profile-user-card"><div className="profile-avatar-wrap"><span className="profile-picture">{account.fullName?.slice(0, 1).toUpperCase() || 'Я'}</span><img className="profile-camera" src="/figma-assets/profile-imgCamera.svg" alt="" /></div><h1>{account.fullName || 'Ярослав Коваленко'}</h1><span className="verified"><img src="/figma-assets/profile-imgCheck.svg" alt="" /> Особу підтверджено</span><div className="profile-rating"><b>★ 4.95 (48 відгуків)</b><small>На PassBy з жовтня 2026</small></div></section>
    <section className="profile-activity-card"><small className="profile-section-label">Активна роль · {roles.length}/2</small><div className="profile-role-switch"><button className={`${activeRole === 'sender' ? 'selected' : ''} ${roles.includes('sender') ? 'role-added' : 'add-role'}`} onClick={() => chooseRole('sender')}>{roles.includes('sender') ? 'Я Замовник' : '＋ Додати замовника'}</button><button className={`${activeRole === 'courier' ? 'selected' : ''} ${roles.includes('courier') ? 'role-added' : 'add-role'}`} onClick={() => chooseRole('courier')}>{roles.includes('courier') ? 'Я Кур’єр' : '＋ Додати кур’єра'}</button></div><button className="profile-row" onClick={() => onToast('Ваші посилки з’являться тут.')}><span className="profile-row-icon"><img src="/figma-assets/profile-imgBox.svg" alt="" /></span><span><b>Мої посилки</b><small>Активні відправлення</small></span><em>2</em><img className="profile-chevron" src="/figma-assets/profile-imgChevron.svg" alt="" /></button><button className="profile-row" onClick={() => onToast('Ваші замовлення з’являться тут.')}><span className="profile-row-icon"><img src="/figma-assets/profile-imgOrders.svg" alt="" /></span><span><b>Мої замовлення</b><small>Доставки у виконанні</small></span><img className="profile-chevron" src="/figma-assets/profile-imgChevron.svg" alt="" /></button></section>
    <section className="profile-stats"><article><b>12</b><small>Відправлень</small></article><article><b>36</b><small>Доставок</small></article><article><b>100%</b><small>Вчасно</small></article></section>
    <section className="profile-data-card"><div className="profile-data-heading"><b>Особисті дані</b><button onClick={() => onToast('Редагування даних буде доступне пізніше.')}>Редагувати дані</button></div><div><small>Телефон</small><b>{account.phone || '+380 (67) 123-45-67'}</b><img src="/figma-assets/profile-imgCheck.svg" alt="Підтверджено" /></div><div><small>Email</small><b>{account.email}</b></div><div><small>Місто</small><b>Київ</b></div></section>
    <section className="profile-menu-card"><button className="profile-row" onClick={() => open('setup-payment')}><span className="profile-row-icon"><img src="/figma-assets/profile-imgWallet.svg" alt="" /></span><span><b>Гаманець та виплати</b></span><em>1 450 грн</em><img className="profile-chevron" src="/figma-assets/profile-imgChevron.svg" alt="" /></button><button className="profile-row" onClick={() => onToast('Способи пересування з’являться тут.')}><span className="profile-row-icon"><img src="/figma-assets/profile-imgCar.svg" alt="" /></span><span><b>Способи пересування</b><small>Авто / Пішки</small></span><img className="profile-chevron" src="/figma-assets/profile-imgChevron.svg" alt="" /></button><button className="profile-row" onClick={() => open('verification')}><span className="profile-row-icon"><img src="/figma-assets/profile-imgShield.svg" alt="" /></span><span><b>Безпека та верифікація</b></span><img className="profile-chevron" src="/figma-assets/profile-imgChevron.svg" alt="" /></button></section>
    <Button kind="danger wide" onClick={onLogout}><img className="logout-icon" src="/figma-assets/profile-imgLogout.svg" alt="" />Вийти з акаунту</Button><Footer />
  </main>
}

function Search({ onBack, toast, onSearchResults }) {
  const [side, setSide] = useState('sender')
  const [orderId, setOrderId] = useState(sampleOrders[0].id)
  const order = sampleOrders.find(item => item.id === orderId) || sampleOrders[0]
  return <main className="screen form-screen search-screen"><PageHeader title="Пошук" back={onBack} backIcon="/figma-assets/search-icon.svg" />
    <div className="segmented"><button className={side === 'sender' ? 'selected' : ''} onClick={() => setSide('sender')}>Замовник</button><button className={side === 'courier' ? 'selected' : ''} onClick={() => setSide('courier')}>Кур’єр</button></div>
    <label className="field search-order-select"><span>Моє замовлення</span><select value={orderId} onChange={e => setOrderId(e.target.value)}>{sampleOrders.map(item => <option key={item.id} value={item.id}>{item.id} · {item.route}</option>)}</select></label>
    <section className="hint-card search-intro"><b>{side === 'sender' ? 'Пошук за замовленням' : 'Пошук поїздки'}</b><p>{side === 'sender' ? 'Використаємо маршрут і параметри посилки з вашого існуючого замовлення.' : 'Знайдемо замовників, яким підходить ваш маршрут.'}</p></section>
    <section className="search-order-card"><span className="eyebrow">МОЄ ЗАМОВЛЕННЯ</span><h2>{order.route}</h2><small>Посилка</small><b>{order.item === 'Документи' ? 'Ноутбук MacBook Pro 16' : order.item}</b><div className="package-size"><small>Вага та габарити</small><b>{order.size === '0,5 кг' ? '2,5 кг · 40 × 30 × 10 см' : `${order.size} · 30 × 20 × 10 см`}</b></div><div className="search-place"><small>Звідки</small><b>{order.from}{order.from === 'Київ' ? ', Вокзальна пл., 1' : ''}</b></div><div className="search-place"><small>Куди</small><b>{order.to}{order.to === 'Львів' ? ', пл. Ринок, 1' : ''}</b></div></section>
    <section className="hint-card search-empty"><b>Не знайшли відповідного {side === 'sender' ? 'кур’єра' : 'замовника'}?</b><p>Після пошуку можна розширити результати: залишити лише вагу або перевірити всі три габарити посилки разом.</p></section>
    <div className="search-bottom"><Button className="wide" onClick={() => { onSearchResults(orderPool.filter(item => item.route === order.route), order.route); onBack() }}>Знайти {side === 'sender' ? 'кур’єра' : 'замовника'}</Button><Button kind="secondary wide" onClick={onBack}>Скасувати</Button><Footer text="PassBy · З’єднуємо відправників і тих, кому зручно доставити дорогою" /></div>
  </main>
}

export default function App() {
  const [screen, setScreen] = useState('intro')
  const [authMode, setAuthMode] = useState('register')
  const [account, setAccount] = useState(null)
  const [loginEmail, setLoginEmail] = useState('')
  const [registrationNotice, setRegistrationNotice] = useState(false)
  const [pending, setPending] = useState(null)
  const [progress, setProgress] = useState(progressEmpty)
  const [toastText, setToastText] = useState('')
  const [searchResults, setSearchResults] = useState(null)
  useEffect(() => { if (!toastText) return; const id = setTimeout(() => setToastText(''), 2800); return () => clearTimeout(id) }, [toastText])
  const toast = value => setToastText(value)
  function enter(info) {
    setAccount(info)
    const nextProgress = normalizeProgress(saved(`passby-progress:${info.email}`, progressEmpty))
    setProgress(nextProgress)
    setScreen(isSetupComplete(nextProgress) ? 'registered-home' : 'home')
  }
  function goHome() { setScreen(isSetupComplete(progress) ? 'registered-home' : 'home') }
  function open(action) {
    const requiredAction = nextSetupAction(progress)
    if (requiredAction && ['verification', 'setup-payment', 'role'].includes(action) && action !== requiredAction) {
      const requiredLabel = requiredAction === 'verification' ? 'верифікацію' : requiredAction === 'setup-payment' ? 'додавання способу оплати' : 'вибір ролі'
      toast(`Спочатку завершіть ${requiredLabel}.`)
      return
    }
    setScreen(action)
  }
  function saveProgress(patch) {
    if (patch.identityVerified && !progress.documentValidated) { toast('Спочатку перевірте документ.'); return }
    if (patch.paymentAdded && !progress.identityVerified) { toast('Спочатку завершіть верифікацію.'); return }
    if (patch.role && (!progress.identityVerified || !progress.paymentAdded)) { toast('Спочатку завершіть верифікацію та додайте картку.'); return }
    const { verifiedFullName, ...progressPatch } = patch
    const next = normalizeProgress({ ...progress, ...progressPatch })
    setProgress(next)
    if (account?.email) localStorage.setItem(`passby-progress:${account.email}`, JSON.stringify(next))
    if (verifiedFullName && account?.email) {
      const updatedAccount = { ...account, fullName: verifiedFullName }
      setAccount(updatedAccount)
      localStorage.setItem(`passby-account:${account.email}`, JSON.stringify(updatedAccount))
    }
    if (patch.identityVerified || patch.paymentAdded || patch.role) setScreen(isSetupComplete(next) ? 'registered-home' : 'home')
  }
  function updateProfileRole(role) {
    const existingRoles = progress.roles?.length ? progress.roles : progress.role ? [progress.role] : []
    const roles = existingRoles.includes(role) ? existingRoles : existingRoles.length < 2 ? [...existingRoles, role] : existingRoles
    const next = { ...progress, role, roles }
    setProgress(next)
    if (account?.email) localStorage.setItem(`passby-progress:${account.email}`, JSON.stringify(next))
  }
  function login(email, passwordHash, setError) { const stored = saved(`passby-account:${email}`, null); if (!stored) return setError('Акаунт не знайдено. Спочатку створіть його.'); if (stored.passwordHash !== passwordHash) return setError('Неправильний пароль. Спробуйте ще раз.'); setRegistrationNotice(false); enter(stored) }
  let view
  if (screen === 'intro') view = <Intro onRegister={() => { setAuthMode('register'); setScreen('auth') }} onLogin={() => { setAuthMode('login'); setScreen('auth') }} />
  else if (screen === 'auth') view = <Auth mode={authMode} setMode={setAuthMode} onBack={() => setScreen('intro')} onRegister={info => { setPending(info); setScreen('confirmation') }} onLogin={login} initialEmail={loginEmail} registrationNotice={registrationNotice} />
  else if (screen === 'confirmation') view = <Confirmation phone={pending?.phone} onBack={() => setScreen('auth')} onConfirm={() => { const verified = { ...pending, phoneVerified: true }; localStorage.setItem(`passby-account:${verified.email}`, JSON.stringify(verified)); localStorage.setItem(`passby-progress:${verified.email}`, JSON.stringify(progressEmpty)); setLoginEmail(verified.email); setRegistrationNotice(true); setPending(null); setAccount(null); setProgress({ ...progressEmpty }); setAuthMode('login'); setScreen('auth') }} />
  else if (screen === 'home' || screen === 'registered-home') view = <Home account={account || { fullName: 'Ярослав Коваленко' }} progress={progress} open={open} onProfile={() => setScreen('profile')} onOrder={() => toast('Деталі замовлення поки недоступні.')} toast={toast} searchResults={searchResults} onSearch={() => setScreen('search')} onClearSearch={() => setSearchResults(null)} isRegistered={screen === 'registered-home'} />
  else if (screen === 'verification') view = <Verification account={account || { fullName: 'Користувач' }} progress={progress} onBack={goHome} onUpdate={saveProgress} />
  else if (screen === 'setup-payment') view = <SetupPayment onBack={goHome} onSave={() => saveProgress({ paymentAdded: true })} />
  else if (screen === 'role') view = <Role current={progress.role} onBack={goHome} onSave={role => saveProgress({ role })} />
  else if (screen === 'profile') view = <Profile account={account || { fullName: 'Ярослав Коваленко', email: 'yaroslav.k@gmail.com', phone: '+380 (67) 123-45-67' }} progress={progress} onBack={goHome} open={open} onLogout={() => { setAccount(null); setProgress(progressEmpty); setScreen('intro') }} onToast={toast} onRoleChange={updateProfileRole} />
  else if (screen === 'search') view = <Search onBack={goHome} toast={toast} onSearchResults={(items, route) => setSearchResults({ items, route, key: `search-${Date.now()}` })} />
  return <div className="app-shell">{view}{toastText && <div className="toast" role="status">{toastText}</div>}</div>
}

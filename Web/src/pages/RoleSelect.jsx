import { useState } from 'react';
import StepHeader from '../components/StepHeader.jsx';
import { BoxIcon, RouteIcon } from '../components/Icons.jsx';
import { rolesApi, ROLES, errorMessage } from '../api.js';

const OPTIONS = [
  {
    role: ROLES.DeliveryRequester,
    title: 'Відправник',
    text: 'Хочу надсилати посилки та знаходити попутних кур’єрів',
    Icon: BoxIcon
  },
  {
    role: ROLES.Deliverer,
    title: 'Кур’єр',
    text: 'Планую поїздки та хочу заробляти на доставці по дорозі',
    Icon: RouteIcon
  }
];

export default function RoleSelect({ onBack, onDone }) {
  const [selected, setSelected] = useState(ROLES.DeliveryRequester);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  async function proceed() {
    setError('');
    setLoading(true);
    try {
      const res = await rolesApi.acquire(selected);
      // 409 = роль уже отримана, це не помилка для користувача
      if (res.ok || res.status === 409) {
        onDone();
        return;
      }
      setError(errorMessage(res, 'Не вдалося зберегти роль'));
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="step-page">
      <StepHeader onBack={onBack} />
      <h1 className="step-title">Оберіть вашу роль</h1>
      <p className="step-subtitle">Ви зможете змінити або поєднувати ролі пізніше в профілі.</p>

      <div className="role-list">
        {OPTIONS.map(({ role, title, text, Icon }) => (
          <button key={role} type="button" className={'role-card' + (selected === role ? ' selected' : '')} onClick={() => setSelected(role)} aria-pressed={selected === role}>
            <span className="role-head">
              <span className="role-icon"><Icon size={20} /></span>
              <span className="role-title">{title}</span>
            </span>
            <span className="role-text">{text}</span>
          </button>
        ))}
      </div>

      {error && <div className="banner banner-error">{error}</div>}

      <div className="step-spacer" />
      <button type="button" className="btn btn-primary" onClick={proceed} disabled={loading}>
        {loading ? 'Зачекайте…' : 'Продовжити'}
      </button>
      <button type="button" className="link-btn muted-link center" onClick={onDone}>
        Пропустити цей крок
      </button>
    </div>
  );
}

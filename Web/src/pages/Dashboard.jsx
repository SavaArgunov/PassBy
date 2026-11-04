import { useCallback, useEffect, useState } from 'react';
import Logo from '../components/Logo.jsx';
import {
  decodeJwt,
  getToken,
  onRequestLog,
  rolesApi,
  ROLES,
  ROLE_LABELS,
  errorMessage
} from '../api.js';

function useCountdown(expSeconds) {
  const calc = () => Math.max(0, Math.floor(expSeconds - Date.now() / 1000));
  const [left, setLeft] = useState(calc);
  useEffect(() => {
    const id = setInterval(() => setLeft(calc()), 1000);
    return () => clearInterval(id);
  });
  return left;
}

function Badge({ status }) {
  if (status === undefined) return null;
  const cls = status >= 200 && status < 300 ? 'ok' : status === 403 ? 'warn' : 'err';
  return <span className={'badge ' + cls}>{status || 'ERR'}</span>;
}

export default function Dashboard({ name, onLogout, onOpenCard }) {
  const claims = decodeJwt(getToken() || '') || {};
  const left = useCountdown(claims.exp || 0);

  const [roles, setRoles] = useState(null);
  const [rolesError, setRolesError] = useState('');
  const [checks, setChecks] = useState({});
  const [log, setLog] = useState([]);
  const [busy, setBusy] = useState(false);

  useEffect(() => onRequestLog((entry) => setLog((prev) => [entry, ...prev].slice(0, 15))), []);

  const loadRoles = useCallback(async () => {
    const res = await rolesApi.mine();
    if (res.ok) {
      setRoles(res.data.roles || []);
      setRolesError('');
    } else if (res.status !== 401) {
      setRolesError(errorMessage(res));
    }
  }, []);

  useEffect(() => {
    loadRoles();
  }, [loadRoles]);

  async function acquire(role) {
    setBusy(true);
    const res = await rolesApi.acquire(role);
    if (!res.ok && res.status !== 409) setRolesError(errorMessage(res));
    await loadRoles();
    setChecks({});
    setBusy(false);
  }

  async function runCheck(key, fn) {
    const res = await fn();
    setChecks((c) => ({ ...c, [key]: res.status }));
  }

  const has = (role) => !!roles && roles.some((r) => r.name === role);
  const mm = String(Math.floor(left / 60)).padStart(2, '0');
  const ss = String(left % 60).padStart(2, '0');

  return (
    <div className="dash">
      <header className="dash-header">
        <Logo withText />
        <button type="button" className="btn btn-outline btn-small" onClick={onLogout}>Вийти</button>
      </header>

      <section className="dash-card">
        <h2>Акаунт</h2>
        <dl className="kv">
          {name && (<><dt>Імʼя (лише на фронті)</dt><dd>{name}</dd></>)}
          <dt>userId (sub)</dt><dd>{claims.sub ?? '—'}</dd>
          <dt>Email</dt><dd>{claims.email ?? '—'}</dd>
          <dt>Токен спливає через</dt><dd className={left === 0 ? 'text-err' : ''}>{mm}:{ss}</dd>
        </dl>
      </section>

      <section className="dash-card">
        <div className="dash-card-head">
          <h2>Ролі</h2>
          <button type="button" className="btn btn-outline btn-small" onClick={loadRoles}>Оновити</button>
        </div>
        {rolesError && <div className="banner banner-error">{rolesError}</div>}
        {roles === null ? (
          <p className="muted">Завантаження…</p>
        ) : roles.length === 0 ? (
          <p className="muted">Ролей ще немає</p>
        ) : (
          <ul className="role-chips">
            {roles.map((r) => (
              <li key={r.name} className="chip">
                {ROLE_LABELS[r.name] || r.name}
                <small>{new Date(r.registeredAtUtc).toLocaleString('uk-UA')}{r.isBlocked ? ' · заблоковано' : ''}</small>
              </li>
            ))}
          </ul>
        )}
        <div className="btn-row">
          {Object.values(ROLES).map((role) => (
            <button key={role} type="button" className="btn btn-primary btn-small" disabled={busy || has(role)} onClick={() => acquire(role)}>
              {has(role) ? `✓ ${ROLE_LABELS[role]}` : `Отримати роль: ${ROLE_LABELS[role]}`}
            </button>
          ))}
        </div>
      </section>

      <section className="dash-card">
        <h2>Перевірка рольових прав</h2>
        <p className="muted small">200 = доступ є, 403 = ролі немає.</p>
        <div className="check-list">
          <div className="check-row">
            <span>GET /api/roles/check/delivery-requester</span>
            <span><Badge status={checks.requester} /> <button type="button" className="btn btn-outline btn-small" onClick={() => runCheck('requester', rolesApi.checkDeliveryRequester)}>Перевірити</button></span>
          </div>
          <div className="check-row">
            <span>GET /api/roles/check/deliverer</span>
            <span><Badge status={checks.deliverer} /> <button type="button" className="btn btn-outline btn-small" onClick={() => runCheck('deliverer', rolesApi.checkDeliverer)}>Перевірити</button></span>
          </div>
        </div>
      </section>

      <section className="dash-card">
        <h2>Демо-екрани</h2>
        <div className="btn-row">
          <button type="button" className="btn btn-outline btn-small" onClick={onOpenCard}>Верифікація картки</button>
        </div>
      </section>

      <section className="dash-card">
        <h2>Журнал запитів</h2>
        {log.length === 0 ? (
          <p className="muted">Поки порожньо</p>
        ) : (
          <ul className="log">
            {log.map((e) => (
              <li key={e.id}>
                <div className="log-head">
                  <span className="muted small">{e.time}</span>
                  <strong>{e.method}</strong>
                  <span className="log-path">{e.path}</span>
                  <Badge status={e.status} />
                </div>
                {e.data !== null && e.data !== undefined && (
                  <pre>{typeof e.data === 'string' ? e.data : JSON.stringify(e.data, null, 1)}</pre>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

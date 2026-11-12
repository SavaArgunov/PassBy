import { useEffect, useRef, useState } from 'react';
import { errorMessage, verificationApi } from './api.js';

const OUTCOMES = {
  Succeeded: 'Зіставлення успішне',
  IdentityMismatch: 'Дані симуляції не збіглися. Перевірте код і спробуйте ще раз.',
  DocumentExpired: 'Строк дії документа минув.',
  DocumentRevoked: 'Документ відкликано.',
  ProviderUnavailable: 'Провайдер перевірки недоступний. Спробуйте пізніше.',
};

function uuid() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function isActiveSuccess(attempt) {
  return attempt?.verificationCode === 'Succeeded'
    && (!attempt.validUntilUtc || new Date(attempt.validUntilUtc) > new Date());
}

const formatDate = (value) => new Date(value).toLocaleString('uk-UA');

// Верифікація особи через MockBank (API /api/verification).
// Крок 1: валідація документа за тестовим номером, крок 2: зіставлення за кодом симуляції.
export default function VerifyModal({ onChanged }) {
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState(null);
  const [detail, setDetail] = useState(null);
  const [reference, setReference] = useState('');
  const [proof, setProof] = useState('');
  const [addingAnother, setAddingAnother] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const retry = useRef(null);

  useEffect(() => {
    let active = true;
    (async () => {
      const [list, current] = await Promise.all([verificationApi.documents(), verificationApi.status()]);
      let document = null;
      let failure = '';
      if (list.ok && list.data.documents.length > 0) {
        const latest = [...list.data.documents]
          .sort((a, b) => new Date(b.validatedAtUtc) - new Date(a.validatedAtUtc))[0];
        const loaded = await verificationApi.document(latest.documentId);
        if (loaded.ok) document = loaded.data;
        else failure = errorMessage(loaded, 'Не вдалося завантажити документ.');
      } else if (!list.ok) {
        failure = errorMessage(list, 'Не вдалося завантажити дані верифікації.');
      }
      if (!active) return;
      if (current.ok) setStatus(current.data);
      else if (!failure) failure = errorMessage(current, 'Не вдалося завантажити статус верифікації.');
      setDetail(document);
      setError(failure);
      setLoading(false);
    })();
    return () => { active = false; };
  }, []);

  async function validate(event) {
    event.preventDefault();
    const value = reference.trim();
    if (busy || !value) return;
    setBusy(true);
    setError('');
    const result = await verificationApi.validateDocument(value);
    setBusy(false);
    if (!result.ok) {
      setError(errorMessage(result, 'Не вдалося перевірити документ.'));
      return;
    }
    retry.current = null;
    setDetail(result.data);
    setReference('');
    setProof('');
    setAddingAnother(false);
    onChanged();
  }

  async function verify(event) {
    event.preventDefault();
    const value = proof.trim();
    if (busy || !value || !detail) return;

    // Повторний запит із тими самими даними використовує той самий Idempotency-Key
    const pending = retry.current;
    const key = pending && pending.documentId === detail.documentId && pending.proof === value
      ? pending.key
      : uuid();
    retry.current = { documentId: detail.documentId, proof: value, key };

    setBusy(true);
    setError('');
    const result = await verificationApi.verifyIdentity(detail.documentId, value, key);
    if (!result.ok) {
      setBusy(false);
      if (result.status >= 400 && result.status < 500) retry.current = null;
      setError(errorMessage(result, 'Не вдалося виконати перевірку. Спробуйте повторити.'));
      return;
    }
    retry.current = null;
    setProof('');
    if (result.data.verificationCode !== 'Succeeded') {
      setBusy(false);
      setError(OUTCOMES[result.data.verificationCode] ?? `Результат перевірки: ${result.data.verificationCode}`);
      return;
    }
    const current = await verificationApi.status();
    setBusy(false);
    if (current.ok) setStatus(current.data);
    onChanged();
  }

  const lastAttempt = status?.lastAttempt;
  const verified = isActiveSuccess(lastAttempt) && !addingAnother;
  const card = detail?.idCard;
  const showCard = !verified && !addingAnother && !!card;

  const title = loading
    ? 'Верифікація'
    : verified ? 'Особу підтверджено'
      : showCard ? 'Це ваші дані?' : 'Перевірка документа';

  return <>
    <span className="modal-kicker">КРОК 1 · ВЕРИФІКАЦІЯ</span>
    <h2>{title}</h2>

    {loading && <p role="status">Завантаження…</p>}

    {!loading && verified && <>
      <div className="lookup-result">
        <span>✓</span>
        <div>
          <b>Документ і особу підтверджено</b>
          <small>
            Перевірено {formatDate(lastAttempt.checkedAtUtc)}
            {lastAttempt.validUntilUtc ? ` · дійсно до ${formatDate(lastAttempt.validUntilUtc)}` : ''}
          </small>
        </div>
      </div>
      <button className="quiet-button" onClick={() => setAddingAnother(true)}>Перевірити інший документ</button>
    </>}

    {!loading && showCard && <>
      <div className="lookup-result">
        <span>✓</span>
        <div>
          <b>{card.givenName} {card.familyName}</b>
          <small>Дата народження: {card.birthDate} · діє до {card.expiresAt}</small>
        </div>
      </div>
      <form onSubmit={verify}>
        <label className="auth-field">Код симуляції
          <input value={proof} onChange={(event) => setProof(event.target.value)}
            maxLength={128} placeholder="Наприклад, DEMO-PROOF-001" autoComplete="off" required />
        </label>
        <p className="demo-caption">MockBank працює з вигаданими документами. Для TEST-ID-001 код DEMO-PROOF-001 дає збіг.</p>
        <div className="modal-actions">
          <button className="primary-button" disabled={busy || !proof.trim()}>
            {busy ? 'Перевірка…' : 'Так, це я'}
          </button>
          <button type="button" className="quiet-button" disabled={busy}
            onClick={() => { setAddingAnother(true); setError(''); }}>Ні, перевірити інший</button>
        </div>
      </form>
    </>}

    {!loading && !verified && !showCard && <form onSubmit={validate}>
      <p>Введіть номер тестового документа, щоб отримати дані. Це симуляція, а не справжня державна перевірка.</p>
      <label className="auth-field">Номер документа
        <input value={reference} onChange={(event) => setReference(event.target.value)}
          maxLength={64} placeholder="Наприклад, TEST-ID-001" autoComplete="off" required />
      </label>
      <button className="primary-button modal-action" disabled={busy || !reference.trim()}>
        {busy ? 'Перевірка…' : 'Перевірити документ'}
      </button>
      {addingAnother && detail && (
        <button type="button" className="quiet-button" disabled={busy}
          onClick={() => { setAddingAnother(false); setError(''); }}>Назад</button>
      )}
    </form>}

    {error && <p className="auth-error" role="alert">{error}</p>}
  </>;
}

import { useEffect, useRef, useState } from 'react';
import StepHeader from '../components/StepHeader.jsx';
import { errorMessage, verificationApi } from '../api.js';

const outcomes = {
  Succeeded: 'Зіставлення успішне',
  IdentityMismatch: 'Дані симуляції не збіглися',
  DocumentExpired: 'Строк дії документа минув',
  DocumentRevoked: 'Документ відкликано',
  ProviderUnavailable: 'Провайдер недоступний'
};

function AttemptResult({ attempt }) {
  return (
    <dl className="kv">
      <dt>Результат</dt><dd>{outcomes[attempt.verificationCode] ?? attempt.verificationCode}</dd>
      <dt>Документ</dt><dd>№ {attempt.documentId}</dd>
      <dt>Час перевірки</dt><dd>{new Date(attempt.checkedAtUtc).toLocaleString('uk-UA')}</dd>
      {attempt.validUntilUtc && (
        <>
          <dt>Строк результату</dt>
          <dd>{new Date(attempt.validUntilUtc).toLocaleString('uk-UA')}</dd>
        </>
      )}
    </dl>
  );
}

export default function IdentityVerification({ onBack }) {
  const [documents, setDocuments] = useState(null);
  const [status, setStatus] = useState(null);
  const [selectedId, setSelectedId] = useState(null);
  const [detail, setDetail] = useState(null);
  const [reference, setReference] = useState('');
  const [proof, setProof] = useState('');
  const [attempt, setAttempt] = useState(null);
  const [busy, setBusy] = useState('');
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState('');
  const [detailError, setDetailError] = useState('');
  const [actionError, setActionError] = useState('');
  const [revision, setRevision] = useState(0);
  const retry = useRef(null);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setLoadError('');
    Promise.all([verificationApi.documents(), verificationApi.status()]).then(([list, result]) => {
      if (!active) return;
      if (list.ok) setDocuments(list.data.documents);
      if (result.ok) setStatus(result.data);
      if (!list.ok || !result.ok) {
        setLoadError(errorMessage(!list.ok ? list : result, 'Не вдалося оновити дані верифікації.'));
      }
      setLoading(false);
    });
    return () => { active = false; };
  }, [revision]);

  useEffect(() => {
    if (selectedId === null) return;
    let active = true;
    setDetailError('');
    verificationApi.document(selectedId).then((result) => {
      if (!active) return;
      if (result.ok) setDetail(result.data);
      else setDetailError(errorMessage(result, 'Не вдалося завантажити документ.'));
    });
    return () => { active = false; };
  }, [selectedId, revision]);

  function selectDocument(id) {
    if (id === selectedId) return;
    setSelectedId(id);
    setDetail(null);
    setDetailError('');
    setProof('');
    setAttempt(null);
    setActionError('');
    retry.current = null;
  }

  async function validate(event) {
    event.preventDefault();
    if (busy || !reference.trim()) return;
    setBusy('document');
    setActionError('');
    try {
      const result = await verificationApi.validateDocument(reference.trim());
      if (!result.ok) {
        setActionError(errorMessage(result, 'Не вдалося валідувати документ.'));
        return;
      }
      selectDocument(result.data.documentId);
      setReference('');
      setRevision((previous) => previous + 1);
    } finally {
      setBusy('');
    }
  }

  async function verify(event) {
    event.preventDefault();
    const submittedProof = proof.trim();
    if (busy || !submittedProof || !detail || detail.documentId !== selectedId) return;

    const pending = retry.current;
    const key = pending?.documentId === selectedId && pending.proof === submittedProof
      ? pending.key
      : crypto.randomUUID();
    retry.current = { documentId: selectedId, proof: submittedProof, key };
    setBusy('attempt');
    setActionError('');
    setAttempt(null);
    try {
      const result = await verificationApi.verifyIdentity(selectedId, submittedProof, key);
      if (!result.ok) {
        if (result.status >= 400 && result.status < 500) retry.current = null;
        setActionError(errorMessage(result, 'Не вдалося виконати перевірку. Спробуйте повторити запит.'));
        return;
      }
      retry.current = null;
      setAttempt(result.data);
      setProof('');
      setRevision((previous) => previous + 1);
    } finally {
      setBusy('');
    }
  }

  const card = detail?.documentId === selectedId ? detail.idCard : null;
  const lastAttempt = status?.lastAttempt;
  const recentResult = attempt && attempt.verificationId !== lastAttempt?.verificationId ? attempt : null;

  return (
    <main className="dash verification-page">
      <StepHeader onBack={onBack} />
      <h1 className="step-title">Верифікація особи</h1>
      <p className="step-subtitle">MockBank працює з вигаданими документами. Використовуйте тестові дані.</p>

      <section className="dash-card">
        <h2>Валідація документа</h2>
        <form onSubmit={validate}>
          <div className="field">
            <label htmlFor="mock-reference">Ідентифікатор тестової ID-картки</label>
            <input id="mock-reference" className="input" value={reference} onChange={(e) => setReference(e.target.value)}
              placeholder="TEST-ID-001" maxLength={64} autoComplete="off" required />
          </div>
          <button className="btn btn-primary" disabled={!!busy || !reference.trim()}>
            {busy === 'document' ? 'Валідація…' : 'Валідувати документ'}
          </button>
        </form>
      </section>

      {actionError && <p className="banner banner-error" role="alert">{actionError}</p>}

      <section className="dash-card">
        <div className="dash-card-head">
          <h2>Мої документи</h2>
          <button className="btn btn-outline btn-small" disabled={loading || !!busy}
            onClick={() => setRevision((previous) => previous + 1)}>Оновити</button>
        </div>
        {loadError && <p className="banner banner-error" role="alert">{loadError}</p>}
        {loading && <p className="muted" role="status">Завантаження…</p>}
        {documents?.length === 0 && !loading && <p className="muted">Валідованих документів ще немає.</p>}
        {!!documents?.length && (
          <div className="btn-row">
            {documents.map((document) => (
              <button key={document.documentId} className="btn btn-outline btn-small"
                disabled={!!busy} aria-pressed={document.documentId === selectedId}
                onClick={() => selectDocument(document.documentId)}>
                № {document.documentId} · {document.providerCode}
              </button>
            ))}
          </div>
        )}
      </section>

      {selectedId !== null && (
        <section className="dash-card">
          <h2>ID-картка № {selectedId}</h2>
          {detailError && <p className="banner banner-error" role="alert">{detailError}</p>}
          {!card && !detailError && <p className="muted" role="status">Завантаження документа…</p>}
          {card && (
            <>
              <dl className="kv">
                <dt>Ім’я та прізвище</dt><dd>{card.givenName} {card.familyName}</dd>
                <dt>Дата народження</dt><dd>{card.birthDate}</dd>
                <dt>Діє до</dt><dd>{card.expiresAt}</dd>
              </dl>
              <form className="verification-proof" onSubmit={verify}>
                <div className="field">
                  <label htmlFor="mock-proof">Код симуляції</label>
                  <input id="mock-proof" className="input" value={proof} onChange={(e) => setProof(e.target.value)}
                    maxLength={128} placeholder="DEMO-PROOF-001" autoComplete="off" required
                    aria-describedby="mock-proof-hint" />
                  <p id="mock-proof-hint" className="muted small">
                    Для TEST-ID-001 код DEMO-PROOF-001 дає збіг. Інший код дає невідповідність.
                  </p>
                </div>
                <button className="btn btn-primary" disabled={!!busy || !proof.trim()}>
                  {busy === 'attempt' ? 'Перевірка…' : 'Провести перевірку'}
                </button>
              </form>
            </>
          )}
        </section>
      )}

      {recentResult && (
        <section className="dash-card" aria-live="polite">
          <h2>Результат запиту</h2>
          <AttemptResult attempt={recentResult} />
        </section>
      )}

      <section className="dash-card">
        <h2>Остання завершена спроба</h2>
        {lastAttempt ? <AttemptResult attempt={lastAttempt} />
          : status && <p className="muted">Завершених спроб ще немає.</p>}
      </section>
    </main>
  );
}

import { useState } from 'react';
import StepHeader from '../components/StepHeader.jsx';

const REWARD = 100;
const COMMISSION_RATE = 0.2;

const formatCard = (v) => v.replace(/\D/g, '').slice(0, 16).replace(/(.{4})/g, '$1 ').trim();
const formatExpiry = (v) => {
  const d = v.replace(/\D/g, '').slice(0, 4);
  return d.length > 2 ? d.slice(0, 2) + '/' + d.slice(2) : d;
};

export default function CardVerify({ onBack }) {
  const [number, setNumber] = useState('');
  const [expiry, setExpiry] = useState('');
  const [cvc, setCvc] = useState('');
  const [holder, setHolder] = useState('');
  const [done, setDone] = useState(false);

  const commission = Math.round(REWARD * COMMISSION_RATE);
  const total = REWARD + commission;

  const valid =
    number.replace(/\s/g, '').length === 16 &&
    /^(0[1-9]|1[0-2])\/\d{2}$/.test(expiry) &&
    cvc.length === 3 &&
    holder.trim().length > 1;

  return (
    <div className="step-page">
      <StepHeader onBack={onBack} />
      <h1 className="step-title">Верифікація картки</h1>
      <p className="step-subtitle">Додайте картку для блокування коштів та підтвердження доставки в PassBy</p>

      <div className="banner banner-info">
        Демо-екран: дані картки нікуди не надсилаються і не зберігаються. Для справжніх платежів потрібен платіжний провайдер.
      </div>

      <div className="card-panel">
        <div className="field">
          <label htmlFor="cc-number">Номер картки</label>
          <input id="cc-number" className="input" inputMode="numeric" autoComplete="off" placeholder="4242 4242 4242 4242" value={number} onChange={(e) => setNumber(formatCard(e.target.value))} />
        </div>
        <div className="field-row">
          <div className="field">
            <label htmlFor="cc-exp">Термін дії (MM/YY)</label>
            <input id="cc-exp" className="input" inputMode="numeric" autoComplete="off" placeholder="08/28" value={expiry} onChange={(e) => setExpiry(formatExpiry(e.target.value))} />
          </div>
          <div className="field">
            <label htmlFor="cc-cvc">CVC/CVV</label>
            <input id="cc-cvc" className="input" inputMode="numeric" autoComplete="off" placeholder="123" value={cvc} onChange={(e) => setCvc(e.target.value.replace(/\D/g, '').slice(0, 3))} />
          </div>
        </div>
        <div className="field">
          <label htmlFor="cc-name">Імʼя на картці</label>
          <input id="cc-name" className="input" autoComplete="off" placeholder="Jane Doe" value={holder} onChange={(e) => setHolder(e.target.value)} />
        </div>
      </div>

      <div className="payment-summary">
        <h3>Розрахунок платежу</h3>
        <div className="summary-row"><span>Винагорода кур’єра</span><strong>{REWARD} грн</strong></div>
        <div className="summary-row"><span>Комісія платформи ({COMMISSION_RATE * 100}%)</span><strong>{commission} грн</strong></div>
        <div className="summary-total"><span>Разом до блокування</span><strong>{total} грн</strong></div>
      </div>

      <div className="note-box">
        Кошти заморожуються та будуть перераховані кур’єру лише після підтвердження отримання посилки.
      </div>

      {done && <div className="banner banner-ok">Демо: картку «привʼязано». Жодних даних не збережено.</div>}

      <div className="step-spacer" />
      <button type="button" className="btn btn-primary" disabled={!valid} onClick={() => setDone(true)}>
        Привʼязати картку та підтвердити
      </button>
    </div>
  );
}

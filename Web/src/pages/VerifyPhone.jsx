import { useEffect, useRef, useState } from 'react';
import StepHeader from '../components/StepHeader.jsx';

const LENGTH = 4;
const RESEND_SECONDS = 59;

export default function VerifyPhone({ phone, onBack, onDone }) {
  const [digits, setDigits] = useState(Array(LENGTH).fill(''));
  const [seconds, setSeconds] = useState(RESEND_SECONDS);
  const refs = useRef([]);

  useEffect(() => {
    refs.current[0]?.focus();
  }, []);

  useEffect(() => {
    if (seconds <= 0) return undefined;
    const id = setTimeout(() => setSeconds((s) => s - 1), 1000);
    return () => clearTimeout(id);
  }, [seconds]);

  const setDigit = (index, value) => {
    const d = value.replace(/\D/g, '').slice(-1);
    setDigits((prev) => prev.map((x, i) => (i === index ? d : x)));
    if (d && index < LENGTH - 1) refs.current[index + 1]?.focus();
  };

  const onKeyDown = (index, e) => {
    if (e.key === 'Backspace' && !digits[index] && index > 0) {
      refs.current[index - 1]?.focus();
    }
  };

  const onPaste = (e) => {
    const text = e.clipboardData.getData('text').replace(/\D/g, '').slice(0, LENGTH);
    if (!text) return;
    e.preventDefault();
    setDigits(Array.from({ length: LENGTH }, (_, i) => text[i] ?? ''));
    refs.current[Math.min(text.length, LENGTH - 1)]?.focus();
  };

  const complete = digits.every(Boolean);
  const mm = String(Math.floor(seconds / 60)).padStart(2, '0');
  const ss = String(seconds % 60).padStart(2, '0');

  return (
    <div className="step-page">
      <StepHeader onBack={onBack} />
      <h1 className="step-title">Підтвердження номера</h1>
      <p className="step-subtitle">Введіть 4-значний код, надісланий на {phone || 'ваш номер'}</p>

      <div className="code-row" onPaste={onPaste}>
        {digits.map((d, i) => (
          <input
            key={i}
            ref={(el) => (refs.current[i] = el)}
            className="code-box"
            inputMode="numeric"
            autoComplete="one-time-code"
            maxLength={1}
            value={d}
            onChange={(e) => setDigit(i, e.target.value)}
            onKeyDown={(e) => onKeyDown(i, e)}
            aria-label={`Цифра ${i + 1}`}
          />
        ))}
      </div>

      {seconds > 0 ? (
        <p className="resend">Надіслати код повторно через {mm}:{ss}</p>
      ) : (
        <button type="button" className="link-btn strong center" onClick={() => setSeconds(RESEND_SECONDS)}>
          Надіслати код повторно
        </button>
      )}

      <div className="banner banner-info">
        Демо-екран: перевірка коду на бекенді ще не реалізована, підійде будь-який код із 4 цифр.
      </div>

      <div className="step-spacer" />
      <button type="button" className="btn btn-primary" disabled={!complete} onClick={onDone}>
        Підтвердити
      </button>
    </div>
  );
}

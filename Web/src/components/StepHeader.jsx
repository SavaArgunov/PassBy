import Logo from './Logo.jsx';
import { ArrowLeft } from './Icons.jsx';

export default function StepHeader({ onBack }) {
  return (
    <div className="step-header">
      {onBack && (
        <button type="button" className="icon-btn" onClick={onBack} aria-label="Назад">
          <ArrowLeft />
        </button>
      )}
      <Logo />
    </div>
  );
}

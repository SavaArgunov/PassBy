import { useEffect, useState } from 'react';
import AuthPage from './pages/AuthPage.jsx';
import VerifyPhone from './pages/VerifyPhone.jsx';
import RoleSelect from './pages/RoleSelect.jsx';
import CardVerify from './pages/CardVerify.jsx';
import Dashboard from './pages/Dashboard.jsx';
import IdentityVerification from './pages/IdentityVerification.jsx';
import { getToken, isTokenValid, onUnauthorized, setToken } from './api.js';

export default function App() {
  const [step, setStep] = useState(() => (isTokenValid(getToken()) ? 'dashboard' : 'auth'));
  const [profile, setProfile] = useState({ name: '', phoneDisplay: '' });
  const [notice, setNotice] = useState('');

  const logout = (message = '') => {
    setToken(null);
    setNotice(message);
    setStep('auth');
  };

  useEffect(
    () => onUnauthorized(() => logout('Сесія закінчилась. Увійдіть знову.')),
    []
  );

  if (step === 'auth') {
    return (
      <AuthPage
        notice={notice}
        onAuthenticated={({ isNewUser, name, phoneDisplay }) => {
          setNotice('');
          setProfile({ name, phoneDisplay });
          setStep(isNewUser ? 'verify' : 'dashboard');
        }}
      />
    );
  }

  if (step === 'verify') {
    return <VerifyPhone phone={profile.phoneDisplay} onBack={() => logout()} onDone={() => setStep('role')} />;
  }

  if (step === 'role') {
    return <RoleSelect onBack={() => setStep('verify')} onDone={() => setStep('dashboard')} />;
  }

  if (step === 'identity') {
    return <IdentityVerification onBack={() => setStep('dashboard')} />;
  }

  if (step === 'card') {
    return <CardVerify onBack={() => setStep('dashboard')} />;
  }

  return (
    <Dashboard
      name={profile.name}
      onLogout={() => logout()}
      onOpenVerification={() => setStep('identity')}
      onOpenCard={() => setStep('card')}
    />
  );
}

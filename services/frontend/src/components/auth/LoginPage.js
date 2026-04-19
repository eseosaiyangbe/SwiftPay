import React, { useState } from 'react';
import { Activity, AlertCircle, Eye, EyeOff, Wallet } from 'lucide-react';
import { APIClient } from '../../lib/api-client';

function PasswordInput({
  id,
  label,
  value,
  onChange,
  placeholder,
  disabled,
  autoComplete,
}) {
  const [visible, setVisible] = useState(false);

  return (
    <div>
      <label htmlFor={id} className="block text-sm font-medium text-slate-700 mb-2">{label}</label>
      <div className="relative">
        <input
          id={id}
          type={visible ? 'text' : 'password'}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          disabled={disabled}
          autoComplete={autoComplete}
          className="w-full px-4 py-3 pr-12 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
          placeholder={placeholder}
        />
        <button
          type="button"
          onClick={() => setVisible((current) => !current)}
          disabled={disabled}
          className="absolute inset-y-0 right-0 px-3 text-slate-500 hover:text-slate-700 disabled:text-slate-300"
          aria-label={visible ? `Hide ${label.toLowerCase()}` : `Show ${label.toLowerCase()}`}
        >
          {visible ? <EyeOff className="w-5 h-5" /> : <Eye className="w-5 h-5" />}
        </button>
      </div>
    </div>
  );
}

export function LoginPage({ onLogin, notice }) {
  const [mode, setMode] = useState('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [resetToken, setResetToken] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [name, setName] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [success, setSuccess] = useState(null);

  const isLogin = mode === 'login';
  const isRegister = mode === 'register';
  const isForgot = mode === 'forgot';
  const isReset = mode === 'reset';

  const setView = (nextMode) => {
    setMode(nextMode);
    setError(null);
    setSuccess(null);
    setPassword('');
    setNewPassword('');
    setConfirmPassword('');
    if (nextMode !== 'reset') setResetToken('');
  };

  const validateNewPassword = () => {
    if (newPassword !== confirmPassword) {
      setError('New password and confirmation must match.');
      return false;
    }

    if (newPassword.length < 8 || !/[a-z]/.test(newPassword) || !/[A-Z]/.test(newPassword) || !/\d/.test(newPassword)) {
      setError('New password must be at least 8 characters and include uppercase, lowercase, and a number.');
      return false;
    }

    return true;
  };

  const handleSubmit = async (event) => {
    event.preventDefault();
    setLoading(true);
    setError(null);
    setSuccess(null);

    try {
      if (mode === 'login') {
        const data = await APIClient.login(email, password);
        onLogin(data.user);
      } else if (mode === 'register') {
        const data = await APIClient.register(email, password, name);
        onLogin(data.user || { id: data.userId, email, name, role: 'user' });
      } else if (mode === 'forgot') {
        const data = await APIClient.forgotPassword(email);
        setSuccess(data.message || 'If that email exists, password reset instructions have been prepared.');
        if (data.resetToken) {
          setResetToken(data.resetToken);
          setMode('reset');
        }
      } else if (mode === 'reset') {
        if (!validateNewPassword()) return;
        const data = await APIClient.resetPassword(resetToken, newPassword);
        setView('login');
        setSuccess(data.message || 'Password reset successfully. Please sign in.');
      }
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-blue-50 to-blue-100 flex items-center justify-center p-4">
      <div className="bg-white rounded-2xl shadow-xl p-8 w-full max-w-md">
        <div className="flex items-center justify-center mb-8">
          <div className="w-16 h-16 bg-gradient-to-br from-blue-600 to-blue-700 rounded-2xl flex items-center justify-center">
            <Wallet className="w-10 h-10 text-white" />
          </div>
        </div>

        <h1 className="text-3xl font-bold text-center text-slate-900 mb-2">SwiftPay</h1>
        <p className="text-center text-slate-600 mb-8">Secure Digital Wallet</p>

        {notice && (
          <div className="mb-6 p-4 bg-amber-50 border border-amber-200 rounded-lg flex items-start space-x-3">
            <AlertCircle className="w-5 h-5 text-amber-600 mt-0.5" />
            <p className="text-sm text-amber-800">{notice}</p>
          </div>
        )}

        {error && (
          <div className="mb-6 p-4 bg-red-50 border border-red-200 rounded-lg flex items-start space-x-3">
            <AlertCircle className="w-5 h-5 text-red-600 mt-0.5" />
            <p className="text-sm text-red-800">{error}</p>
          </div>
        )}

        {success && (
          <div className="mb-6 p-4 bg-green-50 border border-green-200 rounded-lg flex items-start space-x-3">
            <AlertCircle className="w-5 h-5 text-green-600 mt-0.5" />
            <p className="text-sm text-green-800">{success}</p>
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          {isRegister && (
            <div>
              <label htmlFor="name" className="block text-sm font-medium text-slate-700 mb-2">Full Name</label>
              <input
                id="name"
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                disabled={loading}
                autoComplete="name"
                className="w-full px-4 py-3 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                placeholder="John Doe"
              />
            </div>
          )}

          {!isReset && (
            <div>
              <label htmlFor="email" className="block text-sm font-medium text-slate-700 mb-2">Email</label>
              <input
                id="email"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                disabled={loading}
                autoComplete="email"
                className="w-full px-4 py-3 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                placeholder="you@example.com"
              />
            </div>
          )}

          {(isLogin || isRegister) && (
            <>
              <PasswordInput
                id="password"
                label="Password"
                value={password}
                onChange={setPassword}
                disabled={loading}
                autoComplete={isLogin ? 'current-password' : 'new-password'}
                placeholder="Enter password"
              />
              {isRegister && (
                <p className="text-xs text-slate-500 -mt-2">
                  At least 8 characters with uppercase, lowercase, and number
                </p>
              )}
            </>
          )}

          {isReset && (
            <>
              <div>
                <label htmlFor="reset-token" className="block text-sm font-medium text-slate-700 mb-2">Reset Token</label>
                <input
                  id="reset-token"
                  type="text"
                  value={resetToken}
                  onChange={(e) => setResetToken(e.target.value)}
                  disabled={loading}
                  autoComplete="one-time-code"
                  className="w-full px-4 py-3 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                  placeholder="Paste reset token"
                />
              </div>
              <PasswordInput
                id="new-password"
                label="New Password"
                value={newPassword}
                onChange={setNewPassword}
                disabled={loading}
                autoComplete="new-password"
                placeholder="Enter new password"
              />
              <p className="text-xs text-slate-500 -mt-2">
                At least 8 characters with uppercase, lowercase, and number
              </p>
              <PasswordInput
                id="confirm-password"
                label="Confirm New Password"
                value={confirmPassword}
                onChange={setConfirmPassword}
                disabled={loading}
                autoComplete="new-password"
                placeholder="Confirm new password"
              />
            </>
          )}

          {isForgot && (
            <div className="rounded-lg border border-blue-200 bg-blue-50 p-4 text-sm text-blue-800">
              Enter your email and SwiftPay will prepare a one-time reset token. In local development, the token is shown here so you can test without email delivery.
            </div>
          )}

          <button
            type="submit"
            disabled={
              loading ||
              (isLogin && (!email || !password)) ||
              (isRegister && (!email || !password || !name)) ||
              (isForgot && !email) ||
              (isReset && (!resetToken || !newPassword || !confirmPassword))
            }
            className="w-full bg-blue-600 text-white py-3 rounded-lg font-medium hover:bg-blue-700 transition-colors disabled:bg-slate-300 disabled:cursor-not-allowed flex items-center justify-center space-x-2"
          >
            {loading ? (
              <>
                <Activity className="w-5 h-5 animate-spin" />
                <span>Processing...</span>
              </>
            ) : (
              <span>
                {isLogin && 'Sign In'}
                {isRegister && 'Create Account'}
                {isForgot && 'Request Reset Token'}
                {isReset && 'Reset Password'}
              </span>
            )}
          </button>
        </form>

        {isLogin && (
          <div className="mt-4 text-center">
            <button
              type="button"
              onClick={() => setView('forgot')}
              className="text-sm text-slate-600 hover:text-blue-700"
            >
              Forgot password?
            </button>
          </div>
        )}

        <div className="mt-6 text-center">
          <button
            type="button"
            onClick={() => setView(isLogin ? 'register' : 'login')}
            className="text-sm text-blue-600 hover:text-blue-700"
          >
            {isLogin ? "Don't have an account? Sign up" : 'Back to sign in'}
          </button>
        </div>

        {isForgot && (
          <div className="mt-3 text-center">
            <button
              type="button"
              onClick={() => setView('reset')}
              className="text-sm text-blue-600 hover:text-blue-700"
            >
              Already have a reset token?
            </button>
          </div>
        )}

        {isReset && (
          <div className="mt-3 text-center">
            <button
              type="button"
              onClick={() => setView('forgot')}
              className="text-sm text-blue-600 hover:text-blue-700"
            >
              Request a new token
            </button>
          </div>
        )}

        <div className="mt-8 p-4 bg-blue-50 rounded-lg">
          <p className="text-xs text-blue-800 text-center">
            Secured with JWT authentication, encrypted connections, and industry-standard security
          </p>
        </div>
      </div>
    </div>
  );
}

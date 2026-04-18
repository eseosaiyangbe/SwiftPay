import React, { useState } from 'react';
import { Activity, AlertCircle, Wallet } from 'lucide-react';
import { APIClient } from '../../lib/api-client';

export function LoginPage({ onLogin, notice }) {
  const [isLogin, setIsLogin] = useState(true);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  const handleSubmit = async () => {
    setLoading(true);
    setError(null);

    try {
      if (isLogin) {
        const data = await APIClient.login(email, password);
        onLogin(data.user);
      } else {
        const data = await APIClient.register(email, password, name);
        onLogin(data.user || { id: data.userId, email, name, role: 'user' });
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

        <div className="space-y-4">
          {!isLogin && (
            <div>
              <label className="block text-sm font-medium text-slate-700 mb-2">Full Name</label>
              <input
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                className="w-full px-4 py-3 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                placeholder="John Doe"
              />
            </div>
          )}

          <div>
            <label className="block text-sm font-medium text-slate-700 mb-2">Email</label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full px-4 py-3 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              placeholder="you@example.com"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-700 mb-2">Password</label>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full px-4 py-3 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              placeholder="••••••••"
            />
            {!isLogin && (
              <p className="text-xs text-slate-500 mt-1">
                At least 8 characters with uppercase, lowercase, and number
              </p>
            )}
          </div>

          <button
            onClick={handleSubmit}
            disabled={loading || !email || !password || (!isLogin && !name)}
            className="w-full bg-blue-600 text-white py-3 rounded-lg font-medium hover:bg-blue-700 transition-colors disabled:bg-slate-300 disabled:cursor-not-allowed flex items-center justify-center space-x-2"
          >
            {loading ? (
              <>
                <Activity className="w-5 h-5 animate-spin" />
                <span>Processing...</span>
              </>
            ) : (
              <span>{isLogin ? 'Sign In' : 'Create Account'}</span>
            )}
          </button>
        </div>

        <div className="mt-6 text-center">
          <button
            onClick={() => {
              setIsLogin(!isLogin);
              setError(null);
            }}
            className="text-sm text-blue-600 hover:text-blue-700"
          >
            {isLogin ? "Don't have an account? Sign up" : 'Already have an account? Sign in'}
          </button>
        </div>

        <div className="mt-8 p-4 bg-blue-50 rounded-lg">
          <p className="text-xs text-blue-800 text-center">
            🔒 Secured with JWT authentication, encrypted connections, and industry-standard security
          </p>
        </div>
      </div>
    </div>
  );
}


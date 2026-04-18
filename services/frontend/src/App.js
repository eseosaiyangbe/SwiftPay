import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Clock, CheckCircle, XCircle, Activity, Wallet, AlertCircle, LogOut, User } from 'lucide-react';
import { APIClient } from './lib/api-client';
import { SESSION_TIMEOUT_MS, SESSION_WARNING_MS } from './lib/session-config';
import { formatRelativeAge, newestFirst, oldestFirst } from './lib/transaction-utils';
import { LoginPage } from './components/auth/LoginPage';
import { DashboardTab } from './components/dashboard/DashboardTab';
import { MonitoringTab } from './components/monitoring/MonitoringTab';
import { SettingsTab } from './components/settings/SettingsTab';
import { ActivityTab } from './components/transactions/ActivityTab';
import { SendMoneyTab } from './components/transactions/SendMoneyTab';

export default function SwiftPayApp() {
  const [user, setUser] = useState(null);
  const [wallet, setWallet] = useState(null);
  const [allWallets, setAllWallets] = useState([]);
  const [transactions, setTransactions] = useState([]);
  const [notifications, setNotifications] = useState([]);
  const [activeTab, setActiveTab] = useState('dashboard');
  const [metrics, setMetrics] = useState(null);
  const [loading, setLoading] = useState(true);
  const [dataLoading, setDataLoading] = useState(false);
  const [error, setError] = useState(null);
  const [sessionNotice, setSessionNotice] = useState(null);
  const [sessionWarningSeconds, setSessionWarningSeconds] = useState(null);
  const [markingNotificationId, setMarkingNotificationId] = useState(null);
  const [deletingNotificationId, setDeletingNotificationId] = useState(null);
  const warningTimerRef = useRef(null);
  const logoutTimerRef = useRef(null);
  const countdownTimerRef = useRef(null);
  
  const [sendAmount, setSendAmount] = useState('');
  const [recipient, setRecipient] = useState('');
  const [sendLoading, setSendLoading] = useState(false);
  const [sendSuccess, setSendSuccess] = useState(false);

  const clearSessionTimers = useCallback(() => {
    clearTimeout(warningTimerRef.current);
    clearTimeout(logoutTimerRef.current);
    clearInterval(countdownTimerRef.current);
    warningTimerRef.current = null;
    logoutTimerRef.current = null;
    countdownTimerRef.current = null;
  }, []);

  const finishLogout = useCallback(async ({ timedOut = false } = {}) => {
    clearSessionTimers();

    try {
      await APIClient.logout();
    } catch (err) {
      console.error('Logout request failed:', err);
      APIClient.removeToken();
    }

    setUser(null);
    setWallet(null);
    setAllWallets([]);
    setTransactions([]);
    setNotifications([]);
    setMetrics(null);
    setDataLoading(false);
    setMarkingNotificationId(null);
    setDeletingNotificationId(null);
    setSessionWarningSeconds(null);
    setSendAmount('');
    setRecipient('');
    setSendSuccess(false);
    setActiveTab('dashboard');
    setError(null);
    setSessionNotice(timedOut ? 'You were signed out because the session was inactive.' : null);
  }, [clearSessionTimers]);

  const resetSessionTimer = useCallback(() => {
    if (!user) return;

    clearSessionTimers();
    setSessionWarningSeconds(null);
    setSessionNotice(null);

    warningTimerRef.current = setTimeout(() => {
      const initialSeconds = Math.ceil(SESSION_WARNING_MS / 1000);
      setSessionWarningSeconds(initialSeconds);

      countdownTimerRef.current = setInterval(() => {
        setSessionWarningSeconds((current) => {
          if (!current || current <= 1) return 0;
          return current - 1;
        });
      }, 1000);
    }, Math.max(0, SESSION_TIMEOUT_MS - SESSION_WARNING_MS));

    logoutTimerRef.current = setTimeout(() => {
      finishLogout({ timedOut: true });
    }, SESSION_TIMEOUT_MS);
  }, [user, clearSessionTimers, finishLogout]);

  useEffect(() => {
    APIClient.initializeSession();
    const storedUser = APIClient.getStoredUser();
    if (storedUser) {
      setUser(storedUser);
    }
    setLoading(false);
  }, []);

  const fetchWallet = useCallback(async () => {
    if (!user) return;
    try {
      const data = await APIClient.getWallet(user.id);
      setWallet(data);
      setError(null);
    } catch (err) {
      setError(`Failed to load wallet: ${err.message}`);
    }
  }, [user]);

  const fetchAllWallets = useCallback(async () => {
    try {
      const data = await APIClient.getWallets();
      setAllWallets(data);
    } catch (err) {
      console.error('Failed to load wallets:', err);
    }
  }, []);

  const fetchTransactions = useCallback(async () => {
    if (!user) return;
    try {
      const data = await APIClient.getTransactions(user.id);
      setTransactions(data);
    } catch (err) {
      console.error('Failed to load transactions:', err);
    }
  }, [user]);

  const fetchNotifications = useCallback(async () => {
    if (!user) return;
    try {
      const data = await APIClient.getNotifications(user.id);
      setNotifications(data);
    } catch (err) {
      console.error('Failed to load notifications:', err);
    }
  }, [user]);

  const fetchMetrics = useCallback(async () => {
    try {
      const data = await APIClient.getMetrics();
      setMetrics(data);
    } catch (err) {
      console.error('Failed to load metrics:', err);
    }
  }, []);

  useEffect(() => {
    if (user) {
      setSessionNotice(null);
      const loadData = async () => {
        setDataLoading(true);
        try {
          await Promise.all([
            fetchWallet(),
            fetchAllWallets(),
            fetchTransactions(),
            fetchNotifications(),
            fetchMetrics()
          ]);
        } finally {
          setDataLoading(false);
        }
      };
      loadData();
    }
  }, [user, fetchWallet, fetchAllWallets, fetchTransactions, fetchNotifications, fetchMetrics]);

  useEffect(() => {
    if (!user) {
      clearSessionTimers();
      setSessionWarningSeconds(null);
      return undefined;
    }

    const activityEvents = ['click', 'keydown', 'scroll', 'touchstart'];
    activityEvents.forEach((eventName) => {
      window.addEventListener(eventName, resetSessionTimer, { passive: true });
    });

    resetSessionTimer();

    return () => {
      activityEvents.forEach((eventName) => {
        window.removeEventListener(eventName, resetSessionTimer);
      });
      clearSessionTimers();
    };
  }, [user, resetSessionTimer, clearSessionTimers]);

  // Poll wallet/transactions/notifications every 30s; metrics every 60s to reduce load
  useEffect(() => {
    if (!user) return;
    const dataInterval = setInterval(() => {
      fetchWallet();
      fetchTransactions();
      fetchNotifications();
    }, 30000);
    const metricsInterval = setInterval(fetchMetrics, 60000);
    return () => {
      clearInterval(dataInterval);
      clearInterval(metricsInterval);
    };
  }, [user, fetchWallet, fetchTransactions, fetchNotifications, fetchMetrics]);

  const handleSendMoney = async () => {
    const amount = parseFloat(sendAmount);
    
    if (!amount || amount <= 0 || !recipient) {
      setError('Please enter a valid amount and select a recipient');
      return;
    }

    if (wallet && amount > parseFloat(wallet.balance)) {
      setError('Insufficient funds');
      return;
    }

    setSendLoading(true);
    setSendSuccess(false);
    setError(null);

    try {
      await APIClient.createTransaction({
        from: user.id,
        to: recipient,
        amount: amount
      });

      setSendAmount('');
      setRecipient('');
      setSendSuccess(true);
      
      setTimeout(() => {
        fetchWallet();
        fetchTransactions();
      }, 500);

      setTimeout(() => setSendSuccess(false), 3000);
    } catch (err) {
      setError(`Transaction failed: ${err.message}`);
    } finally {
      setSendLoading(false);
    }
  };

  const handleMarkNotificationRead = async (notificationId) => {
    setMarkingNotificationId(notificationId);
    setError(null);

    try {
      const updatedNotification = await APIClient.markNotificationRead(notificationId);
      setNotifications((current) =>
        current.map((notification) =>
          notification.id === notificationId ? updatedNotification : notification
        )
      );
    } catch (err) {
      setError(`Failed to mark notification as read: ${err.message}`);
    } finally {
      setMarkingNotificationId(null);
    }
  };

  const handleDeleteNotification = async (notificationId) => {
    setDeletingNotificationId(notificationId);
    setError(null);

    try {
      await APIClient.deleteNotification(notificationId);
      setNotifications((current) =>
        current.filter((notification) => notification.id !== notificationId)
      );
    } catch (err) {
      setError(`Failed to delete notification: ${err.message}`);
    } finally {
      setDeletingNotificationId(null);
    }
  };

  const handleChangePassword = async ({ currentPassword, newPassword }) => {
    await APIClient.changePassword(currentPassword, newPassword);

    clearSessionTimers();
    APIClient.removeToken();
    setUser(null);
    setWallet(null);
    setAllWallets([]);
    setTransactions([]);
    setNotifications([]);
    setMetrics(null);
    setDataLoading(false);
    setMarkingNotificationId(null);
    setDeletingNotificationId(null);
    setSessionWarningSeconds(null);
    setSendAmount('');
    setRecipient('');
    setSendSuccess(false);
    setActiveTab('dashboard');
    setError(null);
    setSessionNotice('Password changed successfully. Please sign in again.');
  };

  const handleLogout = () => finishLogout();

  if (loading) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-50 to-slate-100 flex items-center justify-center">
        <Activity className="w-12 h-12 text-blue-600 animate-spin" />
      </div>
    );
  }

  if (!user) {
    return <LoginPage onLogin={setUser} notice={sessionNotice} />;
  }

  const otherUsers = allWallets.filter(u => u.user_id !== user.id);
  const queueMetrics = {
    pending: transactions.filter(t => t.status === 'PENDING'),
    processing: transactions.filter(t => t.status === 'PROCESSING'),
    completed: transactions.filter(t => t.status === 'COMPLETED'),
    failed: transactions.filter(t => t.status === 'FAILED')
  };
  const transactionHealthCards = [
    {
      title: 'Pending',
      value: queueMetrics.pending.length,
      Icon: Clock,
      iconClass: 'text-amber-500',
      borderClass: queueMetrics.pending.length > 0 ? 'border-amber-300' : 'border-slate-200',
      textClass: queueMetrics.pending.length > 0 ? 'text-amber-700' : 'text-slate-500',
      description: 'Accepted and waiting for the worker.',
      detail: queueMetrics.pending.length > 0
        ? `Oldest waiting ${formatRelativeAge(oldestFirst(queueMetrics.pending)[0]?.created_at)}`
        : 'Queue is clear.'
    },
    {
      title: 'Processing',
      value: queueMetrics.processing.length,
      Icon: Activity,
      iconClass: 'text-blue-500',
      borderClass: queueMetrics.processing.length > 0 ? 'border-blue-300' : 'border-slate-200',
      textClass: queueMetrics.processing.length > 0 ? 'text-blue-700' : 'text-slate-500',
      description: 'Worker claimed it and is moving money.',
      detail: queueMetrics.processing.length > 0
        ? `Oldest active ${formatRelativeAge(oldestFirst(queueMetrics.processing, 'processing_started_at')[0]?.processing_started_at || oldestFirst(queueMetrics.processing)[0]?.created_at)}`
        : 'No active transfer work.'
    },
    {
      title: 'Completed',
      value: queueMetrics.completed.length,
      Icon: CheckCircle,
      iconClass: 'text-green-500',
      borderClass: 'border-slate-200',
      textClass: 'text-green-700',
      description: 'Money moved and notifications were sent.',
      detail: queueMetrics.completed.length > 0
        ? `Latest completed ${formatRelativeAge(newestFirst(queueMetrics.completed)[0]?.completed_at || newestFirst(queueMetrics.completed)[0]?.created_at)}`
        : 'No successful transfers yet.'
    },
    {
      title: 'Failed',
      value: queueMetrics.failed.length,
      Icon: XCircle,
      iconClass: 'text-red-500',
      borderClass: queueMetrics.failed.length > 0 ? 'border-red-300' : 'border-slate-200',
      textClass: queueMetrics.failed.length > 0 ? 'text-red-700' : 'text-slate-500',
      description: 'Accepted by backend but could not finish.',
      detail: queueMetrics.failed.length > 0
        ? `Latest reason: ${newestFirst(queueMetrics.failed)[0]?.error_message || 'No reason stored'}`
        : 'No backend failures recorded.'
    }
  ];

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-50 to-slate-100">
      <header className="bg-white border-b border-slate-200 shadow-sm">
        <div className="max-w-7xl mx-auto px-6 py-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center space-x-3">
              <div className="w-10 h-10 bg-gradient-to-br from-blue-600 to-blue-700 rounded-lg flex items-center justify-center">
                <Wallet className="w-6 h-6 text-white" />
              </div>
              <div>
                <h1 className="text-xl font-bold text-slate-900">SwiftPay</h1>
                <p className="text-xs text-slate-500">Production Platform</p>
              </div>
            </div>
            
            <div className="flex items-center space-x-4">
              {metrics && (
                <div className="flex items-center space-x-2 text-sm">
                  <div className={`w-2 h-2 rounded-full ${
                    metrics.gateway?.status === 'healthy' ? 'bg-green-500 animate-pulse' : 'bg-red-500'
                  }`}></div>
                  <span className="text-slate-600 hidden sm:inline">System Status</span>
                </div>
              )}
              <div className="flex items-center space-x-2 px-3 py-2 bg-slate-100 rounded-lg">
                <User className="w-4 h-4 text-slate-600" />
                <span className="text-sm font-medium text-slate-900">{user.name}</span>
              </div>
              <button
                onClick={handleLogout}
                className="flex items-center space-x-2 px-3 py-2 text-slate-600 hover:text-slate-900 hover:bg-slate-100 rounded-lg transition-colors"
              >
                <LogOut className="w-4 h-4" />
                <span className="text-sm hidden sm:inline">Logout</span>
              </button>
            </div>
          </div>
        </div>
      </header>

      <nav className="bg-white border-b border-slate-200">
        <div className="max-w-7xl mx-auto px-6">
          <div className="flex space-x-8">
            {['dashboard', 'send', 'activity', 'monitoring', 'settings'].map(tab => (
              <button
                key={tab}
                onClick={() => setActiveTab(tab)}
                className={`px-4 py-3 text-sm font-medium border-b-2 transition-colors ${
                  activeTab === tab
                    ? 'border-blue-600 text-blue-600'
                    : 'border-transparent text-slate-600 hover:text-slate-900'
                }`}
              >
                {tab.charAt(0).toUpperCase() + tab.slice(1)}
              </button>
            ))}
          </div>
        </div>
      </nav>

      {error && (
        <div className="max-w-7xl mx-auto px-6 pt-4">
          <div className="bg-red-50 border border-red-200 rounded-lg p-4 flex items-start space-x-3">
            <AlertCircle className="w-5 h-5 text-red-600 mt-0.5" />
            <div className="flex-1">
              <p className="text-sm text-red-800">{error}</p>
              <button onClick={() => setError(null)} className="text-xs text-red-600 hover:text-red-700 mt-1 underline">
                Dismiss
              </button>
            </div>
          </div>
        </div>
      )}

      {sendSuccess && (
        <div className="max-w-7xl mx-auto px-6 pt-4">
          <div className="bg-green-50 border border-green-200 rounded-lg p-4 flex items-start space-x-3">
            <CheckCircle className="w-5 h-5 text-green-600 mt-0.5" />
            <p className="text-sm text-green-800">Transaction submitted! Processing asynchronously via RabbitMQ...</p>
          </div>
        </div>
      )}

      {sessionWarningSeconds !== null && (
        <div className="max-w-7xl mx-auto px-6 pt-4">
          <div className="bg-amber-50 border border-amber-200 rounded-lg p-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="flex items-start space-x-3">
              <Clock className="w-5 h-5 text-amber-600 mt-0.5" />
              <div>
                <p className="text-sm font-medium text-amber-900">Session timeout warning</p>
                <p className="text-sm text-amber-800">
                  You will be signed out in {Math.max(0, sessionWarningSeconds)} seconds because the session is inactive.
                </p>
              </div>
            </div>
            <div className="flex items-center space-x-2">
              <button
                onClick={resetSessionTimer}
                className="px-3 py-2 bg-amber-600 text-white text-sm font-medium rounded-lg hover:bg-amber-700 transition-colors"
              >
                Stay signed in
              </button>
              <button
                onClick={handleLogout}
                className="px-3 py-2 bg-white border border-amber-300 text-amber-800 text-sm font-medium rounded-lg hover:bg-amber-100 transition-colors"
              >
                Sign out now
              </button>
            </div>
          </div>
        </div>
      )}

      <main className="max-w-7xl mx-auto px-6 py-8">
        {activeTab === 'dashboard' && (
          <DashboardTab
            wallet={wallet}
            transactionHealthCards={transactionHealthCards}
            notifications={notifications}
            dataLoading={dataLoading}
            markingNotificationId={markingNotificationId}
            deletingNotificationId={deletingNotificationId}
            onMarkNotificationRead={handleMarkNotificationRead}
            onDeleteNotification={handleDeleteNotification}
          />
        )}

        {activeTab === 'send' && (
          <SendMoneyTab
            wallet={wallet}
            otherUsers={otherUsers}
            recipient={recipient}
            setRecipient={setRecipient}
            sendAmount={sendAmount}
            setSendAmount={setSendAmount}
            sendLoading={sendLoading}
            onSendMoney={handleSendMoney}
          />
        )}

        {activeTab === 'activity' && (
          <ActivityTab
            transactions={transactions}
            allWallets={allWallets}
            user={user}
          />
        )}

        {activeTab === 'monitoring' && (
          <MonitoringTab metrics={metrics} />
        )}

        {activeTab === 'settings' && (
          <SettingsTab
            user={user}
            onChangePassword={handleChangePassword}
          />
        )}
      </main>
    </div>
  );
}

import React from 'react';
import { AlertCircle, Bell, CheckCircle, Loader2, Trash2, Wallet } from 'lucide-react';

export function DashboardTab({
  wallet,
  transactionHealthCards,
  notifications,
  dataLoading,
  markingNotificationId,
  deletingNotificationId,
  onMarkNotificationRead,
  onDeleteNotification,
}) {
  if (!wallet) return null;

  const unreadCount = notifications.filter(notif => !notif.read).length;

  return (
    <div className="space-y-6">
      <div className="bg-gradient-to-br from-blue-600 to-blue-700 rounded-2xl p-8 text-white shadow-lg">
        <div className="flex justify-between items-start">
          <div>
            <p className="text-blue-100 text-sm mb-2">Available Balance</p>
            <h2 className="text-4xl font-bold">${parseFloat(wallet.balance).toLocaleString('en-US', { minimumFractionDigits: 2 })}</h2>
            <p className="text-blue-100 text-sm mt-4">{wallet.name}</p>
            <p className="text-blue-200 text-xs mt-1">{wallet.user_id}</p>
          </div>
          <Wallet className="w-12 h-12 text-blue-300 opacity-50" />
        </div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4">
        {transactionHealthCards.map(({ title, value, Icon, iconClass, borderClass, textClass, description, detail }) => (
          <div key={title} className={`bg-white rounded-lg p-5 shadow-sm border ${borderClass} min-h-[168px]`}>
            <div className="flex items-start justify-between mb-4">
              <div>
                <span className="text-slate-600 text-sm font-medium">{title}</span>
                <p className="text-3xl font-bold text-slate-900 mt-2">{value}</p>
              </div>
              <div className="w-9 h-9 rounded-lg bg-slate-50 border border-slate-200 flex items-center justify-center">
                <Icon className={`w-5 h-5 ${iconClass} ${title === 'Processing' && value > 0 ? 'animate-spin' : ''}`} />
              </div>
            </div>
            <p className="text-sm text-slate-600 leading-5">{description}</p>
            <p className={`text-xs font-medium mt-3 leading-5 ${textClass}`}>{detail}</p>
          </div>
        ))}
      </div>

      <div className="bg-white rounded-lg shadow-sm border border-slate-200 p-5">
        <div className="flex items-start space-x-3">
          <AlertCircle className="w-5 h-5 text-blue-600 mt-0.5" />
          <div>
            <h3 className="font-semibold text-slate-900">Transaction Pipeline</h3>
            <p className="text-sm text-slate-600 mt-1">
              Pending and Processing should usually stay at zero on a healthy local stack because RabbitMQ and the worker move quickly.
              Completed should grow during normal use. Failed should stay low and give a clear reason when something could not finish.
            </p>
          </div>
        </div>
      </div>

      <div className="bg-white rounded-xl shadow-sm border border-slate-200 p-6">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between mb-4">
          <div className="flex items-center space-x-2">
            <Bell className="w-5 h-5 text-slate-600" />
            <h3 className="font-semibold text-slate-900">Recent Notifications</h3>
          </div>
          <span className="text-xs font-medium text-slate-500">
            {unreadCount} unread
          </span>
        </div>
        <div className="space-y-3">
          {dataLoading && notifications.length === 0 && (
            <div className="flex items-center justify-center gap-2 rounded-lg bg-slate-50 py-6 text-sm text-slate-500">
              <Loader2 className="w-4 h-4 animate-spin" />
              Loading notifications...
            </div>
          )}
          {notifications.slice(0, 5).map(notif => (
            <div
              key={notif.id}
              className={`flex items-start gap-3 p-3 rounded-lg border ${
                notif.read ? 'bg-slate-50 border-slate-100' : 'bg-blue-50 border-blue-100'
              }`}
            >
              <div className={`w-2 h-2 rounded-full mt-2 ${
                notif.type === 'TRANSACTION_COMPLETED' ? 'bg-green-500' :
                notif.type === 'TRANSACTION_RECEIVED' ? 'bg-blue-500' : 'bg-red-500'
              }`} />
              <div className="flex-1">
                <p className="text-sm text-slate-900">{notif.message}</p>
                <p className="text-xs text-slate-500 mt-1">{new Date(notif.created_at).toLocaleString()}</p>
              </div>
              <div className="flex flex-col items-end gap-2">
                {notif.read ? (
                  <span className="inline-flex items-center gap-1 text-xs text-slate-500">
                    <CheckCircle className="w-3.5 h-3.5" />
                    Read
                  </span>
                ) : (
                  <button
                    onClick={() => onMarkNotificationRead(notif.id)}
                    disabled={markingNotificationId === notif.id || deletingNotificationId === notif.id}
                    className="text-xs font-medium text-blue-700 hover:text-blue-800 disabled:text-slate-400"
                  >
                    {markingNotificationId === notif.id ? 'Saving...' : 'Mark read'}
                  </button>
                )}
                <button
                  onClick={() => onDeleteNotification(notif.id)}
                  disabled={deletingNotificationId === notif.id || markingNotificationId === notif.id}
                  className="inline-flex items-center gap-1 text-xs font-medium text-red-600 hover:text-red-700 disabled:text-slate-400"
                >
                  <Trash2 className="w-3.5 h-3.5" />
                  {deletingNotificationId === notif.id ? 'Deleting...' : 'Delete'}
                </button>
              </div>
            </div>
          ))}
          {!dataLoading && notifications.length === 0 && (
            <p className="text-sm text-slate-500 text-center py-4">No notifications yet</p>
          )}
        </div>
      </div>
    </div>
  );
}

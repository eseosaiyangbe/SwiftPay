import React from 'react';
import { Activity, Send } from 'lucide-react';

export function SendMoneyTab({
  wallet,
  otherUsers,
  recipient,
  setRecipient,
  sendAmount,
  setSendAmount,
  sendLoading,
  onSendMoney,
}) {
  if (!wallet) return null;

  return (
    <div className="max-w-2xl mx-auto">
      <div className="bg-white rounded-xl shadow-sm border border-slate-200 p-8">
        <div className="flex items-center space-x-3 mb-6">
          <Send className="w-6 h-6 text-blue-600" />
          <h2 className="text-2xl font-bold text-slate-900">Send Money</h2>
        </div>

        <div className="space-y-6">
          <div>
            <label className="block text-sm font-medium text-slate-700 mb-2">Recipient</label>
            {otherUsers.length > 0 ? (
              <select
                value={recipient}
                onChange={(e) => setRecipient(e.target.value)}
                disabled={sendLoading}
                className="w-full px-4 py-3 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              >
                <option value="">Select recipient</option>
                {otherUsers.map(u => (
                  <option key={u.user_id} value={u.user_id}>{u.name} ({u.user_id})</option>
                ))}
              </select>
            ) : (
              <div className="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
                No other wallets are available yet. Create or register another user before sending money.
              </div>
            )}
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-700 mb-2">Amount</label>
            <div className="relative">
              <span className="absolute left-4 top-3 text-slate-500 text-lg">$</span>
              <input
                type="number"
                value={sendAmount}
                onChange={(e) => setSendAmount(e.target.value)}
                disabled={sendLoading}
                placeholder="0.00"
                step="0.01"
                className="w-full pl-8 pr-4 py-3 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
            </div>
            <p className="text-sm text-slate-500 mt-2">
              Available: ${parseFloat(wallet.balance).toLocaleString('en-US', { minimumFractionDigits: 2 })}
            </p>
          </div>

          <button
            onClick={onSendMoney}
            disabled={sendLoading || !sendAmount || !recipient || otherUsers.length === 0}
            className="w-full bg-blue-600 text-white py-3 rounded-lg font-medium hover:bg-blue-700 transition-colors disabled:bg-slate-300 flex items-center justify-center space-x-2"
          >
            {sendLoading ? (
              <>
                <Activity className="w-5 h-5 animate-spin" />
                <span>Processing...</span>
              </>
            ) : (
              <>
                <Send className="w-5 h-5" />
                <span>Send Money</span>
              </>
            )}
          </button>
        </div>

        <div className="mt-6 p-4 bg-blue-50 border border-blue-200 rounded-lg">
          <p className="text-sm text-blue-800">
            <strong>Secure:</strong> Transactions are processed asynchronously through RabbitMQ with full audit logging.
          </p>
        </div>
      </div>
    </div>
  );
}

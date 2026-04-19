import React from 'react';
import { Activity, ArrowDownLeft, CheckCircle, Clock, Send, XCircle } from 'lucide-react';

export function ActivityTab({ transactions, allWallets, user }) {
  return (
    <div className="bg-white rounded-xl shadow-sm border border-slate-200">
      <div className="p-6 border-b border-slate-200">
        <h2 className="text-xl font-bold text-slate-900">Transaction History</h2>
      </div>
      <div className="p-6">
        <div className="space-y-3">
          {transactions.map(txn => {
            const isOutgoing = txn.from_user_id === user.id;
            const isFailed = txn.status === 'FAILED';
            const otherParty = isOutgoing ? txn.to_user_id : txn.from_user_id;
            const otherWallet = allWallets.find(w => w.user_id === otherParty);

            return (
              <div key={txn.id} className="flex items-center justify-between gap-4 p-4 bg-slate-50 rounded-lg hover:bg-slate-100 transition-colors">
                <div className="flex items-center space-x-4">
                  <div className={`w-10 h-10 rounded-full flex items-center justify-center ${
                    isFailed ? 'bg-red-100' : isOutgoing ? 'bg-red-100' : 'bg-green-100'
                  }`}>
                    {isOutgoing ? <Send className="w-5 h-5 text-red-600" /> : <ArrowDownLeft className="w-5 h-5 text-green-600" />}
                  </div>
                  <div>
                    <p className="font-medium text-slate-900">
                      {isOutgoing ? 'Sent to' : 'Received from'} {otherWallet?.name || otherParty}
                    </p>
                    <p className="text-sm text-slate-500 font-mono">{txn.id}</p>
                    <p className="text-xs text-slate-400 mt-1">{new Date(txn.created_at).toLocaleString()}</p>
                    {isFailed && txn.error_message && (
                      <p className="text-xs text-red-600 mt-1">Reason: {txn.error_message}</p>
                    )}
                  </div>
                </div>
                <div className="text-right">
                  <p className={`font-bold text-lg ${isFailed ? 'text-slate-500' : isOutgoing ? 'text-red-600' : 'text-green-600'}`}>
                    {isFailed ? 'Attempted ' : isOutgoing ? '-' : '+'}${parseFloat(txn.amount).toFixed(2)}
                  </p>
                  <div className="flex items-center justify-end space-x-1 mt-1">
                    {txn.status === 'PENDING' && (
                      <>
                        <Clock className="w-4 h-4 text-amber-500" />
                        <span className="text-xs text-amber-600 font-medium">Pending</span>
                      </>
                    )}
                    {txn.status === 'PROCESSING' && (
                      <>
                        <Activity className="w-4 h-4 text-blue-500 animate-spin" />
                        <span className="text-xs text-blue-600 font-medium">Processing</span>
                      </>
                    )}
                    {txn.status === 'COMPLETED' && (
                      <>
                        <CheckCircle className="w-4 h-4 text-green-500" />
                        <span className="text-xs text-green-600 font-medium">Completed</span>
                      </>
                    )}
                    {txn.status === 'FAILED' && (
                      <>
                        <XCircle className="w-4 h-4 text-red-500" />
                        <span className="text-xs text-red-600 font-medium">Failed</span>
                      </>
                    )}
                  </div>
                </div>
              </div>
            );
          })}
          {transactions.length === 0 && (
            <p className="text-center text-slate-500 py-8">No transactions yet</p>
          )}
        </div>
      </div>
    </div>
  );
}


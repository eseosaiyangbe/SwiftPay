import React from 'react';

export function MonitoringTab({ metrics }) {
  if (!metrics) {
    return (
      <div className="bg-white rounded-xl shadow-sm border border-slate-200 p-8 text-center">
        <p className="text-sm text-slate-500">Loading service health metrics...</p>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="bg-white rounded-xl shadow-sm border border-slate-200 p-6">
        <h2 className="text-xl font-bold text-slate-900 mb-6">Microservices Health</h2>

        {Object.entries({
          'API Gateway': metrics.gateway,
          'Wallet Service': metrics.walletService,
          'Transaction Service': metrics.transactionService,
          'Notification Service': metrics.notificationService
        }).map(([name, service]) => (
          <div key={name} className="mb-6 last:mb-0">
            <div className="flex items-center justify-between mb-3">
              <h3 className="font-semibold text-slate-900">{name}</h3>
              <span className={`px-3 py-1 rounded-full text-xs font-medium ${
                service?.status === 'healthy' ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'
              }`}>
                {service?.status === 'healthy' ? 'HEALTHY' : 'UNHEALTHY'}
              </span>
            </div>
            {service?.database && (
              <div className="grid grid-cols-2 gap-4 mt-3">
                <div className="p-3 bg-blue-50 rounded-lg">
                  <p className="text-xs text-blue-600 mb-1">Database</p>
                  <p className="text-sm font-medium text-blue-900">{service.database}</p>
                </div>
                {service.redis && (
                  <div className="p-3 bg-purple-50 rounded-lg">
                    <p className="text-xs text-purple-600 mb-1">Redis Cache</p>
                    <p className="text-sm font-medium text-purple-900">{service.redis}</p>
                  </div>
                )}
                {service.rabbitmq && (
                  <div className="p-3 bg-orange-50 rounded-lg">
                    <p className="text-xs text-orange-600 mb-1">RabbitMQ</p>
                    <p className="text-sm font-medium text-orange-900">{service.rabbitmq}</p>
                  </div>
                )}
              </div>
            )}
          </div>
        ))}
      </div>

      <div className="bg-white rounded-xl shadow-sm border border-slate-200 p-6">
        <h3 className="font-semibold text-slate-900 mb-4">Production Architecture</h3>
        <div className="space-y-3 text-sm text-slate-600">
          <div className="flex items-start space-x-2">
            <div className="w-2 h-2 bg-blue-600 rounded-full mt-1.5" />
            <p><strong>JWT Auth:</strong> Bearer token authentication with refresh tokens</p>
          </div>
          <div className="flex items-start space-x-2">
            <div className="w-2 h-2 bg-green-600 rounded-full mt-1.5" />
            <p><strong>PostgreSQL:</strong> ACID transactions with row-level locking</p>
          </div>
          <div className="flex items-start space-x-2">
            <div className="w-2 h-2 bg-purple-600 rounded-full mt-1.5" />
            <p><strong>Redis:</strong> Session caching and idempotency tracking</p>
          </div>
          <div className="flex items-start space-x-2">
            <div className="w-2 h-2 bg-orange-600 rounded-full mt-1.5" />
            <p><strong>RabbitMQ:</strong> Async processing with DLQ and retry logic</p>
          </div>
          <div className="flex items-start space-x-2">
            <div className="w-2 h-2 bg-amber-600 rounded-full mt-1.5" />
            <p><strong>Circuit Breakers:</strong> Resilient service communication</p>
          </div>
          <div className="flex items-start space-x-2">
            <div className="w-2 h-2 bg-red-600 rounded-full mt-1.5" />
            <p><strong>Observability:</strong> Prometheus metrics + structured logging</p>
          </div>
        </div>
      </div>
    </div>
  );
}

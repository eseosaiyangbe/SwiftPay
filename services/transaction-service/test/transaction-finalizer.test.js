const { completeClaimedTransaction } = require('../transaction-finalizer');

function createClient() {
  return {
    query: jest.fn(async () => ({ rows: [], rowCount: 1 }))
  };
}

function createMetrics() {
  return {
    transactionDuration: {
      labels: jest.fn(() => ({ observe: jest.fn() }))
    },
    transactionTotal: {
      labels: jest.fn(() => ({ inc: jest.fn() }))
    }
  };
}

function decodeQueueMessages(channel) {
  return channel.sendToQueue.mock.calls.map(([queue, buffer, options]) => ({
    queue,
    payload: JSON.parse(buffer.toString()),
    options
  }));
}

const transaction = {
  id: 'txn-failure-test',
  from_user_id: 'sender-1',
  to_user_id: 'receiver-1',
  amount: 42.5
};

describe('completeClaimedTransaction', () => {
  it('marks transaction COMPLETED and queues sender/receiver notifications after wallet success', async () => {
    const client = createClient();
    const channel = { sendToQueue: jest.fn() };
    const metrics = createMetrics();

    const result = await completeClaimedTransaction({
      client,
      transaction,
      transferWallet: jest.fn(async () => ({ success: true })),
      notificationChannel: channel,
      metrics,
      logger: { info: jest.fn(), error: jest.fn() },
      now: () => 2000,
      startTime: 1000
    });

    expect(result).toEqual({ status: 'COMPLETED', transactionId: transaction.id });
    expect(client.query).toHaveBeenCalledWith(
      expect.stringContaining("SET status = 'COMPLETED'"),
      [transaction.id]
    );
    expect(metrics.transactionDuration.labels).toHaveBeenCalledWith('completed');
    expect(metrics.transactionTotal.labels).toHaveBeenCalledWith('completed', 'transfer', 'transaction-service');

    const messages = decodeQueueMessages(channel);
    expect(messages).toHaveLength(2);
    expect(messages[0]).toEqual(expect.objectContaining({
      queue: 'notifications',
      payload: expect.objectContaining({
        userId: 'sender-1',
        type: 'TRANSACTION_COMPLETED',
        transactionId: transaction.id
      }),
      options: { persistent: true }
    }));
    expect(messages[1]).toEqual(expect.objectContaining({
      queue: 'notifications',
      payload: expect.objectContaining({
        userId: 'receiver-1',
        type: 'TRANSACTION_RECEIVED',
        transactionId: transaction.id
      }),
      options: { persistent: true }
    }));
  });

  it('marks transaction FAILED and queues sender failure notification when Wallet Service fails', async () => {
    const client = createClient();
    const channel = { sendToQueue: jest.fn() };
    const metrics = createMetrics();
    const error = new Error('Wallet service temporarily unavailable');

    await expect(completeClaimedTransaction({
      client,
      transaction,
      transferWallet: jest.fn(async () => { throw error; }),
      notificationChannel: channel,
      metrics,
      logger: { info: jest.fn(), error: jest.fn() },
      now: () => 2500,
      startTime: 1000
    })).rejects.toThrow('Wallet service temporarily unavailable');

    expect(client.query).toHaveBeenCalledWith(
      expect.stringContaining("SET status = 'FAILED'"),
      ['Wallet service temporarily unavailable', transaction.id]
    );
    expect(metrics.transactionDuration.labels).toHaveBeenCalledWith('failed');
    expect(metrics.transactionTotal.labels).toHaveBeenCalledWith('failed', 'transfer', 'transaction-service');

    const messages = decodeQueueMessages(channel);
    expect(messages).toHaveLength(1);
    expect(messages[0]).toEqual(expect.objectContaining({
      queue: 'notifications',
      payload: {
        userId: 'sender-1',
        type: 'TRANSACTION_FAILED',
        message: 'Transaction failed: Wallet service temporarily unavailable',
        transactionId: transaction.id
      },
      options: { persistent: true }
    }));
  });
});

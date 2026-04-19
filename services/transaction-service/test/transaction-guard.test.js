const { claimPendingTransaction } = require('../transaction-guard');

function createClientWithRows(rows) {
  const client = {
    query: jest.fn()
  };

  client.query.mockImplementation(async (sql) => {
    if (sql === 'BEGIN' || sql === 'COMMIT' || sql === 'ROLLBACK') {
      return { rows: [] };
    }

    if (typeof sql === 'string' && sql.includes('SELECT id, status')) {
      return { rows };
    }

    if (typeof sql === 'string' && sql.includes('UPDATE transactions')) {
      return { rowCount: 1, rows: [] };
    }

    throw new Error(`Unexpected query: ${sql}`);
  });

  return client;
}

describe('claimPendingTransaction', () => {
  it('claims a PENDING transaction and moves it to PROCESSING', async () => {
    const client = createClientWithRows([{ id: 'txn-1', status: 'PENDING' }]);

    const result = await claimPendingTransaction(client, 'txn-1');

    expect(result).toEqual({
      claimed: true,
      transactionId: 'txn-1',
      status: 'PROCESSING'
    });
    expect(client.query).toHaveBeenCalledWith('BEGIN');
    expect(client.query).toHaveBeenCalledWith(
      expect.stringContaining('FOR UPDATE'),
      ['txn-1']
    );
    expect(client.query).toHaveBeenCalledWith(
      expect.stringContaining("SET status = 'PROCESSING'"),
      ['txn-1']
    );
    expect(client.query).toHaveBeenCalledWith('COMMIT');
  });

  it.each(['PROCESSING', 'COMPLETED', 'FAILED'])(
    'skips a duplicate message when transaction status is %s',
    async (status) => {
      const client = createClientWithRows([{ id: 'txn-2', status }]);
      const logger = { warn: jest.fn() };

      const result = await claimPendingTransaction(client, 'txn-2', logger, { retryCount: 1 });

      expect(result).toEqual({
        claimed: false,
        transactionId: 'txn-2',
        status
      });
      expect(client.query).toHaveBeenCalledWith('BEGIN');
      expect(client.query).toHaveBeenCalledWith(
        expect.stringContaining('FOR UPDATE'),
        ['txn-2']
      );
      expect(client.query).not.toHaveBeenCalledWith(
        expect.stringContaining("SET status = 'PROCESSING'"),
        ['txn-2']
      );
      expect(client.query).toHaveBeenCalledWith('COMMIT');
      expect(logger.warn).toHaveBeenCalledWith(
        'Skipping duplicate or non-pending transaction message',
        expect.objectContaining({ transactionId: 'txn-2', status, retryCount: 1 })
      );
    }
  );

  it('rolls back and throws when the transaction row is missing', async () => {
    const client = createClientWithRows([]);

    await expect(claimPendingTransaction(client, 'missing-txn')).rejects.toThrow(
      'Transaction not found: missing-txn'
    );
    expect(client.query).toHaveBeenCalledWith('ROLLBACK');
  });
});

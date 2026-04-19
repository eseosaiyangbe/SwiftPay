const { transferFunds } = require('../wallet-transfer');

function createWalletClient(initialBalances) {
  const balances = new Map(
    Object.entries(initialBalances).map(([userId, balance]) => [userId, Number.parseFloat(balance)])
  );

  const client = {
    balances,
    query: jest.fn()
  };

  client.query.mockImplementation(async (sql, params = []) => {
    if (sql === 'BEGIN' || sql === 'COMMIT' || sql === 'ROLLBACK') {
      return { rows: [] };
    }

    if (typeof sql === 'string' && sql.includes('SELECT user_id, balance')) {
      const userId = params[0];
      if (!balances.has(userId)) {
        return { rows: [] };
      }
      return {
        rows: [{ user_id: userId, balance: balances.get(userId).toFixed(2) }]
      };
    }

    if (typeof sql === 'string' && sql.includes('balance = balance -')) {
      const [amount, userId] = params;
      balances.set(userId, balances.get(userId) - Number.parseFloat(amount));
      return { rowCount: 1, rows: [] };
    }

    if (typeof sql === 'string' && sql.includes('balance = balance +')) {
      const [amount, userId] = params;
      balances.set(userId, balances.get(userId) + Number.parseFloat(amount));
      return { rowCount: 1, rows: [] };
    }

    throw new Error(`Unexpected query: ${sql}`);
  });

  return client;
}

describe('transferFunds', () => {
  it('debits sender and credits receiver in one committed transfer', async () => {
    const client = createWalletClient({
      'user-a': 1000,
      'user-b': 1000
    });

    const result = await transferFunds(client, {
      fromUserId: 'user-a',
      toUserId: 'user-b',
      amount: 25.75
    });

    expect(result).toEqual({
      ok: true,
      fromUserId: 'user-a',
      toUserId: 'user-b',
      amount: 25.75
    });
    expect(client.balances.get('user-a')).toBeCloseTo(974.25);
    expect(client.balances.get('user-b')).toBeCloseTo(1025.75);
    expect(client.query).toHaveBeenCalledWith('BEGIN');
    expect(client.query).toHaveBeenCalledWith('COMMIT');
    expect(client.query).not.toHaveBeenCalledWith('ROLLBACK');
  });

  it('rolls back and preserves balances when sender has insufficient funds', async () => {
    const client = createWalletClient({
      'user-a': 10,
      'user-b': 1000
    });

    const result = await transferFunds(client, {
      fromUserId: 'user-a',
      toUserId: 'user-b',
      amount: 25.75
    });

    expect(result).toEqual({
      ok: false,
      statusCode: 400,
      reason: 'insufficient_funds',
      error: 'Insufficient funds',
      available: '10.00',
      requested: 25.75
    });
    expect(client.balances.get('user-a')).toBeCloseTo(10);
    expect(client.balances.get('user-b')).toBeCloseTo(1000);
    expect(client.query).toHaveBeenCalledWith('ROLLBACK');
    expect(client.query).not.toHaveBeenCalledWith(
      expect.stringContaining('balance = balance -'),
      expect.any(Array)
    );
  });

  it('rolls back when either wallet does not exist', async () => {
    const client = createWalletClient({
      'user-a': 1000
    });

    const result = await transferFunds(client, {
      fromUserId: 'user-a',
      toUserId: 'missing-user',
      amount: 25.75
    });

    expect(result).toEqual({
      ok: false,
      statusCode: 404,
      reason: 'wallet_not_found',
      error: 'Wallet not found'
    });
    expect(client.balances.get('user-a')).toBeCloseTo(1000);
    expect(client.query).toHaveBeenCalledWith('ROLLBACK');
  });

  it('locks wallets in stable order to reduce deadlock risk', async () => {
    const client = createWalletClient({
      'user-a': 1000,
      'user-b': 1000
    });

    await transferFunds(client, {
      fromUserId: 'user-b',
      toUserId: 'user-a',
      amount: 25.75
    });

    const selectCalls = client.query.mock.calls.filter(([sql]) =>
      typeof sql === 'string' && sql.includes('SELECT user_id, balance')
    );
    expect(selectCalls[0][1]).toEqual(['user-a']);
    expect(selectCalls[1][1]).toEqual(['user-b']);
  });
});

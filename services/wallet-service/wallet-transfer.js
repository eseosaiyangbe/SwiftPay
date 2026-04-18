async function transferFunds(client, { fromUserId, toUserId, amount }) {
  const transferAmount = Number.parseFloat(amount);

  await client.query('BEGIN');

  const [firstId, secondId] = fromUserId < toUserId
    ? [fromUserId, toUserId]
    : [toUserId, fromUserId];

  const first = await client.query(
    'SELECT user_id, balance FROM wallets WHERE user_id = $1 FOR UPDATE',
    [firstId]
  );
  const second = await client.query(
    'SELECT user_id, balance FROM wallets WHERE user_id = $1 FOR UPDATE',
    [secondId]
  );

  if (first.rows.length === 0 || second.rows.length === 0) {
    await client.query('ROLLBACK');
    return {
      ok: false,
      statusCode: 404,
      reason: 'wallet_not_found',
      error: 'Wallet not found'
    };
  }

  const fromWallet = firstId === fromUserId ? first : second;
  if (Number.parseFloat(fromWallet.rows[0].balance) < transferAmount) {
    await client.query('ROLLBACK');
    return {
      ok: false,
      statusCode: 400,
      reason: 'insufficient_funds',
      error: 'Insufficient funds',
      available: fromWallet.rows[0].balance,
      requested: transferAmount
    };
  }

  await client.query(
    'UPDATE wallets SET balance = balance - $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
    [transferAmount, fromUserId]
  );
  await client.query(
    'UPDATE wallets SET balance = balance + $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
    [transferAmount, toUserId]
  );
  await client.query('COMMIT');

  return {
    ok: true,
    fromUserId,
    toUserId,
    amount: transferAmount
  };
}

module.exports = { transferFunds };

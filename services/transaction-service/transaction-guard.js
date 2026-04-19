async function claimPendingTransaction(client, transactionId, logger, context = {}) {
  await client.query('BEGIN');

  const existing = await client.query(
    `SELECT id, status
     FROM transactions
     WHERE id = $1
     FOR UPDATE`,
    [transactionId]
  );

  if (existing.rows.length === 0) {
    await client.query('ROLLBACK');
    throw new Error(`Transaction not found: ${transactionId}`);
  }

  const currentStatus = existing.rows[0].status;
  if (currentStatus !== 'PENDING') {
    await client.query('COMMIT');
    logger?.warn?.('Skipping duplicate or non-pending transaction message', {
      transactionId,
      status: currentStatus,
      ...context
    });
    return {
      claimed: false,
      transactionId,
      status: currentStatus
    };
  }

  await client.query(
    `UPDATE transactions
     SET status = 'PROCESSING', processing_started_at = CURRENT_TIMESTAMP
     WHERE id = $1`,
    [transactionId]
  );
  await client.query('COMMIT');

  return {
    claimed: true,
    transactionId,
    status: 'PROCESSING'
  };
}

module.exports = { claimPendingTransaction };

async function completeClaimedTransaction({
  client,
  transaction,
  transferWallet,
  notificationChannel,
  logger,
  metrics = {},
  now = () => Date.now(),
  startTime = now()
}) {
  try {
    await transferWallet(transaction);

    await client.query(
      `UPDATE transactions
       SET status = 'COMPLETED', completed_at = CURRENT_TIMESTAMP
       WHERE id = $1`,
      [transaction.id]
    );

    const duration = (now() - startTime) / 1000;
    metrics.transactionDuration?.labels?.('completed')?.observe?.(duration);
    metrics.transactionTotal?.labels?.('completed', 'transfer', 'transaction-service')?.inc?.();

    logger?.info?.('Transaction completed successfully:', {
      transactionId: transaction.id,
      duration
    });

    if (notificationChannel) {
      notificationChannel.sendToQueue('notifications', Buffer.from(JSON.stringify({
        userId: transaction.from_user_id,
        type: 'TRANSACTION_COMPLETED',
        message: `Sent $${transaction.amount} to ${transaction.to_user_id}`,
        transactionId: transaction.id,
        amount: transaction.amount,
        otherParty: transaction.to_user_id
      })), { persistent: true });

      notificationChannel.sendToQueue('notifications', Buffer.from(JSON.stringify({
        userId: transaction.to_user_id,
        type: 'TRANSACTION_RECEIVED',
        message: `Received $${transaction.amount} from ${transaction.from_user_id}`,
        transactionId: transaction.id,
        amount: transaction.amount,
        otherParty: transaction.from_user_id
      })), { persistent: true });
    }

    return {
      status: 'COMPLETED',
      transactionId: transaction.id
    };
  } catch (error) {
    const duration = (now() - startTime) / 1000;
    metrics.transactionDuration?.labels?.('failed')?.observe?.(duration);
    metrics.transactionTotal?.labels?.('failed', 'transfer', 'transaction-service')?.inc?.();

    logger?.error?.('Transaction failed:', {
      transactionId: transaction.id,
      error: error.message,
      duration
    });

    await client.query(
      `UPDATE transactions
       SET status = 'FAILED', error_message = $1, completed_at = CURRENT_TIMESTAMP
       WHERE id = $2`,
      [error.message, transaction.id]
    );

    if (notificationChannel) {
      notificationChannel.sendToQueue('notifications', Buffer.from(JSON.stringify({
        userId: transaction.from_user_id,
        type: 'TRANSACTION_FAILED',
        message: `Transaction failed: ${error.message}`,
        transactionId: transaction.id
      })), { persistent: true });
    }

    throw error;
  }
}

module.exports = { completeClaimedTransaction };

CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_wallets_user ON wallets(user_id);
CREATE INDEX idx_transactions_from_user ON transactions(from_user_id, created_at DESC);
CREATE INDEX idx_transactions_to_user ON transactions(to_user_id, created_at DESC);
CREATE INDEX idx_transactions_status ON transactions(status) WHERE status IN ('PENDING', 'PROCESSING');
CREATE INDEX idx_notifications_user ON notifications(user_id, created_at DESC);
CREATE INDEX idx_audit_logs_user ON audit_logs(user_id, created_at DESC);
CREATE INDEX idx_audit_logs_action ON audit_logs(action, created_at DESC);

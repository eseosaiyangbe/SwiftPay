export const SESSION_TIMEOUT_MS = Number(process.env.REACT_APP_SESSION_TIMEOUT_MS || 15 * 60 * 1000);
export const SESSION_WARNING_MS = Math.min(60 * 1000, Math.max(5000, SESSION_TIMEOUT_MS / 3));


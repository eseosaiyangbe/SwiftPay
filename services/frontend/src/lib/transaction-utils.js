export const formatRelativeAge = (value) => {
  if (!value) return 'No timestamp yet';

  const timestamp = new Date(value).getTime();
  if (Number.isNaN(timestamp)) return 'Unknown age';

  const seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000));
  if (seconds < 60) return `${seconds}s ago`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;

  const days = Math.floor(hours / 24);
  return `${days}d ago`;
};

export const newestFirst = (items) => {
  return [...items].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
};

export const oldestFirst = (items, timestampField = 'created_at') => {
  return [...items].sort((a, b) => {
    const aTime = new Date(a[timestampField] || a.created_at).getTime();
    const bTime = new Date(b[timestampField] || b.created_at).getTime();
    return aTime - bTime;
  });
};


// Human-readable byte sizes. Shared by the paste view and the admin page.
export function formatBytes(bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

// Coarse relative time from a Unix epoch-millis timestamp, e.g. "just now",
// "5min ago", "3h ago", "30d ago". Future timestamps (clock skew) clamp to "just now".
export function timeAgo(ms) {
  if (ms == null) return '';
  const secs = Math.floor((Date.now() - ms) / 1000);
  if (secs < 60) return 'just now';
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}min ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

// A traffic-light color for a byte size, so large items stand out at a glance:
// green < 1 MB, amber 1–50 MB, red > 50 MB.
export function sizeColor(bytes) {
  if (bytes == null) return 'inherit';
  if (bytes < 1024 * 1024) return '#2e7d32';
  if (bytes < 50 * 1024 * 1024) return '#ed6c02';
  return '#d32f2f';
}

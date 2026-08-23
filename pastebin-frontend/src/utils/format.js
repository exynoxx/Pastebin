// Max bytes for a single file OR folder upload. Mirrors the API's MAX_FILE_UPLOAD_BYTES
// (default 50 MB) so the client can reject oversize uploads before sending them.
export const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;

// Human-readable byte sizes. Shared by the paste view and the admin page.
export function formatBytes(bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

// Coarse relative time from a Unix epoch-millis timestamp, e.g. "now", "5 minutes ago",
// "3 hours ago", "yesterday". Intl handles the wording, plurals and the "now"/"yesterday"
// special cases; all we pick is the unit. Future timestamps (clock skew) clamp to "now".
const RELATIVE = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
const UNITS = [['day', 86400], ['hour', 3600], ['minute', 60]];

export function timeAgo(ms) {
  if (ms == null) return '';
  const secs = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  const [unit, per] = UNITS.find(([, per]) => secs >= per) || ['second', 1];
  return RELATIVE.format(-Math.floor(secs / per), unit);
}

// A traffic-light color for a byte size, so large items stand out at a glance:
// green < 1 MB, amber 1–50 MB, red > 50 MB.
export function sizeColor(bytes) {
  if (bytes == null) return 'inherit';
  if (bytes < 1024 * 1024) return '#2e7d32';
  if (bytes < 50 * 1024 * 1024) return '#ed6c02';
  return '#d32f2f';
}

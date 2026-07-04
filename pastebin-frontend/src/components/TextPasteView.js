import { useState } from 'react';
import { formatBytes } from '../utils/format';

export function TextPasteView({ paste, navigate }) {
  const rawUrl = `/api/pastes/${paste.id}/raw`;
  const [copied, setCopied] = useState(false);

  const copyContent = () => {
    if (!paste) return;
    navigator.clipboard.writeText(paste.content).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  };

  return (
    <div className="paste-view">
      <div className="card">
        <div className="paste-header">
          <div>
            <h2>{paste.title}</h2>
            <div className="paste-meta">
              Created: {new Date(paste.createdAt).toLocaleString()}
              {paste.size ? ` · ${formatBytes(paste.size)}` : ''}
            </div>
          </div>
          <div className="paste-actions">
            <button className="btn btn-secondary" onClick={() => navigate('/')}>
              New Paste
            </button>
            <button
              className="btn btn-secondary"
              onClick={copyContent}
              style={copied ? { backgroundColor: '#2e7d32', borderColor: '#2e7d32', color: '#fff' } : undefined}
            >
              {copied ? '✓ Copied!' : `Copy ${paste.isTruncated ? 'Preview' : 'Content'}`}
            </button>
            <a className="btn btn-secondary" href={rawUrl} target="_blank" rel="noreferrer">
              View Raw
            </a>
            <a className="btn btn-secondary" href={rawUrl} download={`${paste.id}.txt`}>
              Download
            </a>
          </div>
        </div>
        {paste.isTruncated && (
          <div className="alert alert-info">
            This paste is large ({formatBytes(paste.size)}). Showing a preview — use
            “View Raw” or “Download” for the full content.
          </div>
        )}
        <div className="paste-content">{paste.content}</div>
      </div>
    </div>
  );
}

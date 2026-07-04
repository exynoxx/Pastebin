import React, { useState } from 'react';
import axios from '../conf';

const SHOW_LIMIT_BYTES = 30 * 1024 * 1024; // 30 MB

export function FilePasteView({ file, navigate }) {
    const [downloading, setDownloading] = useState(false);

    const canShow = file && file.size < SHOW_LIMIT_BYTES;
    const showUrl = file ? `/api/files/${file.id}/raw` : '';
    // Images render inline from the same raw endpoint (served with their original
    // content type), so a picture paste previews on the page instead of only via "Show".
    const isImage = canShow && file.contentType?.startsWith('image/');

    const downloadFile = async () => {
      if (!file) return;
  
      setDownloading(true);
      try {
        const response = await axios.get(`/files/${file.id}/download`, {
          responseType: 'blob'
        });
  
        // Create download link
        const url = window.URL.createObjectURL(new Blob([response.data]));
        const link = document.createElement('a');
        link.href = url;
        link.setAttribute('download', file.originalName);
        document.body.appendChild(link);
        link.click();
        link.remove();
        window.URL.revokeObjectURL(url);
  
      } catch (error) {
        alert('Download failed');
      } finally {
        setDownloading(false);
      }
    };
  
    return (
      <div className="paste-view">
        <div className="card">
          <div className="paste-header">
            <div>
              <h2>📎 {file.originalName}</h2>
              <div className="paste-meta">
                Uploaded: {new Date(file.uploadedAt).toLocaleString()}
              </div>
            </div>
            <div className="paste-actions">
              <button className="btn btn-secondary" onClick={() => navigate('/')}>
                New Paste
              </button>
              {canShow && (
                <a
                  className="btn btn-secondary"
                  href={showUrl}
                  target="_blank"
                  rel="noreferrer"
                >
                  👁 Show
                </a>
              )}
              <button
                className="btn btn-secondary"
                onClick={downloadFile}
                disabled={downloading}
              >
                {downloading ? 'Downloading...' : '📥 Download File'}
              </button>
            </div>
          </div>

          {isImage && (
            <a
              className="image-preview"
              href={showUrl}
              target="_blank"
              rel="noreferrer"
              title="Open full size"
            >
              <img src={showUrl} alt={file.originalName} loading="lazy" />
            </a>
          )}

          <div className="file-info">
            <h4>📎 File Information</h4>
            <div className="file-details">
              <div><strong>Name:</strong> {file.originalName}</div>
              <div><strong>Size:</strong> {(file.size / 1024).toFixed(2)} KB</div>
              <div><strong>Type:</strong> {file.contentType}</div>
              <div><strong>Uploaded:</strong> {new Date(file.uploadedAt).toLocaleString()}</div>
              <div><strong>File ID:</strong> {file.id}</div>
            </div>
            {!canShow && (
              <div className="alert alert-info">
                This file is larger than 30 MB, so it can't be shown in the
                browser — use “Download File” instead.
              </div>
            )}
          </div>
        </div>
      </div>
    );
  }
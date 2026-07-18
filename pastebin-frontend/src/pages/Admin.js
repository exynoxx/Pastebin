import React, { useState, useEffect, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from '../conf';
import { Loading } from '../components/Loading';
import { formatBytes, timeAgo, sizeColor } from '../utils/format';

// Admin-gated delete endpoints differ by kind: pastes under /admin, files under /files.
const deleteUrl = (p) => (p.kind === 'file' ? `/files/${p.id}` : `/admin/pastes/${p.id}`);

// Unlisted admin page (no nav link points here). Protected by a shared-secret token
// the backend checks as the X-Admin-Token header. The token is prompted for on load
// and kept in sessionStorage for the tab's lifetime.
const TOKEN_KEY = 'adminToken';

function promptForToken() {
  const token = window.prompt('Admin token:') || '';
  if (token) sessionStorage.setItem(TOKEN_KEY, token);
  return token;
}

export function Admin() {
  const [pastes, setPastes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [groupByIp, setGroupByIp] = useState(false);
  const [view, setView] = useState('content'); // 'content' | 'accesslog'
  const [logEntries, setLogEntries] = useState([]);
  const navigate = useNavigate();

  // Reads the stored token, prompting once if it's missing.
  const authHeader = () => {
    let token = sessionStorage.getItem(TOKEN_KEY);
    if (!token) token = promptForToken();
    return { 'X-Admin-Token': token };
  };

  const handleAuthError = (err, fallback) => {
    if (err.response?.status === 401) {
      sessionStorage.removeItem(TOKEN_KEY);
      return 'Unauthorized — reload the page to enter the admin token again.';
    }
    return err.response?.data?.error || fallback;
  };

  const loadPastes = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await axios.get('/admin/pastes', { headers: authHeader() });
      setPastes(response.data);
    } catch (err) {
      setError(handleAuthError(err, 'Failed to load pastes'));
    } finally {
      setLoading(false);
    }
  }, []);

  // Access log lives in a flat file the API reads back; loaded lazily when its tab is opened.
  const loadAccessLog = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await axios.get('/admin/access-log', { headers: authHeader() });
      setLogEntries(response.data);
    } catch (err) {
      setError(handleAuthError(err, 'Failed to load access log'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadPastes();
  }, [loadPastes]);

  const showAccessLog = () => {
    setView('accesslog');
    loadAccessLog();
  };
  const refresh = () => (view === 'content' ? loadPastes() : loadAccessLog());

  const deletePaste = async (p) => {
    if (!window.confirm(`Delete ${p.kind} "${p.title}"? This cannot be undone.`)) return;
    try {
      await axios.delete(deleteUrl(p), { headers: authHeader() });
      setPastes((prev) => prev.filter((x) => x.id !== p.id));
    } catch (err) {
      alert(handleAuthError(err, `Failed to delete ${p.kind}`));
    }
  };

  // No bulk endpoint exists, so delete each item from the IP one request at a time.
  // Only the ids that actually deleted are removed from the list; failures stay visible.
  const deletePastesByIp = async (ip, group) => {
    if (!window.confirm(`Delete all ${group.length} item(s) from ${ip}? This cannot be undone.`)) return;
    const deleted = new Set();
    let failure = null;
    for (const p of group) {
      try {
        await axios.delete(deleteUrl(p), { headers: authHeader() });
        deleted.add(p.id);
      } catch (err) {
        failure = err;
      }
    }
    if (deleted.size > 0) {
      setPastes((prev) => prev.filter((p) => !deleted.has(p.id)));
    }
    if (failure) alert(handleAuthError(failure, 'Failed to delete some items'));
  };

  if (loading) {
    return <Loading text="Loading content..." />;
  }

  // Group items by creator IP, noisiest IP first. Empty IPs bucket under "unknown".
  const groups = groupByIp
    ? Object.entries(
        pastes.reduce((acc, p) => {
          const ip = p.ownerIp || 'unknown';
          (acc[ip] = acc[ip] || []).push(p);
          return acc;
        }, {})
      ).sort((a, b) => b[1].length - a[1].length)
    : [];

  return (
    <div className="paste-view">
      <div className="card">
        <div className="paste-header">
          <div>
            <h2>{view === 'content' ? 'Admin — All Content' : 'Admin — Access Log'}</h2>
            <div className="paste-meta">
              {view === 'content'
                ? `${pastes.length} item(s)`
                : `${logEntries.length} entries`}
            </div>
          </div>
          <div className="paste-actions">
            <button className="btn btn-secondary" onClick={() => navigate('/')}>
              Home
            </button>
            <button className="btn btn-secondary" onClick={refresh}>
              Refresh
            </button>
            <button
              className="btn btn-secondary"
              disabled={view === 'content'}
              onClick={() => setView('content')}
            >
              Content
            </button>
            <button
              className="btn btn-secondary"
              disabled={view === 'accesslog'}
              onClick={showAccessLog}
            >
              Access log
            </button>
            {view === 'content' && (
              <>
                <button
                  className="btn btn-secondary"
                  disabled={!groupByIp}
                  onClick={() => setGroupByIp(false)}
                >
                  Flat
                </button>
                <button
                  className="btn btn-secondary"
                  disabled={groupByIp}
                  onClick={() => setGroupByIp(true)}
                >
                  By IP
                </button>
              </>
            )}
          </div>
        </div>

        {error && <div className="alert alert-error">{error}</div>}

        {view === 'content' && (
          <>
            {!error && pastes.length === 0 && (
              <div className="alert alert-info">No content yet.</div>
            )}
            {groupByIp ? (
              groups.map(([ip, group]) => {
                const totalSize = group.reduce((sum, p) => sum + p.size, 0);
                return (
                  <div key={ip} className="ip-group" style={{ marginTop: 24 }}>
                    <div className="paste-header">
                      <div className="paste-meta">
                        {`IP ${ip} · ${group.length} item(s) · ${formatBytes(totalSize)}`}
                      </div>
                      <div className="paste-actions">
                        <button
                          className="btn btn-danger"
                          onClick={() => deletePastesByIp(ip, group)}
                        >
                          Delete all from this IP
                        </button>
                      </div>
                    </div>
                    <ul className="recent-pastes">{group.map(renderPasteItem)}</ul>
                  </div>
                );
              })
            ) : (
              <ul className="recent-pastes">{pastes.map(renderPasteItem)}</ul>
            )}
          </>
        )}

        {view === 'accesslog' && (
          <>
            {!error && logEntries.length === 0 && (
              <div className="alert alert-info">No access-log entries.</div>
            )}
            <ul className="recent-pastes">{logEntries.map(renderLogEntry)}</ul>
          </>
        )}
      </div>
    </div>
  );

  // Renders one content item (paste or file); shared by the flat and grouped-by-IP views.
  function renderPasteItem(p) {
    // Files open at their own route; pastes (inline or blob-backed) at the paste view.
    const viewUrl = p.kind === 'file' ? `/files/${p.id}` : `/paste/${p.id}`;
    const isPublic = p.visibility === 'public';
    // Plain click = View (SPA nav). Ctrl/Cmd/Shift/middle click falls through to the
    // browser's default anchor behaviour, opening the item in a new tab.
    const openView = (e) => {
      if (e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0) return;
      e.preventDefault();
      navigate(viewUrl);
    };
    return (
      <li key={p.id} className="recent-paste-item">
        <div className="paste-header" style={{ marginBottom: 0 }}>
          <a
            href={viewUrl}
            onClick={openView}
            style={{ display: 'block', flex: 1, color: 'inherit', textDecoration: 'none', cursor: 'pointer' }}
          >
            <div className="paste-title">
              <span className="badge" style={{ marginRight: 6, opacity: 0.7, fontSize: '0.85em' }}>
                [{p.kind}]
              </span>
              {p.title}
            </div>
            <div className="paste-meta">
              {new Date(p.createdAt).toLocaleString()}
              {` · ${timeAgo(p.createdAt)}`}
              {' · '}
              <span
                style={{
                  display: 'inline-block',
                  width: 8,
                  height: 8,
                  borderRadius: '50%',
                  backgroundColor: sizeColor(p.size),
                  marginRight: 4,
                  verticalAlign: 'middle',
                }}
              />
              {formatBytes(p.size)}
              {' · '}
              <span style={{ color: isPublic ? '#2e7d32' : '#d32f2f', fontWeight: 600 }}>
                {p.visibility}
              </span>
              {p.kind === 'file' && p.contentType ? ` · ${p.contentType}` : ''}
              {` · ${p.hasBlob ? 'blob' : 'text'}`}
              {` · IP ${p.ownerIp || 'unknown'}`}
            </div>
          </a>
          <div className="paste-actions">
            <button className="btn btn-secondary" onClick={() => navigate(viewUrl)}>
              View
            </button>
            <button className="btn btn-danger" onClick={() => deletePaste(p)}>
              Delete
            </button>
          </div>
        </div>
      </li>
    );
  }

  // Renders one access-log line: timestamp · ip · method · path · status · duration.
  function renderLogEntry(e, i) {
    const status = parseInt(e.status, 10);
    const statusColor =
      status >= 400 ? '#d32f2f' : status >= 200 && status < 300 ? '#2e7d32' : 'inherit';
    return (
      <li key={i} className="recent-paste-item">
        <div className="paste-meta">
          {e.timestamp}
          {` · ${e.ip} · ${e.method} `}
          {e.path}
          {' · '}
          <span style={{ color: statusColor, fontWeight: 600 }}>{e.status}</span>
          {` · ${e.duration}`}
        </div>
      </li>
    );
  }
}

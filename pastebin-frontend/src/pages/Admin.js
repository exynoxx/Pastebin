import React, { useState, useEffect, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from '../conf';
import { Loading } from '../components/Loading';
import { formatBytes } from '../utils/format';

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

  useEffect(() => {
    loadPastes();
  }, [loadPastes]);

  const deletePaste = async (id, title) => {
    if (!window.confirm(`Delete paste "${title}"? This cannot be undone.`)) return;
    try {
      await axios.delete(`/admin/pastes/${id}`, { headers: authHeader() });
      setPastes((prev) => prev.filter((p) => p.id !== id));
    } catch (err) {
      alert(handleAuthError(err, 'Failed to delete paste'));
    }
  };

  if (loading) {
    return <Loading text="Loading pastes..." />;
  }

  return (
    <div className="paste-view">
      <div className="card">
        <div className="paste-header">
          <div>
            <h2>Admin — All Pastes</h2>
            <div className="paste-meta">{pastes.length} paste(s)</div>
          </div>
          <div className="paste-actions">
            <button className="btn btn-secondary" onClick={() => navigate('/')}>
              Home
            </button>
            <button className="btn btn-secondary" onClick={loadPastes}>
              Refresh
            </button>
          </div>
        </div>

        {error && <div className="alert alert-error">{error}</div>}
        {!error && pastes.length === 0 && (
          <div className="alert alert-info">No pastes yet.</div>
        )}

        <ul className="recent-pastes">
          {pastes.map((p) => (
            <li key={p.id} className="recent-paste-item">
              <div className="paste-header" style={{ marginBottom: 0 }}>
                <div>
                  <div className="paste-title">{p.title}</div>
                  <div className="paste-meta">
                    {new Date(p.createdAt).toLocaleString()}
                    {` · ${formatBytes(p.size)}`}
                    {` · ${p.visibility}`}
                    {` · ${p.hasBlob ? 'blob' : 'text'}`}
                    {` · IP ${p.ownerIp || 'unknown'}`}
                  </div>
                </div>
                <div className="paste-actions">
                  <button
                    className="btn btn-secondary"
                    onClick={() => navigate(`/paste/${p.id}`)}
                  >
                    View
                  </button>
                  <button
                    className="btn btn-danger"
                    onClick={() => deletePaste(p.id, p.title)}
                  >
                    Delete
                  </button>
                </div>
              </div>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

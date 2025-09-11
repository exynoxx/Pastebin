import React, { useState, useEffect } from 'react';
import { BrowserRouter as Router, Routes, Route, useNavigate, useParams } from 'react-router-dom';
import axios from 'axios';

const API_BASE = 'http://0.0.0.0:8080/api';

// Configure axios defaults
axios.defaults.baseURL = API_BASE;

function App() {
  return (
    <Router>
      <div className="container">
        <header className="header">
          <h1>DevPaste</h1>
          <p>Share your code snippets and text with the world</p>
        </header>
        
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/paste/:id" element={<PasteView />} />
        </Routes>
      </div>
    </Router>
  );
}

function Home() {
  const [recentPastes, setRecentPastes] = useState([]);
  const [loading, setLoading] = useState(true);
  const navigate = useNavigate();

  useEffect(() => {
    loadRecentPastes();
  }, []);

  const loadRecentPastes = async () => {
    try {
      const response = await axios.get('/pastes');
      setRecentPastes(response.data);
    } catch (error) {
      console.error('Failed to load recent pastes:', error);
    } finally {
      setLoading(false);
    }
  };

  const handlePasteClick = (id) => {
    navigate(`/paste/${id}`);
  };

  return (
    <div className="main-content">
      <PasteForm onPasteCreated={loadRecentPastes} />
      
      <div className="card">
        <h3>Recent Pastes</h3>
        {loading ? (
          <div className="loading">Loading recent pastes...</div>
        ) : recentPastes.length > 0 ? (
          <ul className="recent-pastes">
            {recentPastes.map(paste => (
              <li 
                key={paste.id} 
                className="recent-paste-item"
                onClick={() => handlePasteClick(paste.id)}
              >
                <div className="paste-title">{paste.title}</div>
                <div className="paste-meta">
                  {new Date(paste.createdAt).toLocaleString()}
                </div>
              </li>
            ))}
          </ul>
        ) : (
          <p>No recent pastes found.</p>
        )}
      </div>
    </div>
  );
}

function PasteForm({ onPasteCreated }) {
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState(null);
  const navigate = useNavigate();

  const handleSubmit = async (e) => {
    e.preventDefault();
    
    if (!content.trim()) {
      setMessage({ type: 'error', text: 'Content cannot be empty' });
      return;
    }

    setLoading(true);
    setMessage(null);

    try {
      const response = await axios.post('/pastes', {
        title: title.trim(),
        content: content
      });

      const pasteUrl = `${window.location.origin}/paste/${response.data.id}`;
      setMessage({
        type: 'success',
        text: 'Paste created successfully!',
        url: pasteUrl,
        id: response.data.id
      });

      // Reset form
      setTitle('');
      setContent('');
      
      // Refresh recent pastes
      if (onPasteCreated) {
        onPasteCreated();
      }

    } catch (error) {
      const errorMessage = error.response?.data?.error || 'Failed to create paste';
      setMessage({ type: 'error', text: errorMessage });
    } finally {
      setLoading(false);
    }
  };

  const copyToClipboard = (text) => {
    navigator.clipboard.writeText(text).then(() => {
      alert('URL copied to clipboard!');
    });
  };

  const viewPaste = (id) => {
    navigate(`/paste/${id}`);
  };

  return (
    <div className="card">
      <h2>Create New Paste</h2>
      
      {message && (
        <div className={`alert alert-${message.type}`}>
          {message.text}
          {message.url && (
            <div className="url-display">
              <span>{message.url}</span>
              <div>
                <button 
                  className="copy-btn"
                  onClick={() => copyToClipboard(message.url)}
                >
                  Copy
                </button>
                <button 
                  className="copy-btn"
                  style={{ marginLeft: '5px', background: '#007bff' }}
                  onClick={() => viewPaste(message.id)}
                >
                  View
                </button>
              </div>
            </div>
          )}
        </div>
      )}
      
      <form onSubmit={handleSubmit}>
        <div className="form-group">
          <label htmlFor="title">Title</label>
          <input
            type="text"
            id="title"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="Enter paste title (optional)"
          />
        </div>

        <div className="form-group">
          <label htmlFor="content">Content</label>
          <textarea
            id="content"
            value={content}
            onChange={(e) => setContent(e.target.value)}
            placeholder="Paste your content here..."
            required
          />
        </div>

        <button type="submit" className="btn" disabled={loading}>
          {loading ? 'Creating...' : 'Create Paste'}
        </button>
      </form>
    </div>
  );
}

function PasteView() {
  const { id } = useParams();
  const [paste, setPaste] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const navigate = useNavigate();

  useEffect(() => {
    loadPaste();
  }, [id]);

  const loadPaste = async () => {
    try {
      const response = await axios.get(`/pastes/${id}`);
      setPaste(response.data);
    } catch (error) {
      const errorMessage = error.response?.data?.error || 'Failed to load paste';
      setError(errorMessage);
    } finally {
      setLoading(false);
    }
  };

  const copyContent = () => {
    if (paste) {
      navigator.clipboard.writeText(paste.content).then(() => {
        alert('Content copied to clipboard!');
      });
    }
  };

  if (loading) {
    return <div className="loading">Loading paste...</div>;
  }

  if (error) {
    return (
      <div className="card">
        <div className="alert alert-error">{error}</div>
        <button className="btn" onClick={() => navigate('/')}>
          Back to Home
        </button>
      </div>
    );
  }

  return (
    <div className="paste-view">
      <div className="card">
        <div className="paste-header">
          <div>
            <h2>{paste.title}</h2>
            <div className="paste-meta">
              Created: {new Date(paste.createdAt).toLocaleString()}
            </div>
          </div>
          <div className="paste-actions">
            <button className="btn btn-secondary" onClick={() => navigate('/')}>
              New Paste
            </button>
            <button className="btn btn-secondary" onClick={copyContent}>
              Copy Content
            </button>
          </div>
        </div>
        <div className="paste-content">{paste.content}</div>
      </div>
    </div>
  );
}

export default App;
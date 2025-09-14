import React, { useState, useEffect } from 'react';
import { BrowserRouter as Router, Routes, Route, useNavigate, useParams } from 'react-router-dom';
import axios from 'axios';

const API_BASE = '/api';

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
  const [isDragOver, setIsDragOver] = useState(false);
  const [uploadedFile, setUploadedFile] = useState(null);
  const navigate = useNavigate();

  const handleFileUpload = async (file) => {
    setLoading(true);

    try {
      const formData = new FormData();
      formData.append('file', file);

      const response = await axios.post('/files/upload', formData, {
        headers: {
          'Content-Type': 'multipart/form-data',
        },
        onUploadProgress: (progressEvent) => {
          const percentCompleted = Math.round((progressEvent.loaded * 100) / progressEvent.total);
          setMessage({
            type: 'info',
            text: `Uploading... ${percentCompleted}%`
          });
        }
      });

      const uploadResult = response.data;
      setUploadedFile(uploadResult);

      // Auto-set title if empty
      if (!title.trim()) {
        setTitle(file.name);
      }

      // Set content to file reference with metadata only
      setContent(`[FILE ATTACHMENT]\nFile: ${uploadResult.originalName}\nSize: ${(uploadResult.size / 1024).toFixed(2)} KB\nType: ${uploadResult.contentType}\nUploaded: ${new Date(uploadResult.uploadedAt).toLocaleString()}\n\nFile ID: ${uploadResult.id}`);

      setMessage({
        type: 'success',
        text: `File "${uploadResult.originalName}" uploaded successfully!`
      });

    } catch (error) {
      const errorMessage = error.response?.data?.error || 'Upload failed';
      setMessage({ type: 'error', text: errorMessage });
    } finally {
      setLoading(false);
    }
  };

  const handleSubmit = async (e) => {
    e.preventDefault();

    if (!content.trim()) {
      setMessage({ type: 'error', text: 'Content cannot be empty' });
      return;
    }

    setLoading(true);
    setMessage(null);

    try {
      let pasteResponse;

      if (uploadedFile) {
        // Create paste from uploaded file
        pasteResponse = await axios.post('/files/create-paste-from-file', {
          fileId: uploadedFile.id,
          title: title.trim(),
          includeContent: false // Never include content, only metadata
        });
      } else {
        // Regular paste creation
        pasteResponse = await axios.post('/pastes', {
          title: title.trim(),
          content: content
        });
      }

      const pasteUrl = `${window.location.origin}/paste/${pasteResponse.data.pasteId || pasteResponse.data.id}`;
      setMessage({
        type: 'success',
        text: 'Paste created successfully!',
        url: pasteUrl,
        id: pasteResponse.data.pasteId || pasteResponse.data.id
      });

      // Reset form
      setTitle('');
      setContent('');
      setUploadedFile(null);

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

  const handleDrop = (e) => {
    e.preventDefault();
    setIsDragOver(false);

    const files = Array.from(e.dataTransfer.files);
    if (files.length > 0) {
      handleFileUpload(files[0]);
    }
  };

  const handleDragOver = (e) => {
    e.preventDefault();
    setIsDragOver(true);
  };

  const handleDragLeave = (e) => {
    e.preventDefault();
    setIsDragOver(false);
  };

  const handleFileInputChange = (e) => {
    const files = Array.from(e.target.files);
    if (files.length > 0) {
      handleFileUpload(files[0]);
    }
  };

  const clearContent = () => {
    setContent('');
    setTitle('');
    setUploadedFile(null);
    setMessage(null);
  };

  const downloadFile = async () => {
    if (!uploadedFile) return;

    try {
      const response = await axios.get(`/files/${uploadedFile.id}/download`, {
        responseType: 'blob'
      });

      // Create download link
      const url = window.URL.createObjectURL(new Blob([response.data]));
      const link = document.createElement('a');
      link.href = url;
      link.setAttribute('download', uploadedFile.originalName);
      document.body.appendChild(link);
      link.click();
      link.remove();
      window.URL.revokeObjectURL(url);

    } catch (error) {
      setMessage({ type: 'error', text: 'Download failed' });
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

        {uploadedFile && (
            <div className="file-info">
              <h4>📎 File Information</h4>
              <div className="file-details">
                <div><strong>Name:</strong> {uploadedFile.originalName}</div>
                <div><strong>Size:</strong> {(uploadedFile.size / 1024).toFixed(2)} KB</div>
                <div><strong>Type:</strong> {uploadedFile.contentType}</div>
                <div><strong>Uploaded:</strong> {new Date(uploadedFile.uploadedAt).toLocaleString()}</div>
                <div><strong>File ID:</strong> {uploadedFile.id}</div>
              </div>
              <div className="file-actions">
                <button
                    type="button"
                    className="btn-download"
                    onClick={downloadFile}
                >
                  📥 Download File
                </button>
                <button
                    type="button"
                    className="btn-clear"
                    onClick={clearContent}
                >
                  🗑️ Clear & Start Over
                </button>
              </div>
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

            {/* File Upload Button */}
            <div className="file-upload-section">
              <input
                  type="file"
                  id="file-input"
                  style={{ display: 'none' }}
                  onChange={handleFileInputChange}
                  accept="*/*"
              />
              <button
                  type="button"
                  className="btn-file-upload"
                  onClick={() => document.getElementById('file-input').click()}
              >
                📎 Choose File
              </button>
              <span className="file-help">or drag and drop a file below</span>
            </div>

            {/* Drag and Drop Textarea */}
            <div
                className={`textarea-container ${isDragOver ? 'drag-over' : ''}`}
                onDrop={handleDrop}
                onDragOver={handleDragOver}
                onDragLeave={handleDragLeave}
            >
            <textarea
                id="content"
                value={content}
                onChange={(e) => setContent(e.target.value)}
                placeholder="Paste your content here... or drag and drop any file!"
                required
            />
              {isDragOver && (
                  <div className="drag-overlay">
                    <div className="drag-message">
                      📎 Drop your file here
                    </div>
                  </div>
              )}
            </div>
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
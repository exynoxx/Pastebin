import React, { useState, useEffect } from 'react';
import { BrowserRouter as Router, Routes, Route, useNavigate, useParams } from 'react-router-dom';

import {PasteView} from "./pages/PasteView"
import {Admin} from "./pages/Admin"

import { PasteList } from './components/PasteList';
import { Loading } from './components/Loading';
import { FilePasteView } from './components/FilePasteView'

import axios from './conf';

// Builds a friendly notice from a 429 (Too Many Requests) response. Prefers the server's
// message and appends a human-readable wait derived from Retry-After / retryAfterSeconds.
function rateLimitMessage(error) {
  const data = error.response?.data || {};
  const seconds =
    Number(data.retryAfterSeconds) ||
    Number(error.response?.headers?.['retry-after']) ||
    0;

  let wait = '';
  if (seconds > 0) {
    wait =
      seconds >= 60
        ? ` Try again in about ${Math.ceil(seconds / 60)} minute${seconds >= 120 ? 's' : ''}.`
        : ` Try again in ${seconds} second${seconds === 1 ? '' : 's'}.`;
  }

  const base =
    data.error ||
    "You're creating pastes too quickly. Please slow down.";
  return `⏳ ${base}${wait}`;
}

// Common Components
function Alert({ message, onCopy, onView }) {
  if (!message) return null;

  return (
    <div className={`alert alert-${message.type}`}>
      {message.text}
      {message.url && (
        <div className="url-display">
          <span>{message.url}</span>
          <div>
            <button className="copy-btn" onClick={() => onCopy(message.url)}>
              Copy
            </button>
            <button
              className="copy-btn"
              style={{ marginLeft: '5px', background: '#9c6644' }}
              onClick={() => onView(message.id)}
            >
              View
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// File Upload Components
function FileUploadSection({ onFileUpload, onFolderUpload, loading }) {
  const handleFileInputChange = (e) => {
    const files = Array.from(e.target.files);
    if (files.length > 0) {
      onFileUpload(files[0]);
    }
    e.target.value = ''; // allow re-selecting the same file
  };

  const handleFolderInputChange = (e) => {
    if (e.target.files.length > 0) {
      onFolderUpload(e.target.files);
    }
    e.target.value = '';
  };

  return (
    <div className="file-upload-section">
      <input
        type="file"
        id="file-input"
        style={{ display: 'none' }}
        onChange={handleFileInputChange}
        accept="*/*"
      />
      {/* webkitdirectory makes the picker select a whole folder; set via ref because
          React doesn't render the non-standard attribute reliably from JSX. */}
      <input
        type="file"
        id="folder-input"
        style={{ display: 'none' }}
        onChange={handleFolderInputChange}
        ref={(el) => { if (el) { el.webkitdirectory = true; el.directory = true; } }}
        multiple
      />
      <button
        type="button"
        className="btn-file-upload"
        onClick={() => document.getElementById('file-input').click()}
        disabled={loading}
      >
        📎 Choose File
      </button>
      <button
        type="button"
        className="btn-file-upload"
        onClick={() => document.getElementById('folder-input').click()}
        disabled={loading}
      >
        📁 Choose Folder
      </button>
      <span className="file-help">or drag and drop a file below</span>
    </div>
  );
}

function FileInfo({ uploadedFile, onDownload, onClear }) {
  if (!uploadedFile) return null;

  const isImage = uploadedFile.contentType?.startsWith('image/');
  const rawUrl = `/api/files/${uploadedFile.id}/raw`;

  return (
    <div className="file-info">
      <h4>📎 File Information</h4>
      {isImage && (
        <a className="image-preview" href={rawUrl} target="_blank" rel="noreferrer" title="Open full size">
          <img src={rawUrl} alt={uploadedFile.originalName} loading="lazy" />
        </a>
      )}
      <div className="file-details">
        <div><strong>Name:</strong> {uploadedFile.originalName}</div>
        <div><strong>Size:</strong> {(uploadedFile.size / 1024).toFixed(2)} KB</div>
        <div><strong>Type:</strong> {uploadedFile.contentType}</div>
        <div><strong>Uploaded:</strong> {new Date(uploadedFile.uploadedAt).toLocaleString()}</div>
        <div><strong>File ID:</strong> {uploadedFile.id}</div>
      </div>
      <div className="file-actions">
        <button type="button" className="btn-download" onClick={onDownload}>
          📥 Download File
        </button>
        <button type="button" className="btn-clear" onClick={onClear}>
          🗑️ Clear & Start Over
        </button>
      </div>
    </div>
  );
}

// Paste Form Component
function PasteForm({ onPasteCreated }) {
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');
  const [visibility, setVisibility] = useState('public');
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
      formData.append('visibility', visibility);

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

      // Show success message with link to file paste
      const fileUrl = `${window.location.origin}/files/${uploadResult.id}`;
      setMessage({
        type: 'success',
        text: `File "${uploadResult.originalName}" uploaded successfully!`,
        url: fileUrl,
        id: uploadResult.id
      });

    } catch (error) {
      const errorMessage = error.response?.data?.error || 'Upload failed';
      setMessage({ type: 'error', text: errorMessage });
    } finally {
      setLoading(false);
    }
  };

  const handleFolderUpload = async (fileList) => {
    const files = Array.from(fileList);
    if (files.length === 0) return;

    setLoading(true);

    try {
      // The browser exposes each file's path relative to the picked folder; the first
      // segment is the folder's name. The server zips everything into one blob.
      const folderName = (files[0].webkitRelativePath || files[0].name).split('/')[0] || 'folder';

      const formData = new FormData();
      files.forEach((file) => {
        formData.append('files', file, file.webkitRelativePath || file.name);
      });
      formData.append('folderName', folderName);
      formData.append('visibility', visibility);

      const response = await axios.post('/files/upload-folder', formData, {
        headers: { 'Content-Type': 'multipart/form-data' },
        onUploadProgress: (progressEvent) => {
          const percentCompleted = Math.round((progressEvent.loaded * 100) / progressEvent.total);
          setMessage({ type: 'info', text: `Zipping & uploading folder... ${percentCompleted}%` });
        }
      });

      const uploadResult = response.data;
      setUploadedFile(uploadResult);

      if (!title.trim()) {
        setTitle(uploadResult.originalName);
      }

      setContent(`[FOLDER ARCHIVE]\nFolder: ${folderName}\nFiles: ${files.length}\nArchive: ${uploadResult.originalName}\nSize: ${(uploadResult.size / 1024).toFixed(2)} KB\nType: ${uploadResult.contentType}\n\nFile ID: ${uploadResult.id}`);

      const fileUrl = `${window.location.origin}/files/${uploadResult.id}`;
      setMessage({
        type: 'success',
        text: `Folder "${folderName}" (${files.length} files) zipped and uploaded successfully!`,
        url: fileUrl,
        id: uploadResult.id
      });

    } catch (error) {
      const errorMessage = error.response?.data?.error || 'Folder upload failed';
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
          includeContent: false, // Never include content, only metadata
          visibility
        });
      } else {
        // Regular paste creation
        pasteResponse = await axios.post('/pastes', {
          title: title.trim(),
          content: content,
          visibility
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
      setVisibility('public');
      setUploadedFile(null);

      // Refresh recent pastes
      if (onPasteCreated) {
        onPasteCreated();
      }

    } catch (error) {
      if (error.response?.status === 429) {
        setMessage({ type: 'warning', text: rateLimitMessage(error) });
      } else {
        const errorMessage = error.response?.data?.error || 'Failed to create paste';
        setMessage({ type: 'error', text: errorMessage });
      }
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
    // Check if it's a file ID or paste ID based on the URL structure
    if (message && message.url.includes('/files/')) {
      navigate(`/files/${id}`);
    } else {
      navigate(`/paste/${id}`);
    }
  };

  return (
    <div className="card">
      <h2>Create New Paste</h2>

      <Alert 
        message={message} 
        onCopy={copyToClipboard}
        onView={viewPaste}
      />

      <FileInfo 
        uploadedFile={uploadedFile}
        onDownload={downloadFile}
        onClear={clearContent}
      />

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
          <label htmlFor="visibility-toggle">Visibility</label>
          <div className="visibility-toggle">
            <button
              type="button"
              id="visibility-toggle"
              className={`toggle-switch ${visibility === 'private' ? 'private' : ''}`}
              role="switch"
              aria-checked={visibility === 'private'}
              onClick={() => setVisibility(visibility === 'private' ? 'public' : 'private')}
            >
              <span className="toggle-knob" />
            </button>
            <span className="toggle-label">
              {visibility === 'private'
                ? '🔒 Private — unlisted, only reachable by link'
                : '🌐 Public — shown in the recent list'}
            </span>
          </div>
        </div>

        <div className="form-group">
          <label htmlFor="content">Content</label>

          <FileUploadSection
            onFileUpload={handleFileUpload}
            onFolderUpload={handleFolderUpload}
            loading={loading}
          />

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


// Main Route Components
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

  const handlePasteClick = (paste) => {
    navigate(paste.kind === 'file' ? `/files/${paste.id}` : `/paste/${paste.id}`);
  };

  return (
    <div className="main-content">
      <PasteForm onPasteCreated={loadRecentPastes} />

      <div className="card">
        <h3>Recent Pastes</h3>
        <PasteList 
          pastes={recentPastes}
          loading={loading}
          onPasteClick={handlePasteClick}
        />
      </div>
    </div>
  );
}

function FileView() {
  const { id } = useParams();
  const [file, setFile] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const navigate = useNavigate();

  useEffect(() => {
    loadFile();
  }, [id]);

  const loadFile = async () => {
    try {
      const response = await axios.get(`/files/${id}`);
      setFile(response.data);
    } catch (error) {
      const errorMessage = error.response?.data?.error || 'Failed to load file';
      setError(errorMessage);
    } finally {
      setLoading(false);
    }
  };

  if (loading) {
    return <Loading text="Loading file..." />;
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

  return <FilePasteView file={file} navigate={navigate} />;
}

// Main App Component
function App() {
  return (
    <Router>
      <div className="container">
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/paste/:id" element={<PasteView />} />
          <Route path="/files/:id" element={<FileView />} />
          <Route path="/admin" element={<Admin />} />
        </Routes>
      </div>
    </Router>
  );
}

export default App;
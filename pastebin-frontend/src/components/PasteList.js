import React from 'react';
import { Loading } from './Loading';

function itemIcon(paste) {
  if (paste.kind !== 'file') return '📄';
  return paste.contentType?.startsWith('image/') ? '🖼️' : '📎';
}

function PasteItem({ paste, onClick }) {
  return (
    <li
      className="recent-paste-item"
      onClick={() => onClick(paste)}
    >
      <div className="paste-title">
        <span className="paste-icon" aria-hidden="true">{itemIcon(paste)}</span>
        {paste.title}
      </div>
      <div className="paste-meta">
        {new Date(paste.createdAt).toLocaleString()}
      </div>
    </li>
  );
}

export function PasteList({ pastes, loading, onPasteClick }) {
  if (loading) {
    return <Loading text="Loading recent pastes..." />;
  }

  if (pastes.length === 0) {
    return <p>No recent pastes found.</p>;
  }

  return (
    <ul className="recent-pastes">
      {pastes.map(paste => (
        <PasteItem 
          key={paste.id} 
          paste={paste} 
          onClick={onPasteClick}
        />
      ))}
    </ul>
  );
}
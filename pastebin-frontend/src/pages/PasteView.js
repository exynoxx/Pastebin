import React, { useState, useEffect } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import axios from '../conf';
import { TextPasteView } from "../components/TextPasteView";
import { Loading } from '../components/Loading';


export function PasteView() {
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

    if (loading) {
        return <Loading text="Loading paste..." />;
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

    return <TextPasteView paste={paste} navigate={navigate} />;
}  
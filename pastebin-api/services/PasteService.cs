using System.Collections.Concurrent;
using pastebin.api.models;

namespace pastebin.api.services;

public interface IPasteService
{
    Task<Paste> CreatePasteAsync(CreatePasteRequest request);
    Task<Paste?> GetPasteAsync(string id);
    Task<List<Paste>> GetRecentPastesAsync(int limit = 10);
}
public class PasteService : IPasteService
{
    private readonly ConcurrentDictionary<string, Paste> _pastes = new();

    public Task<Paste> CreatePasteAsync(CreatePasteRequest request)
    {
        var id = GenerateId();
        var paste = new Paste
        {
            Id = id,
            Title = string.IsNullOrWhiteSpace(request.Title) ? "Untitled" : request.Title.Trim(),
            Content = request.Content ?? string.Empty
        };

        _pastes[id] = paste;
        return Task.FromResult(paste);
    }

    public Task<Paste?> GetPasteAsync(string id)
    {
        _pastes.TryGetValue(id, out var paste);
        return Task.FromResult(paste);
    }

    public Task<List<Paste>> GetRecentPastesAsync(int limit = 10)
    {
        var recent = _pastes.Values
            .OrderByDescending(p => p.CreatedAt)
            .Take(Math.Min(limit, 50))
            .ToList();
        return Task.FromResult(recent);
    }

    private static string GenerateId()
    {
        const string chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        var random = new Random();
        return new string(Enumerable.Repeat(chars, 8)
            .Select(s => s[random.Next(s.Length)]).ToArray());
    }
}
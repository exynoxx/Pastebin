using System.Collections.Concurrent;
using MongoDB.Driver;
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
    private readonly IMongoDatabase _database;

    public PasteService(IMongoDatabase database)
    {
        this._database = database;
    }

    public async Task<Paste> CreatePasteAsync(CreatePasteRequest request)
    {
        var id = GenerateId();
        var paste = new Paste
        {
            Id = id,
            Title = string.IsNullOrWhiteSpace(request.Title) ? "Untitled" : request.Title.Trim(),
            Content = request.Content ?? string.Empty
        };
        
        await _database.GetCollection<Paste>("pastes").InsertOneAsync(paste);
        return paste;
    }

    public async Task<Paste?> GetPasteAsync(string id)
    {
        return await _database
            .GetCollection<Paste>("pastes").Find(x=>x.Id == id)
            .SingleOrDefaultAsync();
    }

    public async Task<List<Paste>> GetRecentPastesAsync(int limit = 50)
    {
        return await _database.GetCollection<Paste>("pastes")
            .Find(_ => true)
            .SortByDescending(p => p.CreatedAt)
            .Limit(limit)
            .ToListAsync();
    }

    private static string GenerateId()
    {
        const string chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        var random = new Random();
        return new string(Enumerable.Repeat(chars, 8)
            .Select(s => s[random.Next(s.Length)]).ToArray());
    }
}
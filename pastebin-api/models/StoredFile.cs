namespace pastebin.api.models;

public record StoredFile
{
    public required string Id { get; init; } = string.Empty;
    public required string OriginalName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public required long Size { get; init; }
    public DateTime UploadedAt { get; init; } = DateTime.UtcNow;
    public required string StoragePath { get; init; } = string.Empty; // For file system storage
}
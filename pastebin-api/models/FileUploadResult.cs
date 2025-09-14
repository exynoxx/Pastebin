namespace pastebin.api.models;

public record FileUploadResult
{
    public string Id { get; init; } = string.Empty;
    public string OriginalName { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public long Size { get; init; }
    public DateTime UploadedAt { get; init; } = DateTime.UtcNow;
}
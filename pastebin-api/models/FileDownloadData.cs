namespace pastebin.api.models;

public record FileDownloadData
{
    public byte[] Data { get; init; } = [];
    public string ContentType { get; init; } = string.Empty;
    public string FileName { get; init; } = string.Empty;
}
namespace pastebin.api.models;

public record CreatePasteRequest
{
    public string Title { get; init; } = string.Empty;
    public string Content { get; init; } = string.Empty;
}
namespace pastebin.api.models;

public record CreatePasteFromFileRequest
{
    public string FileId { get; init; } = string.Empty;
    public string Title { get; init; } = string.Empty;
    public bool IncludeContent { get; init; } = true;
}
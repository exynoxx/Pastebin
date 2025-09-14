using MongoDB.Driver;
using pastebin.api.models;

namespace pastebin.api.services
{
    public interface IFileUploadService
    {
        Task<FileUploadResult> UploadFileAsync(IFormFile file);
        Task<StoredFile?> GetFileAsync(string fileId);
        Task<FileDownloadData?> DownloadFileAsync(string fileId);
        Task<bool> DeleteFileAsync(string fileId);
    }

    public class FileUploadService : IFileUploadService
    {
        private readonly IMongoDatabase _database;
        private readonly string _uploadPath;
        private readonly long _maxFileSize;

        // Text file extensions that should be stored as text
        /*private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
        {
            ".txt", ".md", ".js", ".jsx", ".ts", ".tsx", ".css", ".scss", ".sass",
            ".html", ".htm", ".xml", ".json", ".yml", ".yaml", ".ini", ".cfg",
            ".conf", ".log", ".sql", ".sh", ".bat", ".py", ".java", ".c", ".cpp",
            ".h", ".hpp", ".cs", ".php", ".rb", ".go", ".rs", ".swift", ".kt",
            ".dart", ".vue", ".svelte", ".r", ".m", ".scala", ".clj", ".pl"
        };*/

        public FileUploadService(IMongoDatabase database)
        {
            _database = database;
            _uploadPath = "uploads";
            _maxFileSize = 50_000_000; // 50MB default
        
            // Ensure upload directory exists
            Directory.CreateDirectory(_uploadPath);
        }

        public async Task<FileUploadResult> UploadFileAsync(IFormFile file)
        {
            if (file.Length > _maxFileSize)
            {
                throw new InvalidOperationException($"File size exceeds maximum allowed size of {_maxFileSize / (1024 * 1024)}MB");
            }

            var fileId = GenerateFileId();
            var extension = Path.GetExtension(file.FileName);
            //var isTextFile = IsTextFile(file.FileName, file.ContentType);
        
        
            // Read file content
            

            // For text files, also store as string
            /*if (isTextFile && fileData.Length > 0)
            {
                try
                {
                    content = System.Text.Encoding.UTF8.GetString(fileData);
                
                    // Create preview (first 500 characters)
                    previewContent = content.Length > 500 
                        ? content.Substring(0, 500) + "..."
                        : content;
                }
                catch
                {
                    // If UTF-8 fails, treat as binary
                    isTextFile = false;
                }
            }*/

            var filePath = Path.Combine(_uploadPath, $"{fileId}{extension}");
            await using (var fileStream = new FileStream(filePath, FileMode.Create))
            {
                await file.CopyToAsync(fileStream);
            }

            var storedFile = new StoredFile
            {
                Id = fileId,
                OriginalName = file.FileName,
                ContentType = file.ContentType ?? "application/octet-stream",
                Size = file.Length,
                UploadedAt = DateTime.UtcNow,
                StoragePath = filePath
            };
            await _database.GetCollection<StoredFile>("files").InsertOneAsync(storedFile);

            return new FileUploadResult
            {
                Id = fileId,
                OriginalName = file.FileName,
                ContentType = file.ContentType ?? "application/octet-stream",
                Size = file.Length,
                UploadedAt = DateTime.UtcNow,
            };
        }

        public async Task<StoredFile?> GetFileAsync(string fileId)
        {
            return await _database
                .GetCollection<StoredFile>("files")
                .Find(f => f.Id == fileId)
                .SingleOrDefaultAsync();
        }

        public async Task<FileDownloadData?> DownloadFileAsync(string fileId)
        {
            var file = await GetFileAsync(fileId);
            if (file == null) return null;

            return new FileDownloadData
            {
                Data = await File.ReadAllBytesAsync(file.StoragePath),
                ContentType = file.ContentType,
                FileName = file.OriginalName
            };
        }

        public async Task<bool> DeleteFileAsync(string fileId)
        {
            var file = await GetFileAsync(fileId);
            if (file == null) return false;

            // Delete from file system if stored there
            if (!string.IsNullOrEmpty(file.StoragePath) && File.Exists(file.StoragePath))
            {
                File.Delete(file.StoragePath);
            }

            // Delete from database
            var result = await _database
                .GetCollection<StoredFile>("files")
                .DeleteOneAsync(f => f.Id == fileId);

            return result.DeletedCount > 0;
        }


        /*private static bool IsTextFile(string fileName, string? contentType)
        {
            // Check by extension
            var extension = Path.GetExtension(fileName);
            if (TextExtensions.Contains(extension))
                return true;

            // Check by content type
            if (contentType != null)
            {
                return contentType.StartsWith("text/") ||
                       contentType == "application/json" ||
                       contentType == "application/xml" ||
                       contentType == "application/javascript" ||
                       contentType == "application/x-javascript";
            }

            return false;
        }*/

        private static string GenerateFileId()
        {
            return Guid.NewGuid().ToString("N")[..12]; // 12 character ID
        }
    }
}
using Microsoft.AspNetCore.Mvc;
using pastebin.api.models;
using pastebin.api.services;

namespace pastebin.api.controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class FilesController : ControllerBase
    {
        private readonly IFileUploadService _fileUploadService;
        private readonly IPasteService _pasteService;

        public FilesController(IFileUploadService fileUploadService, IPasteService pasteService)
        {
            _fileUploadService = fileUploadService;
            _pasteService = pasteService;
        }

        [HttpPost("upload")]
        [RequestSizeLimit(50_000_000)] // 50MB limit
        public async Task<IActionResult> UploadFile(IFormFile file)
        {
            if (file == null || file.Length == 0)
            {
                return BadRequest(new { error = "No file provided" });
            }

            try
            {
                var uploadResult = await _fileUploadService.UploadFileAsync(file);
                return Ok(uploadResult);
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { error = $"Upload failed: {ex.Message}" });
            }
        }


        [HttpGet("{fileId}")]
        public async Task<IActionResult> GetFile(string fileId)
        {
            try
            {
                var fileInfo = await _fileUploadService.GetFileAsync(fileId);
                if (fileInfo == null)
                {
                    return NotFound(new { error = "File not found" });
                }

                return Ok(fileInfo);
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { error = $"Failed to retrieve file: {ex.Message}" });
            }
        }

        [HttpGet("{fileId}/download")]
        public async Task<IActionResult> DownloadFile(string fileId)
        {
            try
            {
                var fileData = await _fileUploadService.DownloadFileAsync(fileId);
                if (fileData == null)
                {
                    return NotFound(new { error = "File not found" });
                }

                return File(fileData.Data, fileData.ContentType, fileData.FileName);
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { error = $"Download failed: {ex.Message}" });
            }
        }

        [HttpDelete("{fileId}")]
        public async Task<IActionResult> DeleteFile(string fileId)
        {
            try
            {
                var success = await _fileUploadService.DeleteFileAsync(fileId);
                if (!success)
                {
                    return NotFound(new { error = "File not found" });
                }

                return Ok(new { message = "File deleted successfully" });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { error = $"Delete failed: {ex.Message}" });
            }
        }
    }
}
using System.Text;
using System.Text.Unicode;
using Microsoft.AspNetCore.Mvc;
using MongoDB.Bson;
using MongoDB.Driver;
using MongoDB.Driver.GridFS;

namespace Pastebin;

[ApiController]
public class FileUploadController(GridFSBucket gridFs) : ControllerBase
{
    [HttpGet("ping")]
    public IActionResult Ping()
    {
        return Ok(new { message = "ping"});
    }

    [HttpPost("file")]
    [DisableRequestSizeLimit]
    public async Task<IActionResult> UploadFile(IFormFile file)
    {
        if (file == null || file.Length == 0)
            return BadRequest("No file uploaded.");

        Console.WriteLine("Uploading file...");
        try
        {
            using var stream = file.OpenReadStream();
            var fileId = await gridFs.UploadFromStreamAsync(file.FileName, stream);

            Console.WriteLine("done");

            return Ok(new { message = "File uploaded successfully", fileId = fileId.ToString() });
        }
        catch (Exception ex)
        {
            Console.WriteLine("err " + ex.StackTrace);
            return StatusCode(500, $"Error: {ex.Message}");
        }
    }
    
    [HttpPost("text")]
    public async Task<IActionResult> UploadFile(string text)
    {
        Console.WriteLine("Uploading text...");
        try
        {
            using var stream = new MemoryStream();
            stream.Write(Encoding.UTF8.GetBytes(text));
            stream.Position = 0;
            
            var name = Guid.NewGuid().ToString();
            var fileId = await gridFs.UploadFromStreamAsync(name, stream);

            Console.WriteLine("done");

            return Ok(new { message = "Text uploaded successfully", fileId = fileId.ToString() });
        }
        catch (Exception ex)
        {
            Console.WriteLine("err " + ex.StackTrace);
            return StatusCode(500, $"Error: {ex.Message}");
        }
    }

    [HttpGet("file/{id}")]
    public async Task<IActionResult> DownloadFile(string id)
    {
        if (!ObjectId.TryParse(id, out var objectId))
            return BadRequest("Invalid file ID.");

        try
        {
            var stream = await gridFs.OpenDownloadStreamAsync(objectId);
            return File(stream, "application/octet-stream", stream.FileInfo.Filename);
        }
        catch (GridFSFileNotFoundException)
        {
            return NotFound("File not found.");
        }
    }

    [HttpGet("list")]
    public async Task<IActionResult> ListFiles()
    {
        var filter = Builders<GridFSFileInfo<ObjectId>>.Filter.Empty;
        var files = await gridFs.Find(filter).ToListAsync();

        var fileList = new List<object>();
        foreach (var file in files)
        {
            fileList.Add(new
            {
                Id = file.Id.ToString(),
                FileName = file.Filename,
                Length = file.Length,
                UploadDate = file.UploadDateTime
            });
        }

        return Ok(fileList);
    }
}
using Microsoft.AspNetCore.Mvc;
using pastebin.api.models;
using pastebin.api.services;

namespace pastebin.api.controllers;

[ApiController]
[Route("api/[controller]")]
public class PastesController : ControllerBase
{
    private readonly IPasteService _pasteService;

    public PastesController(IPasteService pasteService)
    {
        _pasteService = pasteService;
    }

    [HttpPost]
    public async Task<IActionResult> CreatePaste([FromBody] CreatePasteRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Content))
        {
            return BadRequest(new { error = "Content cannot be empty" });
        }

        var paste = await _pasteService.CreatePasteAsync(request);
        return Ok(new { id = paste.Id });
    }

    [HttpGet("{id}")]
    public async Task<IActionResult> GetPaste(string id)
    {
        var paste = await _pasteService.GetPasteAsync(id);
        if (paste == null)
        {
            return NotFound(new { error = "Paste not found" });
        }
        return Ok(paste);
    }

    [HttpGet]
    public async Task<IActionResult> GetRecentPastes([FromQuery] int limit = 10)
    {
        var pastes = await _pasteService.GetRecentPastesAsync(limit);
        return Ok(pastes);
    }
}
using MongoDB.Driver;
using pastebin.api.services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();
builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowAll", policy =>
    {
        policy.AllowAnyOrigin()
            .AllowAnyMethod()
            .AllowAnyHeader();
    });
});

builder.Services.AddSingleton<IPasteService, PasteService>();
builder.Services.AddSingleton<IFileUploadService, FileUploadService>();

var mongo = new MongoClient("mongodb://admin:password123@mongo:27017/pastebin?authSource=admin");
builder.Services.AddSingleton<IMongoDatabase>(_ => mongo.GetDatabase("pastebin"));

var app = builder.Build();

app.UseCors("AllowAll");
app.UseRouting();
app.MapControllers();

app.Run("http://0.0.0.0:8080");
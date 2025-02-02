using System.Diagnostics;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using MongoDB.Driver;
using MongoDB.Driver.GridFS;

var builder = WebApplication.CreateBuilder(args);

var mongoClient = new MongoClient("mongodb://admin:adminpass@mongodb:27017");
var mongoDatabase = mongoClient.GetDatabase("FileStorageDB");

builder.Services.AddSingleton(mongoDatabase);
var fs = new GridFSBucket(mongoDatabase);
builder.Services.AddSingleton(fs);

builder.Services.AddSwaggerGen();
builder.Services.AddControllers();

builder.Services.Configure<FormOptions>(x =>
{
    x.ValueLengthLimit = int.MaxValue;
    x.MultipartBodyLengthLimit = int.MaxValue;
});

builder.Services.Configure<KestrelServerOptions>(options =>
{
    options.Limits.MaxRequestBodySize = null;
});


// Add CORS policy
builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowAll",
        policy => policy.AllowAnyOrigin()
            .AllowAnyMethod()
            .AllowAnyHeader());
});


var app = builder.Build();
app.UseCors("AllowAll");


app.UseSwagger();
app.UseSwaggerUI();
app.UseRouting(); 

app.MapControllers(); 


/*
using var memoryStream = new MemoryStream();
using var sw = new StreamWriter(memoryStream);
sw.WriteLine("test");
sw.Flush();
memoryStream.Position = 0;

await fs.UploadFromStreamAsync("test.txt", memoryStream);*/

/*
const string uri = "http://localhost:5000/swagger/index.html";
Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
*/

//app.Urls.Add("http://localhost:5000");
app.Run();
using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using PassByBack.Data;
using PassByBack.Models.Entities;
using PassByBack.Services;

var builder = WebApplication.CreateBuilder(args);

Console.WriteLine($"Environment: {builder.Environment.EnvironmentName}");
Console.WriteLine($"UserSecrets ID: {builder.Environment.ApplicationName}");
Console.WriteLine(
    $"JWT key found: {!string.IsNullOrWhiteSpace(builder.Configuration["Jwt:Key"])}"
);


builder.Services.AddControllers();

builder.Services.AddSwaggerGen();


builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseSqlServer(
        builder.Configuration.GetConnectionString("DefaultConnection")
    )
);



var jwtKey = builder.Configuration["Jwt:Key"]
             ?? throw new InvalidOperationException("JWT key is missing");

if (Encoding.UTF8.GetByteCount(jwtKey) < 32)
{
    throw new InvalidOperationException("JWT key is too short");
}

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.MapInboundClaims = false;

        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = builder.Configuration["Jwt:Issuer"],

            ValidateAudience = true,
            ValidAudience = builder.Configuration["Jwt:Audience"],

            ValidateIssuerSigningKey = true,
            IssuerSigningKey = new SymmetricSecurityKey(
                Encoding.UTF8.GetBytes(jwtKey)
            ),

            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromSeconds(30)
        };
    });

builder.Services.AddAuthorization();
builder.Services.AddRoleAuthorization();

builder.Services.AddScoped<AuthService>();

builder.Services
    .AddScoped<IPasswordHasher<UserAccount>,
        PasswordHasher<UserAccount>>();

builder.Services.AddCors(options =>
{
    options.AddPolicy("Frontend", policy =>
    {
        policy.AllowAnyOrigin()
            .AllowAnyMethod()
            .AllowAnyHeader();
    });
});

var app = builder.Build();

app.UseCors("Frontend");

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

    Console.WriteLine(
        await db.Database.CanConnectAsync()
            ? "Database connected!"
            : "Database connection failed!"
    );
}

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider
        .GetRequiredService<AppDbContext>();

    bool connected = await db.Database.CanConnectAsync();

    Console.WriteLine($"Connected: {connected}");

    if (connected)
    {
        int usersCount = await db.UserAccounts.CountAsync();
        Console.WriteLine($"Users count: {usersCount}");
    }
}

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();

app.UseCors("AllowAll");

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.MapGet("/api/health/db", async (
    AppDbContext db,
    CancellationToken cancellationToken) =>
{
    try
    {
        bool hasUsers = await db.UserAccounts
            .AnyAsync(cancellationToken);

        return Results.Ok(new
        {
            status = "OK",
            database = "Connected",
            userAccountTable = "Accessible",
            hasUsers
        });
    }
    catch (Exception ex)
    {
        app.Logger.LogError(ex, "Database health check failed");

        return Results.Problem(
            title: "Database connection failed",
            statusCode: 503
        );
    }
});

app.Run();
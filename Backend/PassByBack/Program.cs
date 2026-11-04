using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using PassByBack.Data;
using PassByBack.Models.Entities;
using PassByBack.Services;

var builder = WebApplication.CreateBuilder(args);

Console.WriteLine($"Environment: {builder.Environment.EnvironmentName}");
Console.WriteLine(
    $"JWT key found: {!string.IsNullOrWhiteSpace(builder.Configuration["Jwt:Key"])}"
);

builder.Services.AddControllers();

builder.Services.AddSwaggerGen(options =>
{
    options.AddSecurityDefinition("Bearer", new OpenApiSecurityScheme
    {
        Name = "Authorization",
        Type = SecuritySchemeType.Http,
        Scheme = "bearer",
        BearerFormat = "JWT",
        In = ParameterLocation.Header,
        Description = "Вставте access token (без слова Bearer)"
    });

    options.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        {
            new OpenApiSecurityScheme
            {
                Reference = new OpenApiReference
                {
                    Type = ReferenceType.SecurityScheme,
                    Id = "Bearer"
                }
            },
            Array.Empty<string>()
        }
    });
});

// Рядок підключення не зберігаємо в репозиторії:
// локально: dotnet user-secrets set "ConnectionStrings:DefaultConnection" "..."
// у Docker/на сервері: змінна середовища ConnectionStrings__DefaultConnection
var connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException(
        "Connection string 'DefaultConnection' is missing " +
        "(use user-secrets or the ConnectionStrings__DefaultConnection environment variable)");

builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseSqlServer(connectionString)
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
        policy.WithOrigins(
                "http://localhost:3000",
                "http://localhost:5173"
            )
            .AllowAnyHeader()
            .AllowAnyMethod();
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

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.MapGet("/api/health", () =>
{
    return Results.Ok(new
    {
        status = "OK",
        message = "PassByBack API is running"
    });
});

app.Run();

using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using PassByBack.Authorization;
using PassByBack.Services;

namespace PassByBack.Controllers;

[ApiController]
[Route("api/deliverer/orders/search")]
[Authorize(Policy = AppPolicies.RequireDeliveryRequester)]
public class DelivererOrderSearchController : ControllerBase
{
    private readonly DelivererOrderService _service;

    public DelivererOrderSearchController(
        DelivererOrderService service)
    {
        _service = service;
    }

    [HttpGet]
    public async Task<IActionResult> Search(
        [FromQuery]
        [Range(1, 1000000)]
        int page = 1,

        [FromQuery]
        [Range(1, 100)]
        int pageSize = 20,

        CancellationToken cancellationToken = default)
    {
        var sub = User.FindFirst("sub")?.Value;

        if (!long.TryParse(sub, out var userId))
        {
            return Unauthorized();
        }

        var result = await _service.SearchAsync(
            userId,
            page,
            pageSize,
            cancellationToken);

        return Ok(result);
    }
}
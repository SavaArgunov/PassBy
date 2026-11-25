using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using PassByBack.Authorization;
using PassByBack.Models.DelivererOrders;
using PassByBack.Services;

namespace PassByBack.Controllers;

[ApiController]
[Route("api/deliverer/orders")]
[Authorize(Policy = AppPolicies.RequireDeliverer)]
public class DelivererOrdersController : ControllerBase
{
    private readonly DelivererOrderService _service;

    public DelivererOrdersController(
        DelivererOrderService service)
    {
        _service = service;
    }

    [HttpPost]
    public async Task<IActionResult> Create(
        [FromBody] CreateDelivererOrderRequest request,
        CancellationToken cancellationToken)
    {
        var userId = GetUserId();

        if (userId is null)
        {
            return Unauthorized();
        }

        try
        {
            var result = await _service.CreateAsync(
                userId.Value,
                request,
                cancellationToken);

            return CreatedAtAction(
                nameof(GetById),
                new { id = result.DelivererIntentId },
                result);
        }
        catch (SqlException ex)
            when (ex.Number is 51010 or 51011 or 51012)
        {
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetAll(
        CancellationToken cancellationToken)
    {
        var userId = GetUserId();

        if (userId is null)
        {
            return Unauthorized();
        }

        var orders = await _service.GetAllAsync(
            userId.Value,
            cancellationToken);

        return Ok(orders);
    }

    [HttpGet("{id:long}")]
    public async Task<IActionResult> GetById(
        long id,
        CancellationToken cancellationToken)
    {
        var userId = GetUserId();

        if (userId is null)
        {
            return Unauthorized();
        }

        var order = await _service.GetByIdAsync(
            userId.Value,
            id,
            cancellationToken);

        if (order is null)
        {
            return NotFound();
        }

        return Ok(order);
    }

    [HttpPatch("{id:long}")]
    public IActionResult Update(long id)
    {
        return StatusCode(501);
    }

    [HttpPost("{id:long}/cancel")]
    public IActionResult Cancel(long id)
    {
        return StatusCode(501);
    }

    private long? GetUserId()
    {
        return long.TryParse(
            User.FindFirst("sub")?.Value,
            out var userId)
            ? userId
            : null;
    }
}
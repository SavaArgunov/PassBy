using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using PassByBack.Authorization;
using PassByBack.Models.DelivererOrders;
using PassByBack.Services;
using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;

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
    public async Task<IActionResult> Update(
        long id,
        [FromBody] JsonElement patch,
        CancellationToken cancellationToken)
    {
        var userId = GetUserId();

        if (userId is null)
        {
            return Unauthorized();
        }

        try
        {
            var order = await _service.UpdateAsync(
                userId.Value,
                id,
                patch,
                cancellationToken);

            if (order is null)
            {
                return NotFound();
            }

            return Ok(order);
        }
        catch (ValidationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (JsonException)
        {
            return BadRequest(new
            {
                message = "Invalid field value or type."
            });
        }
        catch (OrderUpdateConflictException ex)
        {
            return Conflict(new { message = ex.Message });
        }
        catch (SqlException ex)
            when (ex.Number is 51990 or 1205 or 51160)
        {
            return Conflict(new
            {
                message = "Order cannot be updated at this time."
            });
        }
        catch (DbUpdateException ex)
            when (ex.InnerException is SqlException sql &&
                  sql.Number is 51160 or 1205)
        {
            return Conflict(new
            {
                message = "Order cannot be updated at this time."
            });
        }
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
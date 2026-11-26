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
                  sql.Number is 51603 or 51160 or 1205)
        {
            return Conflict(new
            {
                message = "Order cannot be updated at this time."
            });
        }
    }

    [HttpPost("{id:long}/cancel")]
    public Task<IActionResult> Cancel(
        long id,
        CancellationToken cancellationToken)
    {
        return ChangeStatusAsync(
            id,
            "Cancelled",
            cancellationToken);
    }

    [HttpPost("{id:long}/publish")]
    public Task<IActionResult> Publish(
        long id,
        CancellationToken cancellationToken)
    {
        return ChangeStatusAsync(
            id,
            "Published",
            cancellationToken);
    }

    [HttpPost("{id:long}/unpublish")]
    public Task<IActionResult> Unpublish(
        long id,
        CancellationToken cancellationToken)
    {
        return ChangeStatusAsync(
            id,
            "Private",
            cancellationToken);
    }
    
    private async Task<IActionResult> ChangeStatusAsync(
        long id,
        string newStatusCode,
        CancellationToken cancellationToken)
    {
        var userId = GetUserId();

        if (userId is null)
        {
            return Unauthorized();
        }

        if (id <= 0)
        {
            return BadRequest(new
            {
                message = "Invalid order ID."
            });
        }

        try
        {
            var result = await _service.SetStatusAsync(
                userId.Value,
                id,
                newStatusCode,
                cancellationToken);

            return Ok(result);
        }
        catch (SqlException ex)
            when (ex.Number is 51620 or 51621)
        {
            return BadRequest(new
            {
                message = "Invalid order status parameters."
            });
        }
        catch (SqlException ex)
            when (ex.Number is 51623 or 51624)
        {
            return NotFound();
        }
        catch (SqlException ex)
            when (ex.Number is
                      51622 or
                      51625 or
                      51626 or
                      51627 or
                      51628 or
                      51629 or
                      51603 or
                      51160 or
                      1205)
        {
            var message = ex.Number switch
            {
                51625 or 51603 =>
                    "Cancelled order is immutable.",

                51626 or 51160 =>
                    "Fulfilled order is immutable.",

                51627 =>
                    "Invalid order status transition.",

                51628 =>
                    "Order has an active deal.",

                51629 =>
                    "Order has an active interaction.",

                _ =>
                    "Order cannot be updated at this time."
            };

            return Conflict(new { message });
        }
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
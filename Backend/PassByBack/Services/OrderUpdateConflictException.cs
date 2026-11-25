namespace PassByBack.Services;

public class OrderUpdateConflictException : Exception
{
    public OrderUpdateConflictException(string message)
        : base(message)
    {
        
    }
}
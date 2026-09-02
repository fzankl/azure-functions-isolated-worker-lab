namespace OrderProcessor;

public sealed class RetryOptions
{
    public int MaxRetries { get; set; } = 3;
}

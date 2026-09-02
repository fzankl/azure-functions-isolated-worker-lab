namespace OrderProcessor;

public interface IScopedDependency;

public sealed class ScopedDependency : IScopedDependency;

public sealed class SingletonConsumer
{
    public SingletonConsumer(IScopedDependency dependency) { }
}

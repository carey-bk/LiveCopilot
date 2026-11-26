namespace LiveCopilot.Core;


[System.Runtime.CompilerServices.CollectionBuilder(typeof(ValueList), nameof(ValueList.Create))]
[JsonConverter(typeof(ValueListJsonConverter))]
public sealed class ValueList<T> : IReadOnlyList<T>, IEquatable<ValueList<T>>
{
    private readonly T[] items;
    public ValueList(IEnumerable<T> items) => this.items = items.ToArray();
    public int Count => items.Length;
    public T this[int index] => items[index];
    public IEnumerator<T> GetEnumerator() => ((IEnumerable<T>)items).GetEnumerator();
    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
    public bool Equals(ValueList<T>? other) => other is not null && items.SequenceEqual(other.items);
    public override bool Equals(object? obj) => obj is ValueList<T> other && Equals(other);
    public override int GetHashCode() { var hash = new HashCode(); foreach (var item in items) hash.Add(item); return hash.ToHashCode(); }
}
public static class ValueList
{
    public static ValueList<T> Create<T>(ReadOnlySpan<T> items) => new(items.ToArray());
    public static ValueList<T> ToValueList<T>(this IEnumerable<T> items) => new(items);
}

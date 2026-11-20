namespace LiveCopilot.Core;


/// Synchronous stores are owned by their caller's serialized context, like Swift MainActor stores.
/// A UI adapter can marshal PropertyChanged without making Core depend on a dispatcher.
public abstract class ObservableStore : System.ComponentModel.INotifyPropertyChanged
{
    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    protected void Changed() => PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(string.Empty));
}

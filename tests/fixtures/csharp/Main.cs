using System.Threading;
using Godot;

public partial class Main : Node
{
    [Signal]
    public delegate void PulseEventHandler();

    [Export]
    public string State { get; set; } = "ready";

    [Export]
    public int ActionCount { get; set; }

    [Export]
    public int ActionReleaseCount { get; set; }

    [Export]
    public bool ActionPressed { get; set; }

    private Label _status = null!;
    private Label _clickStatus = null!;
    private Button _button = null!;

    public override void _Ready()
    {
        _status = GetNode<Label>("Status");
        _clickStatus = GetNode<Label>("ClickStatus");
        _button = GetNode<Button>("Button");
        _button.Pressed += OnButtonPressed;
    }

    public override void _ExitTree()
    {
        if (_button != null)
            _button.Pressed -= OnButtonPressed;
    }

    public override void _UnhandledInput(InputEvent @event)
    {
        if (@event.IsActionPressed("ui_accept"))
        {
            ActionCount++;
            ActionPressed = true;
            _status.Text = $"accepted:{ActionCount}";
        }
        else if (@event.IsActionReleased("ui_accept"))
        {
            ActionReleaseCount++;
            ActionPressed = false;
        }
    }

    public string Echo(string value) => value;

    public async void TriggerPulse()
    {
        await ToSignal(GetTree().CreateTimer(1.0), Godot.Timer.SignalName.Timeout);
        if (IsInsideTree())
            EmitSignal(SignalName.Pulse);
    }

    public void BlockMainThread() => Thread.Sleep(System.Threading.Timeout.Infinite);

    private void OnButtonPressed() => _clickStatus.Text = "clicked";
}

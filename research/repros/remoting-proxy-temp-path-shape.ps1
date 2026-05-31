# Static local analysis helper for RemoteDiscoveryHelper.GetModulePath shape.
# It records why the temp path was treated as a dead end in this first pass.
[pscustomobject]@{
    Source = 'src/System.Management.Automation/engine/Modules/RemoteDiscoveryHelper.cs'
    Observation = 'Implicit-remoting proxy paths are generated below Path.GetTempPath from sanitized module name, version, computer name, and local runspace InstanceId.'
    Triage = 'Not validated as exploitable in local-only testing; realistic exploitation would require pre-creating or racing a path containing a per-runspace GUID and then crossing a trust boundary.'
}

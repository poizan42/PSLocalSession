using System;
using System.IO.Pipes;
using System.Management.Automation.Remoting;
using System.Reflection;

namespace PSLocalSession.Server
{
    public static class PipeServer
    {
        private static readonly Type ServerType = typeof(RemoteSessionNamedPipeServer);
        private static readonly ConstructorInfo ServerCtor = ServerType.GetConstructor(
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
            null, new[] { typeof(string) }, null);
        private static readonly PropertyInfo StreamProperty = ServerType.GetProperty(
            "Stream", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly FieldInfo StreamField = ServerType.GetField(
            "<Stream>k__BackingField", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly PropertyInfo IsDisposedProperty = ServerType.GetProperty(
            "IsDisposed", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly MethodInfo StartListeningMethod = ServerType.GetMethod(
            "StartListening", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly FieldInfo IpcServerEnabledField = ServerType.GetField(
            "IPCNamedPipeServerEnabled", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly FieldInfo IpcServerField = ServerType.GetField(
            "IPCNamedPipeServer", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly PropertyInfo PipeNameProperty = ServerType.GetProperty(
            "PipeName", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly Type MediatorType = ServerType.Assembly.GetType(
            "System.Management.Automation.Remoting.Server.NamedPipeProcessMediator");
        private static readonly MethodInfo RunMethod = MediatorType == null ? null : MediatorType.GetMethod(
            "Run", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly Action<string, RemoteSessionNamedPipeServer> RunDelegate = CreateRunDelegate();

        private static Action<string, RemoteSessionNamedPipeServer> CreateRunDelegate()
        {
            if (RunMethod == null) { return null; }
            return (Action<string, RemoteSessionNamedPipeServer>)Delegate.CreateDelegate(
                typeof(Action<string, RemoteSessionNamedPipeServer>), RunMethod);
        }

        private static void EnsureAvailable()
        {
            if (ServerCtor == null || StreamProperty == null || StreamField == null ||
                IsDisposedProperty == null || StartListeningMethod == null ||
                RunMethod == null || RunDelegate == null)
            {
                throw new InvalidOperationException(
                    "This PowerShell version does not expose the named-pipe remoting server API " +
                    "PSLocalSession relies on. PowerShell 7.1 or later is required.");
            }
        }

        public static RemoteSessionNamedPipeServer Start(string pipeName, PipeSecurity security)
        {
            EnsureAvailable();
            if (string.IsNullOrEmpty(pipeName)) { throw new ArgumentException("Pipe name is required.", nameof(pipeName)); }
            if (security == null) { throw new ArgumentNullException(nameof(security)); }

            var server = (RemoteSessionNamedPipeServer)ServerCtor.Invoke(new object[] { pipeName });
            try
            {
                // The constructor already created one pipe with PowerShell's default DACL.
                // Drop it and recreate the same name with the caller-supplied security descriptor.
                var oldStream = (NamedPipeServerStream)StreamProperty.GetValue(server);
                oldStream.Dispose();

                // FirstPipeInstance is .NET 8+ and is not needed here: the previous stream
                // has already been disposed and the pipe name is free.
                NamedPipeServerStream stream = NamedPipeServerStreamAcl.Create(
                    pipeName,
                    PipeDirection.InOut,
                    1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous,
                    32768,
                    32768,
                    security);

                StreamField.SetValue(server, stream);

                // This is exactly the callback `pwsh -CustomPipeName` installs.
                Action<RemoteSessionNamedPipeServer> clientConnected =
                    s => RunDelegate(string.Empty, s);
                StartListeningMethod.Invoke(server, new object[] { clientConnected });
                return server;
            }
            catch
            {
                try { server.Dispose(); } catch { }
                throw;
            }
        }

        public static RemoteSessionNamedPipeServer StartDefault(PipeSecurity security)
        {
            EnsureAvailable();
            if (security == null) { throw new ArgumentNullException("security"); }
            if (IpcServerEnabledField == null || IpcServerField == null || PipeNameProperty == null)
            {
                throw new InvalidOperationException("The default IPC server fields are not available.");
            }

            IpcServerEnabledField.SetValue(null, false);
            var defaultServer = (RemoteSessionNamedPipeServer)IpcServerField.GetValue(null);
            if (defaultServer == null)
            {
                throw new InvalidOperationException("The default IPC server is not running.");
            }

            string pipeName = (string)PipeNameProperty.GetValue(defaultServer, null);
            defaultServer.Dispose();

            // The caller retries if the old instance has not disappeared yet.
            return Start(pipeName, security);
        }

        public static bool IsDisposed(RemoteSessionNamedPipeServer server)
        {
            try
            {
                return (bool)IsDisposedProperty.GetValue(server);
            }
            catch
            {
                return true;
            }
        }

        public static bool IsConnected(RemoteSessionNamedPipeServer server)
        {
            try
            {
                var stream = (NamedPipeServerStream)StreamProperty.GetValue(server);
                return stream != null && stream.IsConnected;
            }
            catch
            {
                return false;
            }
        }
    }
}

using System;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Threading;

namespace PSLocalSession.Server
{
    public static class PipeServer
    {
        private const BindingFlags Flags =
            BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;

        private static readonly Type ServerType = typeof(System.Management.Automation.PSObject).Assembly.GetType(
            "System.Management.Automation.Remoting.RemoteSessionNamedPipeServer");

        private static void EnsureAvailable()
        {
            if (ServerType == null)
            {
                throw new InvalidOperationException("RemoteSessionNamedPipeServer is not available.");
            }
        }

        public static object StartDefault(PipeSecurity security)
        {
            EnsureAvailable();
            if (security == null) { throw new ArgumentNullException("security"); }

            FieldInfo enabledField = ServerType.GetField("IPCNamedPipeServerEnabled", Flags);
            FieldInfo serverField = ServerType.GetField("IPCNamedPipeServer", Flags);
            PropertyInfo pipeNameProperty = ServerType.GetProperty("PipeName", Flags);
            MethodInfo disposeMethod = ServerType.GetMethod("Dispose", Flags);
            if (enabledField == null || serverField == null || pipeNameProperty == null || disposeMethod == null)
            {
                throw new InvalidOperationException("The default IPC server fields are not available.");
            }

            enabledField.SetValue(null, false);
            object defaultServer = serverField.GetValue(null);
            if (defaultServer == null)
            {
                throw new InvalidOperationException("The default IPC server is not running.");
            }

            string pipeName = (string)pipeNameProperty.GetValue(defaultServer, null);
            disposeMethod.Invoke(defaultServer, null);

            ConstructorInfo ctor = ServerType.GetConstructor(
                Flags, null, new Type[] { typeof(string) }, null);
            if (ctor == null)
            {
                throw new InvalidOperationException("RemoteSessionNamedPipeServer constructor not found.");
            }

            object server = null;
            Exception lastError = null;
            for (int attempt = 0; attempt < 50; attempt++)
            {
                try
                {
                    server = ctor.Invoke(new object[] { pipeName });
                    break;
                }
                catch (Exception e)
                {
                    lastError = e;
                    Thread.Sleep(50);
                }
            }
            if (server == null)
            {
                throw new IOException("Could not create the default server pipe.", lastError);
            }

            try
            {
                PropertyInfo streamProperty = ServerType.GetProperty("Stream", Flags);
                NamedPipeServerStream oldStream =
                    (NamedPipeServerStream)streamProperty.GetValue(server, null);
                oldStream.Dispose();

                NamedPipeServerStream stream = null;
                for (int attempt = 0; attempt < 50; attempt++)
                {
                    try
                    {
                        stream = new NamedPipeServerStream(
                            pipeName,
                            PipeDirection.InOut,
                            1,
                            PipeTransmissionMode.Message,
                            PipeOptions.Asynchronous,
                            32768,
                            32768,
                            security);
                        break;
                    }
                    catch (Exception e)
                    {
                        lastError = e;
                        Thread.Sleep(50);
                    }
                }
                if (stream == null)
                {
                    throw new IOException("Could not create the default server pipe.", lastError);
                }

                FieldInfo streamField = ServerType.GetField("_serverPipeStream", Flags);
                if (streamField == null)
                {
                    streamField = ServerType.GetField("<Stream>k__BackingField", Flags);
                }
                if (streamField == null)
                {
                    throw new InvalidOperationException("The server stream field was not found.");
                }
                streamField.SetValue(server, stream);

                StartListening(server);
                return server;
            }
            catch
            {
                try { disposeMethod.Invoke(server, null); } catch { }
                throw;
            }
        }

        private static void StartListening(object server)
        {
            Type mediatorType = ServerType.Assembly.GetType(
                "System.Management.Automation.Remoting.Server.NamedPipeProcessMediator");
            if (mediatorType == null)
            {
                throw new InvalidOperationException("NamedPipeProcessMediator is not available.");
            }

            MethodInfo runMethod = mediatorType.GetMethod(
                "Run", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
            if (runMethod == null)
            {
                throw new InvalidOperationException("NamedPipeProcessMediator.Run is not available.");
            }

            Type actionType = typeof(Action<,>).MakeGenericType(
                new Type[] { typeof(string), ServerType });
            Delegate run = Delegate.CreateDelegate(actionType, runMethod);

            MethodInfo makeCallback = typeof(PipeServer).GetMethod(
                "MakeCallback", BindingFlags.Static | BindingFlags.NonPublic);
            if (makeCallback == null)
            {
                throw new InvalidOperationException("The callback factory was not found.");
            }
            makeCallback = makeCallback.MakeGenericMethod(new Type[] { ServerType });
            Delegate callback = (Delegate)makeCallback.Invoke(null, new object[] { run });

            MethodInfo startListening = ServerType.GetMethod("StartListening", Flags);
            if (startListening == null)
            {
                throw new InvalidOperationException("StartListening was not found.");
            }
            startListening.Invoke(server, new object[] { callback });
        }

        private static Action<T> MakeCallback<T>(Delegate run)
        {
            return delegate(T server)
            {
                run.DynamicInvoke(new object[] { string.Empty, server });
            };
        }

        public static bool IsDisposed(object server)
        {
            try
            {
                PropertyInfo property = ServerType.GetProperty("IsDisposed", Flags);
                return (bool)property.GetValue(server, null);
            }
            catch
            {
                return true;
            }
        }

        public static bool IsConnected(object server)
        {
            try
            {
                PropertyInfo property = ServerType.GetProperty("Stream", Flags);
                NamedPipeServerStream stream =
                    (NamedPipeServerStream)property.GetValue(server, null);
                return stream != null && stream.IsConnected;
            }
            catch
            {
                return false;
            }
        }
    }
}

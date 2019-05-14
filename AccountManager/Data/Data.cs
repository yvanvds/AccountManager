using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    

    public sealed class Data
    {
        private static readonly Lazy<Data> data = new Lazy<Data>(() => new Data());

        public static Data Instance { get { return data.Value; } }

        private Data()
        {
            wisaServer = Properties.Settings.Default.WisaServer;
            wisaPort = Properties.Settings.Default.WisaPort;
            wisaDatabase = Properties.Settings.Default.WisaDatabase;
            wisaUser = Properties.Settings.Default.WisaUser;
            WisaPassword = Properties.Settings.Default.WisaPassword;
            WisaConnectionTested = Properties.Settings.Default.WisaConnectionTested;
        }

        private string wisaServer;

        public string WisaServer
        {
            get { return wisaServer; }
            set {
                wisaServer = value.Trim();
                Properties.Settings.Default.WisaServer = wisaServer;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaPort;

        public string WisaPort
        {
            get { return wisaPort; }
            set {
                wisaPort = value.Trim();
                Properties.Settings.Default.WisaPort = wisaPort;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaDatabase;

        public string WisaDatabase
        {
            get { return wisaDatabase; }
            set {
                wisaDatabase = value.Trim();
                Properties.Settings.Default.WisaDatabase = wisaDatabase;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaUser;

        public string WisaUser
        {
            get { return wisaUser; }
            set {
                wisaUser = value.Trim();
                Properties.Settings.Default.WisaUser = wisaUser;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private string wisaPassword;

        public string WisaPassword
        {
            get { return wisaPassword; }
            set {
                wisaPassword = value.Trim();
                Properties.Settings.Default.WisaPassword = wisaPassword;
                WisaConnectionTested = ConfigState.Unknown;
            }
        }

        private ConfigState wisaConnectionTested;

        public ConfigState WisaConnectionTested
        {
            get { return wisaConnectionTested; }
            set {
                wisaConnectionTested = value;
                Properties.Settings.Default.WisaConnectionTested = wisaConnectionTested;
                Properties.Settings.Default.Save();
            }
        }

        public void SetWisaCredentials()
        {
            int port = 0;
            try
            {
                port = Convert.ToInt32(WisaPort);
            } catch(Exception)
            {
                MainWindow.Instance.Log.AddError(Origin.Wisa, "Port should be a number");
                return;
            }
            

            WisaApi.Connector.Init(
                WisaServer, port, WisaUser, WisaPassword, WisaDatabase, MainWindow.Instance.Log
            );
        }
    }
}

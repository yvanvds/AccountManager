using MaterialDesignThemes.Wpf;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.ViewModels.Settings
{
    class AzureSettings : INotifyPropertyChanged
    {
        public IAsyncCommand TestConnectionCommand { get; private set; }

        public AzureSettings()
        {
            TestConnectionCommand = new RelayAsyncCommand(TestConnection);
        }

        private async Task TestConnection()
        {
            Indicator = true;
            State.App.Instance.Azure.Connect();
            ConnectIcon = PackIconKind.CloudTick;
            Indicator = false;
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        public string ClientID
        {
            get => State.App.Instance.Azure.ClientID.Value;
            set
            {
                State.App.Instance.Azure.ClientID.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(ClientID)));
            }
        }

        public string TenantID
        {
            get => State.App.Instance.Azure.TenantID.Value;
            set
            {
                State.App.Instance.Azure.TenantID.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(TenantID)));
            }
        }

        public string Domain
        {
            get => State.App.Instance.Azure.Domain.Value;
            set
            {
                State.App.Instance.Azure.Domain.Value = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Domain)));
            }
        }

        bool indicator = false;
        public bool Indicator
        {
            get => indicator;
            set
            {
                indicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Indicator)));
            }
        }

        private PackIconKind connectIcon = PackIconKind.CloudQuestion;
        public PackIconKind ConnectIcon
        {
            get => connectIcon;
            set
            {
                connectIcon = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(ConnectIcon)));
            }
        }
    }
}

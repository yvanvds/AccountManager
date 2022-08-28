using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.ViewModels.Dashboard
{
    class LinkedAccounts : INotifyPropertyChanged, State.IStateObserver
    {
        State.Linked.LinkedState state;
        public IAsyncCommand SyncCommand { get; private set; }

        public LinkedAccounts()
        {
            state = State.App.Instance.Linked;
            state.AddObserver(this);

            SyncCommand = new RelayAsyncCommand(Sync);
        }

        private async Task Sync()
        {
            Indicator = true;
            await State.App.Instance.Linked.Accounts.ReLink().ConfigureAwait(false);
            Indicator = false;
        }

        ~LinkedAccounts()
        {
            state.RemoveObserver(this);
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

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

        public int TotalWisaAccounts => state.Accounts.TotalWisaAccounts;
        public int TotalDirectoryAccounts => state.Accounts.TotalDirectoryAccounts;
        public int TotalSmartschoolAccounts => state.Accounts.TotalSmartschoolAccounts;
        public int TotalAzureAccounts => state.Accounts.TotalAzureAccounts;
        public int UnlinkedWisaAccounts => state.Accounts.UnlinkedWisaAccounts;
        public int UnlinkedDirectoryAccounts => state.Accounts.UnlinkedDirectoryAccounts;
        public int UnlinkedSmartschoolAccounts => state.Accounts.UnlinkedSmartschoolAccounts;
        public int UnlinkedAzureAccounts => state.Accounts.UnlinkedAzureAccounts;
        public int LinkedWisaAccounts => state.Accounts.LinkedWisaAccounts;
        public int LinkedDirectoryAccounts => state.Accounts.LinkedDirectoryAccounts;
        public int LinkedSmartschoolAccounts => state.Accounts.LinkedSmartschoolAccounts;
        public int LinkedAzureAccounts => state.Accounts.LinkedAzureAccounts;
        public string UnlinkedDirectoryColor => state.Accounts.UnlinkedDirectoryAccounts == 0 ? "DarkGreen" : "DarkRed";
        public string UnlinkedSmartschoolColor => state.Accounts.UnlinkedSmartschoolAccounts == 0 ? "DarkGreen" : "DarkRed";
        public string UnlinkedWisaColor => state.Accounts.UnlinkedWisaAccounts == 0 ? "DarkGreen" : "DarkRed";
        public string UnlinkedAzureColor => state.Accounts.UnlinkedAzureAccounts == 0 ? "DarkGreen" : "DarkRed";

        public void OnStateChanges()
        {
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalWisaAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalDirectoryAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalSmartschoolAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalAzureAccounts)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedWisaAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedDirectoryAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedSmartschoolAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedAzureAccounts)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedWisaAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedDirectoryAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedSmartschoolAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedAzureAccounts)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedWisaColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedDirectoryColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedSmartschoolColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedAzureColor)));
        }
    }
}

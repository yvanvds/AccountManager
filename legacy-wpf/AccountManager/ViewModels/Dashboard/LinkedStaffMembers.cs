using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.ViewModels.Dashboard
{
    class LinkedStaffMembers : INotifyPropertyChanged, State.IStateObserver
    {
        State.Linked.LinkedState state;
        public IAsyncCommand SyncCommand { get; private set; }

        public LinkedStaffMembers()
        {
            state = State.App.Instance.Linked;
            state.AddObserver(this);

            SyncCommand = new RelayAsyncCommand(Sync);
        }

        private async Task Sync()
        {
            Indicator = true;
            await State.App.Instance.Linked.Staff.ReLink().ConfigureAwait(false);
            Indicator = false;
        }

        ~LinkedStaffMembers()
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

        public int TotalWisaAccounts => state.Staff.TotalWisaAccounts;
        public int TotalSmartschoolAccounts => state.Staff.TotalSmartschoolAccounts;
        public int TotalAzureAccounts => state.Staff.TotalAzureAccounts;
        public int UnlinkedWisaAccounts => state.Staff.UnlinkedWisaAccounts;
        public int UnlinkedSmartschoolAccounts => state.Staff.UnlinkedSmartschoolAccounts;
        public int UnlinkedAzureAccounts => state.Staff.UnlinkedAzureAccounts;
        public int LinkedWisaAccounts => state.Staff.LinkedWisaAccounts;
        public int LinkedSmartschoolAccounts => state.Staff.LinkedSmartschoolAccounts;
        public int LinkedAzureAccounts => state.Staff.LinkedAzureAccounts;
        public string UnlinkedSmartschoolColor => state.Staff.UnlinkedSmartschoolAccounts == 0 ? "DarkGreen" : "DarkRed";
        public string UnlinkedWisaColor => state.Staff.UnlinkedWisaAccounts == 0 ? "DarkGreen" : "DarkRed";
        public string UnlinkedAzureColor => state.Staff.UnlinkedAzureAccounts == 0 ? "DarkGreen" : "DarkRed";

        public void OnStateChanges()
        {
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalWisaAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalSmartschoolAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalAzureAccounts)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedWisaAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedSmartschoolAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedAzureAccounts)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedWisaAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedSmartschoolAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedAzureAccounts)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedWisaColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedSmartschoolColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedAzureColor)));
        }
    }
}

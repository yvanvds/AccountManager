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
        public int TotalDirectoryAccounts => state.Staff.TotalDirectoryAccounts;
        public int TotalSmartschoolAccounts => state.Staff.TotalSmartschoolAccounts;
        public int TotalGoogleAccounts => state.Staff.TotalGoogleAccounts;
        public int UnlinkedWisaAccounts => state.Staff.UnlinkedWisaAccounts;
        public int UnlinkedDirectoryAccounts => state.Staff.UnlinkedDirectoryAccounts;
        public int UnlinkedSmartschoolAccounts => state.Staff.UnlinkedSmartschoolAccounts;
        public int UnlinkedGoogleAccounts => state.Staff.UnlinkedGoogleAccounts;
        public int LinkedWisaAccounts => state.Staff.LinkedWisaAccounts;
        public int LinkedDirectoryAccounts => state.Staff.LinkedDirectoryAccounts;
        public int LinkedSmartschoolAccounts => state.Staff.LinkedSmartschoolAccounts;
        public int LinkedGoogleAccounts => state.Staff.LinkedGoogleAccounts;
        public string UnlinkedDirectoryColor => state.Staff.UnlinkedDirectoryAccounts == 0 ? "DarkGreen" : "DarkRed";
        public string UnlinkedSmartschoolColor => state.Staff.UnlinkedSmartschoolAccounts == 0 ? "DarkGreen" : "DarkRed";
        public string UnlinkedWisaColor => state.Staff.UnlinkedWisaAccounts == 0 ? "DarkGreen" : "DarkRed";
        public string UnlinkedGoogleColor => state.Staff.UnlinkedGoogleAccounts == 0 ? "DarkGreen" : "DarkRed";

        public void OnStateChanges()
        {
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalWisaAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalDirectoryAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalSmartschoolAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalGoogleAccounts)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedWisaAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedDirectoryAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedSmartschoolAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedGoogleAccounts)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedWisaAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedDirectoryAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedSmartschoolAccounts)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedGoogleAccounts)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedWisaColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedDirectoryColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedSmartschoolColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedGoogleColor)));
        }
    }
}

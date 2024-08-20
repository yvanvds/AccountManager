using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.ViewModels.Dashboard
{
    class LinkedGroups : INotifyPropertyChanged, State.IStateObserver
    {
        State.Linked.LinkedState state;
        public IAsyncCommand SyncCommand { get; private set; }

        public LinkedGroups()
        {
            state = State.App.Instance.Linked;
            state.AddObserver(this);

            SyncCommand = new RelayAsyncCommand(Sync);
        }

        private async Task Sync()
        {
            Indicator = true;
            await State.App.Instance.Linked.Groups.ReLink();
            Indicator = false;
        }

        ~LinkedGroups()
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

        public int TotalWisaGroups => state.Groups.TotalWisaGroups;
        public int TotalSmartschoolGroups => state.Groups.TotalSmartschoolGroups;
        public int UnlinkedWisaGroups => state.Groups.UnlinkedWisaGroups;
        public int UnlinkedSmartschoolGroups => state.Groups.UnlinkedSmartschoolGroups;
        public int LinkedWisaGroups => state.Groups.LinkedWisaGroups;
        public int LinkedSmartschoolGroups => state.Groups.LinkedSmartschoolGroups;
        public string UnlinkedSmartschoolColor => state.Groups.UnlinkedSmartschoolGroups == 0 ? "DarkGreen" : "DarkRed";
        public string UnlinkedWisaColor => state.Groups.UnlinkedWisaGroups == 0 ? "DarkGreen" : "DarkRed";


        public void OnStateChanges()
        {
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalWisaGroups)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(TotalSmartschoolGroups)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedWisaGroups)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedSmartschoolGroups)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedWisaGroups)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LinkedSmartschoolGroups)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedWisaColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UnlinkedSmartschoolColor)));
        }
    }

    
}

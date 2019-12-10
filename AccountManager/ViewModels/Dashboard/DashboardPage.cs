using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Media;

namespace AccountManager.ViewModels.Dashboard
{
    class DashboardPage : INotifyPropertyChanged, State.IStateObserver
    {
        State.Wisa.WisaState Wisa;
        State.Google.GoogleState Google;
        State.AD.ADState AD;
        State.Smartschool.SmartschoolState Smartschool;

        public IAsyncCommand SyncWisaGroupsCommand { get; private set; }
        public IAsyncCommand SyncDirectoryGroupsCommand { get; private set; }
        public IAsyncCommand SyncWisaAccountsCommand { get; private set; }
        public IAsyncCommand SyncDirectoryAccountsCommand { get; private set; }
        public IAsyncCommand SyncSmartschoolAccountsCommand { get; private set; }
        public IAsyncCommand SyncGoogleAccountsCommand { get; private set; }


        public DashboardPage()
        {
            Wisa = State.App.Instance.Wisa;
            Google = State.App.Instance.Google;
            AD = State.App.Instance.AD;
            Smartschool = State.App.Instance.Smartschool;

            Wisa.AddObserver(this);
            Google.AddObserver(this);
            AD.AddObserver(this);
            Smartschool.AddObserver(this);

            SyncWisaGroupsCommand = new RelayAsyncCommand(SyncWisaGroups);
            SyncDirectoryGroupsCommand = new RelayAsyncCommand(SyncDirectoryGroups);

        }

        private Task SyncDirectoryGroups()
        {
            throw new NotImplementedException();
        }

        private async Task SyncWisaGroups()
        {
            IndicatorWisaGroup = true;
            Wisa.Connect();
            await Wisa.Groups.Load();
            IndicatorWisaGroup = false;
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        public DateTime WisaGroupDate { get => Wisa.Groups.LastSync; }
        public string WisaGroupColor { get => GetColor(Wisa.Groups.LastSync); }

        bool indicatorWisaGroup = false;
        public bool IndicatorWisaGroup
        {
            get => indicatorWisaGroup;
            set
            {
                indicatorWisaGroup = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(IndicatorWisaGroup)));
            }
        }

        public void OnStateChanges()
        {
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaGroupDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaGroupColor)));
        }

        private string GetColor(DateTime date)
        {
            int diff = (DateTime.Now - date).Days;
            if (diff == 0) return "DarkGreen";
            if (diff == 1) return "Orange";
            return "DarkRed";
        }
    }
}

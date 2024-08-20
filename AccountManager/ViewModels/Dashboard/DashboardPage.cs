using System;
using System.ComponentModel;
using System.Threading.Tasks;

namespace AccountManager.ViewModels.Dashboard
{
    class DashboardPage : INotifyPropertyChanged, State.IStateObserver
    {
        State.Wisa.WisaState Wisa;
        State.Smartschool.SmartschoolState Smartschool;
        State.Azure.AzureState Azure;

        public IAsyncCommand SyncWisaGroupsCommand { get; private set; }
        public IAsyncCommand SyncADGroupsCommand { get; private set; }
        public IAsyncCommand SyncWisaAccountsCommand { get; private set; }
        public IAsyncCommand SyncADAccountsCommand { get; private set; }
        public IAsyncCommand SyncSmartschoolAccountsCommand { get; private set; }
        public IAsyncCommand SyncAzureGroupsCommand { get; private set; }
        public IAsyncCommand SyncAzureAccountsCommand { get; private set; }

        public DashboardPage()
        {
            Wisa = State.App.Instance.Wisa;
            Smartschool = State.App.Instance.Smartschool;
            Azure = State.App.Instance.Azure;

            Wisa.AddObserver(this);
            Smartschool.AddObserver(this);
            Azure.AddObserver(this);

            SyncWisaGroupsCommand = new RelayAsyncCommand(SyncWisaGroups);
            SyncWisaAccountsCommand = new RelayAsyncCommand(SyncWisaAccounts);
            SyncSmartschoolAccountsCommand = new RelayAsyncCommand(SyncSmartschoolAccounts);
            SyncAzureGroupsCommand = new RelayAsyncCommand(SyncAzureGroups);
            SyncAzureAccountsCommand = new RelayAsyncCommand(SyncAzureAccounts);
        }

        private async Task SyncAzureAccounts()
        {
            IndicatorAzureAccount = true;
            await Azure.Accounts.Load().ConfigureAwait(false);
            IndicatorAzureAccount = false;
        }

        private async Task SyncAzureGroups()
        {
            IndicatorAzureGroups = true;
            await Azure.Groups.Load().ConfigureAwait(false);
            IndicatorAzureGroups = false;
        }

        private async Task SyncSmartschoolAccounts()
        {
            IndicatorSmartschoolAccount = true;
            Smartschool.Connect();
            await Smartschool.Groups.Load().ConfigureAwait(false);
            IndicatorSmartschoolAccount = false;
        }

        private async Task SyncWisaAccounts()
        {
            IndicatorWisaAccount = true;
            Wisa.Connect();
            await Wisa.Students.Load().ConfigureAwait(false);
            await Wisa.Staff.Load().ConfigureAwait(false);
            IndicatorWisaAccount = false;
        }

        private async Task SyncWisaGroups()
        {
            IndicatorWisaGroup = true;
            Wisa.Connect();
            await Wisa.Groups.Load().ConfigureAwait(false);
            IndicatorWisaGroup = false;
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        #region WisaProps
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

        public DateTime WisaAccountDate { get => Wisa.Students.LastSync; }
        public string WisaAccountColor { get => GetColor(Wisa.Students.LastSync); }

        bool indicatorWisaAccount = false;
        public bool IndicatorWisaAccount
        {
            get => indicatorWisaAccount;
            set
            {
                indicatorWisaAccount = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(IndicatorWisaAccount)));
            }
        }
        #endregion

        

        #region AzureProps
        public DateTime AzureAccountDate { get => Azure.Accounts.LastSync; }
        public string AzureAccountColor { get => GetColor(Azure.Accounts.LastSync); }

        public DateTime AzureGroupDate { get => Azure.Groups.LastSync; }
        public string AzureGroupColor { get => GetColor(Azure.Groups.LastSync); }

        bool indicatorAzureAccount = false;
        public bool IndicatorAzureAccount
        {
            get => indicatorAzureAccount;
            set
            {
                indicatorAzureAccount = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(IndicatorAzureAccount)));
            }
        }

        bool indicatorAzureGroups = false;
        public bool IndicatorAzureGroups
        {
            get => indicatorAzureGroups;
            set
            {
                indicatorAzureGroups = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(IndicatorAzureGroups)));
            }
        }
        #endregion

        #region SmartschoolProps
        public DateTime SmartschoolAccountDate { get => Smartschool.Groups.LastSync; }
        public string SmartschoolAccountColor { get => GetColor(Smartschool.Groups.LastSync); }

        bool indicatorSmartschoolAccount = false;
        public bool IndicatorSmartschoolAccount
        {
            get => indicatorSmartschoolAccount;
            set
            {
                indicatorSmartschoolAccount = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(IndicatorSmartschoolAccount)));
            }
        }
        #endregion


        public void OnStateChanges()
        {
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaGroupDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaGroupColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaAccountDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaAccountColor)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(SmartschoolAccountDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(SmartschoolAccountColor)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(AzureAccountDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(AzureAccountColor)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(AzureGroupDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(AzureGroupColor)));
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

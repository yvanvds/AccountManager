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
        //State.Google.GoogleState Google;
        State.AD.ADState AD;
        State.Smartschool.SmartschoolState Smartschool;
        State.Azure.AzureState Azure;

        public IAsyncCommand SyncWisaGroupsCommand { get; private set; }
        public IAsyncCommand SyncADGroupsCommand { get; private set; }
        public IAsyncCommand SyncWisaAccountsCommand { get; private set; }
        public IAsyncCommand SyncADAccountsCommand { get; private set; }
        public IAsyncCommand SyncSmartschoolAccountsCommand { get; private set; }
        //public IAsyncCommand SyncGoogleAccountsCommand { get; private set; }
        public IAsyncCommand SyncAzureAccountsCommand { get; private set; }

        public DashboardPage()
        {
            Wisa = State.App.Instance.Wisa;
            //Google = State.App.Instance.Google;
            AD = State.App.Instance.AD;
            Smartschool = State.App.Instance.Smartschool;
            Azure = State.App.Instance.Azure;

            Wisa.AddObserver(this);
            //Google.AddObserver(this);
            AD.AddObserver(this);
            Smartschool.AddObserver(this);
            Azure.AddObserver(this);

            SyncWisaGroupsCommand = new RelayAsyncCommand(SyncWisaGroups);
            SyncADGroupsCommand = new RelayAsyncCommand(SyncDirectoryGroups);
            SyncWisaAccountsCommand = new RelayAsyncCommand(SyncWisaAccounts);
            SyncADAccountsCommand = new RelayAsyncCommand(SyncDirectoryAccounts);
            SyncSmartschoolAccountsCommand = new RelayAsyncCommand(SyncSmartschoolAccounts);
            //SyncGoogleAccountsCommand = new RelayAsyncCommand(SyncGoogleAccounts);
            SyncAzureAccountsCommand = new RelayAsyncCommand(SyncAzureAccounts);
        }

        private async Task SyncAzureAccounts()
        {
            IndicatorAzureAccount = true;
            Azure.Connect();
            await Azure.LoadContent().ConfigureAwait(false);
            IndicatorAzureAccount = false;
        }

        //private async Task SyncGoogleAccounts()
        //{
        //    IndicatorGoogleAccount = true;
        //    //Google.Connect();
        //    //await Google.Accounts.Load().ConfigureAwait(false);
        //    IndicatorGoogleAccount = false;
        //}

        private async Task SyncSmartschoolAccounts()
        {
            IndicatorSmartschoolAccount = true;
            Smartschool.Connect();
            await Smartschool.Groups.Load().ConfigureAwait(false);
            IndicatorSmartschoolAccount = false;
        }

        private async Task SyncDirectoryAccounts()
        {
            IndicatorADAccount = true;
            bool result = await AD.Connect().ConfigureAwait(false);
            if (result) await AD.Accounts.Load().ConfigureAwait(false);
            IndicatorADAccount = false;
        }

        private async Task SyncWisaAccounts()
        {
            IndicatorWisaAccount = true;
            Wisa.Connect();
            await Wisa.Students.Load().ConfigureAwait(false);
            await Wisa.Staff.Load().ConfigureAwait(false);
            IndicatorWisaAccount = false;
        }

        private async Task SyncDirectoryGroups()
        {
            IndicatorADGroup = true;
            bool result = await AD.Connect().ConfigureAwait(false);
            if (result) await AD.Groups.Load().ConfigureAwait(false);
            IndicatorADGroup = false;
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

        #region ADProps
        public DateTime ADGroupDate { get => AD.Groups.LastSync; }
        public string ADGroupColor { get => GetColor(AD.Groups.LastSync); }

        bool indicatorADGroup = false;
        public bool IndicatorADGroup
        {
            get => indicatorADGroup;
            set
            {
                indicatorADGroup = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(IndicatorADGroup)));
            }
        }

        public DateTime ADAccountDate { get => AD.Accounts.LastSync; }
        public string ADAccountColor { get => GetColor(AD.Accounts.LastSync); }

        bool indicatorADAccount = false;
        public bool IndicatorADAccount
        {
            get => indicatorADAccount;
            set
            {
                indicatorADAccount = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(IndicatorADAccount)));
            }
        }
        #endregion

        #region AzureProps
        public DateTime AzureAccountDate { get => Azure.Accounts.LastSync; }
        public string AzureAccountColor { get => GetColor(Azure.Accounts.LastSync); }

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

        //#region GoogleProps
        //public DateTime GoogleAccountDate { get => Google.Accounts.LastSync; }
        //public string GoogleAccountColor { get => GetColor(Google.Accounts.LastSync); }

        //bool indicatorGoogleAccount = false;
        //public bool IndicatorGoogleAccount
        //{
        //    get => indicatorGoogleAccount;
        //    set
        //    {
        //        indicatorGoogleAccount = value;
        //        PropertyChanged(this, new PropertyChangedEventArgs(nameof(IndicatorGoogleAccount)));
        //    }
        //}
        //#endregion

        public void OnStateChanges()
        {
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaGroupDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaGroupColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaAccountDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WisaAccountColor)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(ADGroupDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(ADGroupColor)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(ADAccountDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(ADAccountColor)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(SmartschoolAccountDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(SmartschoolAccountColor)));

            //PropertyChanged(this, new PropertyChangedEventArgs(nameof(GoogleAccountDate)));
            //PropertyChanged(this, new PropertyChangedEventArgs(nameof(GoogleAccountColor)));

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(AzureAccountDate)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(AzureAccountColor)));
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

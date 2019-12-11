using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Input;

namespace AccountManager.ViewModels.Accounts
{
    class GoogleAccounts : INotifyPropertyChanged, State.IStateObserver
    {
        State.Google.GoogleState state;

        public IAsyncCommand ReloadCommand { get; private set; }
        public ICommand ClearFilterCommand { get; private set; }

        public GoogleAccounts()
        {
            state = State.App.Instance.Google;
            state.AddObserver(this);

            ReloadCommand = new RelayAsyncCommand(ReloadAccounts);
            ClearFilterCommand = new RelayCommand(ClearFilter);

            updateSelection();
        }
        ~GoogleAccounts()
        {
            state.RemoveObserver(this);
        }

        #region Commands
        private void ClearFilter()
        {
            FilterText = "";
        }

        private async Task ReloadAccounts()
        {
            Indicator = true;
            await state.LoadContent();
            updateSelection();
            Indicator = false;
        }
        #endregion

        private void updateSelection()
        {
            accounts.Clear();
            var selectedFilter = filterText.Length == 0 ? "None" : SelectedFilter;

            if (AccountApi.Google.AccountManager.All == null)
            {
                return;
            }
            foreach (var account in AccountApi.Google.AccountManager.All.Values.OrderBy(d => d.FamilyName))
            {
                switch (selectedFilter)
                {
                    case "None":
                        if (account.IsStaff && IncludeStaff || !account.IsStaff && IncludeOther) accounts.Add(account);
                        break;
                    case "Naam":
                        if (account.FamilyName.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase))
                            if (account.IsStaff && IncludeStaff || !account.IsStaff && IncludeOther)
                                accounts.Add(account);
                        break;
                    case "Voornaam":
                        if (account.GivenName.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase))
                            if (account.IsStaff && IncludeStaff || !account.IsStaff && IncludeOther)
                                accounts.Add(account);
                        break;
                    case "Gebruikersnaam":
                        if (account.UID.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase))
                            if (account.IsStaff && IncludeStaff || !account.IsStaff && IncludeOther)
                                accounts.Add(account);
                        break;
                }
            }

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(Accounts)));
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        #region Accounts
        private ObservableCollection<AccountApi.Google.Account> accounts = new ObservableCollection<AccountApi.Google.Account>();
        public ObservableCollection<AccountApi.Google.Account> Accounts => accounts;

        public string SelectedAccountTitle => selectedAccount == null ? "Geen Actieve Selectie" : selectedAccount.FullName;

        AccountApi.Google.Account selectedAccount = null;
        public AccountApi.Google.Account SelectedAccount
        {
            get => selectedAccount;
            set
            {
                selectedAccount = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SelectedAccount)));
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SelectedAccountTitle)));
            }
        }
        #endregion

        #region Filter
        private string filterText = string.Empty;
        public string FilterText
        {
            get => filterText;
            set
            {
                filterText = value.Trim();
                updateSelection();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(FilterText)));
            }
        }

        private bool includeStaff = true;
        public bool IncludeStaff
        {
            get => includeStaff;
            set
            {
                includeStaff = value;
                updateSelection();
            }
        }

        private bool includeOther = true;
        public bool IncludeOther
        {
            get => includeOther;
            set
            {
                includeOther = value;
                updateSelection();
            }
        }

        private List<string> filterTypes = new List<string> { "Naam", "Voornaam", "Gebruikersnaam" };
        public List<string> FilterTypes => filterTypes;

        private string selectedFilter = "Naam";
        public string SelectedFilter
        {
            get => selectedFilter;
            set
            {
                selectedFilter = value;
                updateSelection();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SelectedFilter)));
            }
        }
        #endregion

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

        public void OnStateChanges()
        {
            updateSelection();
        }
    }
}

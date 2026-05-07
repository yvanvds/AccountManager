using AccountApi;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Input;

namespace AccountManager.ViewModels.Passwords
{
    class StaffPasswords : INotifyPropertyChanged, State.IStateObserver
    {
        State.Smartschool.SmartschoolState state;
        public ICommand ClearFilterCommand { get; private set; }
        public ICommand NewAccountCommand { get; private set; }

        List<IAccount> allAccounts = new List<IAccount>();

        public StaffPasswords()
        {
            state = State.App.Instance.Smartschool;
            state.AddObserver(this);
            ClearFilterCommand = new RelayCommand(ClearFilter);
            NewAccountCommand = new RelayCommand(NewAccount);

            (state.Groups.Root.Find("Personeel") as AccountApi.Smartschool.Group).GetAllAccounts(allAccounts);

            updateSelection();
        }

        private void NewAccount()
        {
            SelectedAccount = null;
            
        }

        ~StaffPasswords()
        {
            state.RemoveObserver(this);
        }

        private void ClearFilter()
        {
            FilterText = "";
        }

        private void updateSelection()
        {
            var accounts = new List<IAccount>();

            var selectedFilter = filterText.Length == 0 ? "None" : SelectedFilter;

            foreach (var account in allAccounts)
            {
                switch(selectedFilter)
                {
                    case "None": accounts.Add(account); break;
                    case "Voornaam": if (account.GivenName.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Naam": if (account.SurName.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Gebruikersnaam": if (account.UID.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                }
            }

            Accounts = accounts;
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        #region Accounts
        private List<IAccount> accounts = new List<IAccount>();
        public List<IAccount> Accounts
        {
            get => accounts;
            set
            {
                accounts = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Accounts)));
            }
        }

        public string SelectedAccountTitle => selectedAccount == null ? "Geen Actieve Selectie" : selectedAccount.GivenName + " " + selectedAccount.SurName;

        AccountApi.Smartschool.Account selectedAccount = null;
        public AccountApi.Smartschool.Account SelectedAccount
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

        public void OnStateChanges()
        {
            updateSelection();
        }


    }
}

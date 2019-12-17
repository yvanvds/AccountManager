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
        State.AD.ADState state;
        public ICommand ClearFilterCommand { get; private set; }
        public ICommand NewAccountCommand { get; private set; }

        public StaffPasswords()
        {
            state = State.App.Instance.AD;
            state.AddObserver(this);
            ClearFilterCommand = new RelayCommand(ClearFilter);
            NewAccountCommand = new RelayCommand(NewAccount);

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
            var accounts = new List<AccountApi.Directory.Account>();

            var selectedFilter = filterText.Length == 0 ? "None" : SelectedFilter;

            foreach (var account in AccountApi.Directory.AccountManager.Staff)
            {
                switch(selectedFilter)
                {
                    case "None": accounts.Add(account); break;
                    case "Voornaam": if (account.FirstName.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Naam": if (account.LastName.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Gebruikersnaam": if (account.UID.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                }
            }

            Accounts = accounts;
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        #region Accounts
        private List<AccountApi.Directory.Account> accounts = new List<AccountApi.Directory.Account>();
        public List<AccountApi.Directory.Account> Accounts
        {
            get => accounts;
            set
            {
                accounts = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Accounts)));
            }
        }

        public string SelectedAccountTitle => selectedAccount == null ? "Geen Actieve Selectie" : selectedAccount.FullName;

        AccountApi.Directory.Account selectedAccount = null;
        public AccountApi.Directory.Account SelectedAccount
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

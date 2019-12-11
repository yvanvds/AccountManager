using AccountManager.Views.Accounts;
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
    class ADAccounts : INotifyPropertyChanged, State.IStateObserver
    {
        State.AD.ADState state;

        public IAsyncCommand ReloadCommand { get; private set; }
        public ICommand SetTargetCommand { get; private set; }
        public ICommand ClearFilterCommand { get; private set; }

        public ADAccounts()
        {
            state = State.App.Instance.AD;
            state.AddObserver(this);

            ReloadCommand = new RelayAsyncCommand(ReloadAccounts);
            SetTargetCommand = new RelayCommand<string>(SetTarget);
            ClearFilterCommand = new RelayCommand(ClearFilter);

            updateSelection();
        }
        ~ADAccounts()
        {
            state.RemoveObserver(this);
        }

        #region Commands
        private void ClearFilter()
        {
            FilterText = "";
        }

        private void SetTarget(string obj)
        {
            Target = obj;
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

            var list = Target == "Personeel" ? AccountApi.Directory.AccountManager.Staff : AccountApi.Directory.AccountManager.Students;

            foreach (var account in list)
            {
                switch (selectedFilter)
                {
                    case "None": accounts.Add(account); break;
                    case "Voornaam": if (account.FirstName.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Naam": if (account.LastName.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Gebruikersnaam": if (account.UID.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                }
            }

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(Accounts)));
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        #region Accounts
        private ObservableCollection<AccountApi.Directory.Account> accounts = new ObservableCollection<AccountApi.Directory.Account>();
        public ObservableCollection<AccountApi.Directory.Account> Accounts => accounts;

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
        public string FilterText {
            get => filterText;
            set
            {
                filterText = value.Trim();
                updateSelection();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(FilterText)));
            }
        }

        private string target = "Leerlingen";
        public string Target
        {
            get => target;
            set
            {
                target = value;
                updateSelection();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Target)));
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

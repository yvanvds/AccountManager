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
    internal class AzureAccounts : INotifyPropertyChanged, State.IStateObserver
    {
        State.Azure.AzureState state;

        public IAsyncCommand ReloadCommand { get; private set; }
        public ICommand SetTargetCommand { get; private set; }
        public ICommand ClearFilterCommand { get; private set; }

        public AzureAccounts()
        {
            state = State.App.Instance.Azure;
            state.AddObserver(this);

            //ReloadCommand = new RelayAsyncCommand(ReloadAccounts);
            //SetTargetCommand = new RelayCommand<string>(SetTarget);
            //ClearFilterCommand = new RelayCommand(ClearFilter);

            updateSelection();
        }

        ~AzureAccounts()
        {
            state.RemoveObserver(this);
        }

        private void updateSelection()
        {
            accounts.Clear();
            var selectedFilter = filterText.Length == 0 ? "None" : SelectedFilter;

            var list = AccountApi.Azure.UserManager.Instance.Users;


            foreach (var account in list)
            {
                switch (selectedFilter)
                {
                    case "None": accounts.Add(account); break;
                    case "Voornaam": if (account.GivenName.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Naam": if (account.Surname.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Klas": if (account.Department.Contains(filterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                }
            }

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(Accounts)));
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        #region Accounts
        private ObservableCollection<Microsoft.Graph.User> accounts = new ObservableCollection<Microsoft.Graph.User>();
        public ObservableCollection<Microsoft.Graph.User> Accounts => accounts;

        public string SelectedAccountTitle => selectedAccount == null ? "Geen Actieve Selectie" : selectedAccount.DisplayName;

        Microsoft.Graph.User selectedAccount = null;
        public Microsoft.Graph.User SelectedAccount
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
                filterText = value;
                updateSelection();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(FilterText)));
            }
        }

        private List<string> filterTypes = new List<string> { "Naam", "Voornaam", "Klas" };
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

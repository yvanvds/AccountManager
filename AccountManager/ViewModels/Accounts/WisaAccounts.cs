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
    class WisaAccounts : INotifyPropertyChanged, State.IStateObserver
    {
        State.Wisa.WisaState state;

        public IAsyncCommand ReloadCommand { get; private set; }
        public ICommand ClearFilterCommand { get; private set; }

        public WisaAccounts()
        {
            state = State.App.Instance.Wisa;
            state.AddObserver(this);

            ReloadCommand = new RelayAsyncCommand(ReloadAccounts);
            ClearFilterCommand = new RelayCommand(ClearFilter);

            updateSelection();
        }
        ~WisaAccounts()
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

            foreach (var account in AccountApi.Wisa.Students.All)
            {
                switch (selectedFilter)
                {
                    case "None": accounts.Add(account); break;
                    case "Naam": if (account.Name.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Voornaam": if (account.FirstName.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Klas": if (account.ClassName.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                }
            }

            PropertyChanged(this, new PropertyChangedEventArgs(nameof(Accounts)));
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        #region Accounts
        private ObservableCollection<AccountApi.Wisa.Student> accounts = new ObservableCollection<AccountApi.Wisa.Student>();
        public ObservableCollection<AccountApi.Wisa.Student> Accounts => accounts;

        public string SelectedAccountTitle => selectedAccount == null ? "Geen Actieve Selectie" : selectedAccount.FullName;

        AccountApi.Wisa.Student selectedAccount = null;
        public AccountApi.Wisa.Student SelectedAccount
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

        public bool WorkDateNow
        {
            get => state.WorkDateIsNow.Value;
            set
            {
                state.WorkDateIsNow.Value = value;
            }
        }

        public DateTime WorkDate
        {
            get => state.WorkDate.Value;
            set
            {
                state.WorkDate.Value = value;
            }
        }



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
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WorkDateNow)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(WorkDate)));
        }
    }
}

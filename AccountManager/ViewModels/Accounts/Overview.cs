using AccountManager.Action.Account;
using AccountManager.State;
using AccountManager.State.Linked;
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
    class Overview : INotifyPropertyChanged, IStateObserver
    {
        State.Linked.LinkedState state;

        public ICommand ClearFilterCommand { get; private set; }
        public IAsyncCommand<AccountAction> DoAccountActionCommand { get; private set; }

        #region constructor
        public Overview()
        {
            state = State.App.Instance.Linked;
            state.AddObserver(this);

            ClearFilterCommand = new RelayCommand(clearFilter);
            DoAccountActionCommand = new RelayAsyncCommand<AccountAction>(doAccountAction);

            updateList();
        }

        

        ~Overview()
        {
            state.RemoveObserver(this);
        }
        #endregion

        private void updateList()
        {
            // don't reuse and clear the Accounts list here. When updating, the selected account might be still in use and will crash this method
            var accounts = new List<LinkedAccount>();
            var selectedFilter = FilterText.Length == 0 ? "None" : SelectedFilter;

            List<LinkedAccount> list = State.App.Instance.Linked.Accounts.List.Values.ToList();
            list.Sort((a, b) => a.Name.CompareTo(b.Name));

            foreach(var account in list)
            {
                if (ShowOnlyProblemAccounts && account.OK) continue;
                switch (selectedFilter)
                {
                    case "None": accounts.Add(account); break;
                    case "Naam": if (account.Name.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                    case "Klas": if (account.ClassGroup.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                }
            }
            Accounts = accounts;
        }

        private void evaluateAccount()
        {
            if (SelectedAccount == null)
            {
                SelectedAccountHeader = "Selecteer een Account";
                Actions.Clear();
            } else
            {
                SelectedAccountHeader = SelectedAccount.Name + " - Mogelijke Acties";
                Actions.Clear();
                foreach(var action in SelectedAccount.Actions)
                {
                    Actions.Add(action);
                }

                if (Actions.Count == 0)
                {
                    Actions.Add(new NoActionNeeded());
                }
            }
        }

        private async Task doAccountAction(AccountAction action)
        {
            ///var action = obj as AccountAction;
            action.Indicator = true;

            if (action.CanBeAppliedToAll && action.ApplyToAll.Value)
            {
                foreach(var account in Accounts)
                {
                    var sameAction = account.GetSameAction(action);
                    if (sameAction != null)
                    {
                        //Account original = State.App.Instance.Linked.Accounts.List[account.UID];
                        await sameAction.Apply(account, StudentDeleteDate).ConfigureAwait(false);
                    }
                }
                MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Other, "Alle Acties werden uitgevoerd.");
            } else
            {
                //Account original = State.App.Instance.Linked.Accounts.List[SelectedAccount.UID];
                await action.Apply(SelectedAccount, StudentDeleteDate).ConfigureAwait(false);
            }
            await State.App.Instance.Linked.Accounts.ReLink().ConfigureAwait(false);
            updateList();
            action.Indicator = false;
        }

        private void clearFilter()
        {
            FilterText = string.Empty;
        }

        #region properties
        bool showOnlyProblemAccounts = false;
        public bool ShowOnlyProblemAccounts
        {
            get => showOnlyProblemAccounts;
            set
            {
                showOnlyProblemAccounts = value;
                updateList();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(ShowOnlyProblemAccounts)));
            }
        }

        List<State.Linked.LinkedAccount> accounts = new List<State.Linked.LinkedAccount>();
        public List<State.Linked.LinkedAccount> Accounts
        {
            get => accounts;
            set
            {
                accounts = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Accounts)));
            }
        }

        State.Linked.LinkedAccount selectedAccount = null;
        public State.Linked.LinkedAccount SelectedAccount
        {
            get => selectedAccount;
            set
            {
                selectedAccount = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SelectedAccount)));
                evaluateAccount();
            }
        }

        string selectedAccountHeader = string.Empty;
        public string SelectedAccountHeader
        {
            get => selectedAccountHeader;
            set
            {
                selectedAccountHeader = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SelectedAccountHeader)));
            }
        }

        public DateTime StudentDeleteDate { get; set; } = DateTime.Now;

        public ObservableCollection<AccountAction> Actions { get; set; } = new ObservableCollection<AccountAction>();

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

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };
        #endregion

        #region Filter
        private string filterText = string.Empty;
        public string FilterText
        {
            get => filterText;
            set
            {
                filterText = value.Trim();
                updateList();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(FilterText)));
            }
        }

        private List<string> filterTypes = new List<string> { "Naam", "Klas" };
        public List<string> FilterTypes => filterTypes;

        private string selectedFilter = "Naam";
        public string SelectedFilter
        {
            get => selectedFilter;
            set
            {
                selectedFilter = value;
                updateList();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SelectedFilter)));
            }
        }
        #endregion

        public void OnStateChanges()
        {

        }

        
    }
}

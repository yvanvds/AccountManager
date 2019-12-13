using AccountManager.Action.StaffAccount;
using AccountManager.State;
using AccountManager.State.Linked;
using MaterialDesignThemes.Wpf;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Input;

namespace AccountManager.ViewModels.Accounts
{
    class StaffOverview : INotifyPropertyChanged
    {
        LinkedState state;

        public ICommand ClearFilterCommand { get; private set; }
        public IAsyncCommand<AccountAction> DoAccountActionCommand { get; private set; }
        public IAsyncCommand<AccountAction> ViewDetailsActionCommand { get; private set; }

        #region constructor
        public StaffOverview()
        {
            state = State.App.Instance.Linked;

            ClearFilterCommand = new RelayCommand(clearFilter);
            DoAccountActionCommand = new RelayAsyncCommand<AccountAction>(doAccountAction);
            ViewDetailsActionCommand = new RelayAsyncCommand<AccountAction>(viewDetailsAction);
            updateList();
        }
        #endregion

        private void updateList()
        {
            // don't reuse and clear the Accounts list here. When updating, the selected account might be still in use and will crash this method
            var accounts = new List<LinkedStaffMember>();
            var selectedFilter = FilterText.Length == 0 ? "None" : SelectedFilter;

            List<LinkedStaffMember> list = State.App.Instance.Linked.Staff.List.Values.ToList();
            list.Sort((a, b) => a.Name.CompareTo(b.Name));

            foreach (var account in list)
            {
                if (ShowOnlyProblemAccounts && account.OK) continue;
                switch (selectedFilter)
                {
                    case "None": accounts.Add(account); break;
                    case "Naam": if (account.Name.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase)) accounts.Add(account); break;
                }
            }
            Accounts = accounts;
            if (SelectedAccount != null) foreach (var account in Accounts)
            {
                if (account.UID == SelectedAccount.UID)
                {
                    SelectedAccount = account;
                    break;
                }
            }
        }

        private void evaluateAccount()
        {
            var actions = new List<AccountAction>();
            if (SelectedAccount == null)
            {
                SelectedAccountHeader = "Selecteer een Account";
            }
            else
            {
                SelectedAccountHeader = SelectedAccount.Name + " - Mogelijke Acties";
                foreach (var action in SelectedAccount.Actions)
                {
                    actions.Add(action);
                }

                if (actions.Count == 0)
                {
                    actions.Add(new NoActionNeeded());
                }
                Actions = actions;
            }
        }

        private async Task doAccountAction(AccountAction action)
        {
            ///var action = obj as AccountAction;
            action.Indicator = true;

            if (action.CanBeAppliedToAll && action.ApplyToAll.Value)
            {
                foreach (var account in Accounts)
                {
                    var sameAction = account.GetSameAction(action);
                    if (sameAction != null)
                    {
                        await sameAction.Apply(account).ConfigureAwait(false);
                    }
                }
                MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Other, "Alle Acties werden uitgevoerd.");
            }
            else
            {
                await action.Apply(SelectedAccount).ConfigureAwait(false);
            }
            await State.App.Instance.Linked.Accounts.ReLink().ConfigureAwait(false);
            updateList();
            action.Indicator = false;
        }

        private async Task viewDetailsAction(AccountAction action)
        {
            if (action.CanShowDetails)
            {
                var document = action.GetDetails(SelectedAccount);
                var dialog = new Views.Dialogs.ShowActionDetails(document);
                await DialogHost.Show(dialog, "RootDialog").ConfigureAwait(false);
            }
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

        List<State.Linked.LinkedStaffMember> accounts = new List<State.Linked.LinkedStaffMember>();
        public List<State.Linked.LinkedStaffMember> Accounts
        {
            get => accounts;
            set
            {
                accounts = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Accounts)));
            }
        }

        State.Linked.LinkedStaffMember selectedAccount = null;
        public State.Linked.LinkedStaffMember SelectedAccount
        {
            get => selectedAccount;
            set
            {
                if (value != null)
                {
                    selectedAccount = value;
                    PropertyChanged(this, new PropertyChangedEventArgs(nameof(SelectedAccount)));
                    evaluateAccount();
                }

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

        private List<AccountAction> actions;
        public List<AccountAction> Actions
        {
            get => actions;
            set
            {
                actions = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Actions)));
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

        private List<string> filterTypes = new List<string> { "Naam" };
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

    }
}

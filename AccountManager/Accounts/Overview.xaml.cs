using AccountManager.Action;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Accounts
{
    /// <summary>
    /// Interaction logic for Overview.xaml
    /// </summary>
    public partial class Overview : UserControl
    {
        Prop<LinkedAccount> SelectedAccount { get; set; } = new Prop<LinkedAccount>() { Value = null };
        public ObservableCollection<AccountAction> Actions = new ObservableCollection<AccountAction>();
        bool OnlyShowProblemAccounts { get; set; } = false;
        public Prop<string> AccountCount { get; set; } = new Prop<string>() { Value = "" };

        public Prop<bool> Working { get; set; } = new Prop<bool>() { Value = false };

        enum FilterType
        {
            Name,
            Class,
            None,
        }

        FilterType filterType { get; set; } = FilterType.Name;
        private string Filter { get; set; } = string.Empty;

        public Overview()
        {
            InitializeComponent();
            
            DataContext = this;
        }

        private async Task CreateCollection()
        {
            var Accounts = new List<LinkedAccount>();
            Working.Value = true;
            await Task.Run(() => {
                var selectedFilter = Filter.Length == 0 ? FilterType.None : filterType;

                List<LinkedAccount> accounts = LinkedAccounts.List.Values.ToList();
                accounts.Sort((a, b) => a.Name.CompareTo(b.Name));

                foreach (var account in accounts)
                {
                    if (OnlyShowProblemAccounts && account.AccountOK) continue;
                    switch (selectedFilter)
                    {
                        case FilterType.None: Accounts.Add(account); break;
                        case FilterType.Name: if (account.Name.Contains(Filter, StringComparison.CurrentCultureIgnoreCase)) Accounts.Add(account); break;
                        case FilterType.Class: if (account.ClassGroup.Contains(Filter, StringComparison.CurrentCultureIgnoreCase)) Accounts.Add(account); break;
                    }
                }
            });
            AccountList.ItemsSource = Accounts;
            AccountCount.Value = Accounts.Count.ToString();
            Working.Value = false;
        }

        private void AccountList_SelectedCellsChanged(object sender, SelectedCellsChangedEventArgs e)
        {
            if (AccountList.SelectedItem is LinkedAccount)
            {
                SelectedAccount.Value = AccountList.SelectedItem as LinkedAccount;
                ActionsBox.Header = SelectedAccount.Value.Name + " - Mogelijke Acties";
                Actions.Clear();
                foreach (var action in SelectedAccount.Value.Actions)
                {
                    Actions.Add(action);
                }
                if (Actions.Count == 0)
                {
                    Actions.Add(new NoAccountActionNeeded());
                }
            }
            else
            {
                ActionsBox.Header = "Selecteer een Account";
                SelectedAccount.Value = null;
                Actions.Clear();
            }
            ActionsViewer.ItemsSource = Actions;
        }

        private async void FilterCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            var index = (sender as ComboBox).SelectedIndex;
            if (index == 0) filterType = FilterType.Name;
            else filterType = FilterType.Class;
            await CreateCollection();
        }

        private async void FilterText_TextChanged(object sender, TextChangedEventArgs e)
        {
            Filter = (sender as TextBox).Text.Trim();
            await CreateCollection();
        }

        private async void FilterDeleteButton_Click(object sender, RoutedEventArgs e)
        {
            Filter = string.Empty;
            FilterText.Text = string.Empty;
            await CreateCollection();
        }

        private async void ShowProblemsOnly_Checked(object sender, RoutedEventArgs e)
        {
            OnlyShowProblemAccounts = true;
            await CreateCollection();
        }

        private async void ShowProblemsOnly_Unchecked(object sender, RoutedEventArgs e)
        {
            OnlyShowProblemAccounts = false;
            await CreateCollection();
        }

        private async void UserControl_Loaded(object sender, RoutedEventArgs e)
        {
            await CreateCollection();
        }

        private async void ActionButton_Click(object sender, RoutedEventArgs e)
        {
            AccountAction action = (e.Source as Button).DataContext as AccountAction;
            await action.Apply(SelectedAccount.Value);
            await LinkedAccounts.ReLink();
            await CreateCollection();
        }
    }
}

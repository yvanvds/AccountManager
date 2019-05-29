using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Accounts
{
    enum GoogleFilterType
    {
        FamilyName,
        GivenName,
        UserID,
        None,
    }
    /// <summary>
    /// Interaction logic for GoogleAccounts.xaml
    /// </summary>
    public partial class GoogleAccounts : UserControl
    {
        public Prop<bool> ShowAccountsReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<string> AccountCount { get; set; } = new Prop<string> { Value = "0" };
        public Data Data { get => Data.Instance; }

        public ObservableCollection<GoogleApi.Account> accounts = new ObservableCollection<GoogleApi.Account>();
        public Prop<GoogleApi.Account> SelectedAccount { get; set; } = new Prop<GoogleApi.Account> { Value = null };
        public Prop<string> SelectedTitle { get; set; } = new Prop<string> { Value = "Geen actieve selectie" };

        private GoogleFilterType FilterType { get; set; } = GoogleFilterType.FamilyName;
        private string Filter { get; set; } = String.Empty;

        public bool StaffChecked { get; set; } = true;
        public bool OtherChecked { get; set; } = true;

        public GoogleAccounts()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            CreateSelection();
            AccountList.ItemsSource = accounts;
        }

        private void CreateSelection()
        {
            accounts.Clear();
            var selectedFilter = Filter.Length == 0 ? GoogleFilterType.None : FilterType;

            if (GoogleApi.AccountManager.All == null)
            {
                AccountCount.Value = "0";
                return;
            }

            foreach(var account in GoogleApi.AccountManager.All.Values.OrderBy(d => d.FamilyName))
            {
                switch(selectedFilter)
                {
                    case GoogleFilterType.None:
                        if (account.IsStaff && StaffChecked || !account.IsStaff && OtherChecked) accounts.Add(account);
                        break;
                    case GoogleFilterType.FamilyName:
                        if (account.FamilyName.Contains(Filter))
                            if (account.IsStaff && StaffChecked || !account.IsStaff && OtherChecked)
                                accounts.Add(account);
                        break;
                    case GoogleFilterType.GivenName:
                        if (account.GivenName.Contains(Filter))
                            if (account.IsStaff && StaffChecked || !account.IsStaff && OtherChecked)
                                accounts.Add(account);
                        break;
                    case GoogleFilterType.UserID:
                        if (account.UID.Contains(Filter))
                            if (account.IsStaff && StaffChecked || !account.IsStaff && OtherChecked)
                                accounts.Add(account);
                        break;
                }
            }
            AccountCount.Value = accounts.Count.ToString();
        }

        private async void ReloadAccountButton_Click(object sender, RoutedEventArgs e)
        {
            ShowAccountsReloadButtonIndicator.Value = true;
            Data.Instance.SetGoogleCredentials();
            await Data.Instance.ReloadGoogleAccounts();
            CreateSelection();
            ShowAccountsReloadButtonIndicator.Value = false;
        }

        private void AccountList_SelectedCellsChanged(object sender, SelectedCellsChangedEventArgs e)
        {
            SelectedAccount.Value = (sender as DataGrid).SelectedItem as GoogleApi.Account;
            if (SelectedAccount.Value != null)
            {
                SelectedTitle.Value = SelectedAccount.Value.FullName;
            }
            else
            {
                SelectedTitle.Value = "Geen actieve selectie";
            }
        }

        private void FilterCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            var index = (sender as ComboBox).SelectedIndex;
            if (index == 0) FilterType = GoogleFilterType.FamilyName;
            else if (index == 1) FilterType = GoogleFilterType.GivenName;
            else FilterType = GoogleFilterType.UserID;
            CreateSelection();
        }

        private void FilterText_TextChanged(object sender, TextChangedEventArgs e)
        {
            Filter = (sender as TextBox).Text.Trim();
            CreateSelection();
        }

        private void FilterDeleteButton_Click(object sender, RoutedEventArgs e)
        {
            Filter = string.Empty;
            FilterText.Text = string.Empty;
            CreateSelection();
        }

        private void StaffCheckbox_Checked(object sender, RoutedEventArgs e)
        {
            CreateSelection();
        }

        private void StaffCheckbox_Unchecked(object sender, RoutedEventArgs e)
        {
            CreateSelection();
        }

        private void OtherCheckbox_Checked(object sender, RoutedEventArgs e)
        {
            CreateSelection();
        }

        private void OtherCheckbox_Unchecked(object sender, RoutedEventArgs e)
        {
            CreateSelection();
        }
    }
}

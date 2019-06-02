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
    enum ADFilterType
    {
        Name,
        FirstName,
        UID,
        None,
    }
    /// <summary>
    /// Interaction logic for ADAccounts.xaml
    /// </summary>
    public partial class ADAccounts : UserControl
    {
        public Prop<bool> ShowGroupsReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<string> AccountCount { get; set; } = new Prop<string> { Value = "0" };
        public Data Data { get => Data.Instance; }

        public ObservableCollection<DirectoryApi.Account> accounts = new ObservableCollection<DirectoryApi.Account>();
        public Prop<DirectoryApi.Account> SelectedAccount { get; set; } = new Prop<DirectoryApi.Account> { Value = null };
        public Prop<string> SelectedTitle { get; set; } = new Prop<string> { Value = "Geen actieve selectie" };

        private ADFilterType FilterType { get; set; } = ADFilterType.Name;
        private string Filter { get; set; } = String.Empty;
        bool showStaff = false;

        public ADAccounts()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            CreateSelection();
            AccountList.ItemsSource = accounts;
        }

        private void StudentButton_Click(object sender, RoutedEventArgs e)
        {
            showStaff = false;
            CreateSelection();
        }

        private void StaffButton_Click(object sender, RoutedEventArgs e)
        {
            showStaff = true;
            CreateSelection();
        }

        private void CreateSelection()
        {
            accounts.Clear();
            var selectedFilter = Filter.Length == 0 ? ADFilterType.None : FilterType;

            var list = showStaff ? DirectoryApi.AccountManager.Staff : DirectoryApi.AccountManager.Students;

            foreach(var account in list)
            {
                switch(selectedFilter)
                {
                    case ADFilterType.None: accounts.Add(account); break;
                    case ADFilterType.FirstName: if (account.FirstName.Contains(Filter)) accounts.Add(account); break;
                    case ADFilterType.Name: if (account.LastName.Contains(Filter)) accounts.Add(account); break;
                    case ADFilterType.UID: if (account.UID.Contains(Filter)) accounts.Add(account); break;
                }
            }
            AccountCount.Value = accounts.Count.ToString();
        }

        private async void ReloadAccountButton_Click(object sender, RoutedEventArgs e)
        {
            ShowGroupsReloadButtonIndicator.Value = true;
            Data.Instance.SetADCredentials();
            await Data.Instance.ReloadADAccounts();
            //BuildAccountTree();

            ShowGroupsReloadButtonIndicator.Value = false;
        }

        private void FilterCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            var index = (sender as ComboBox).SelectedIndex;
            if (index == 0) FilterType = ADFilterType.Name;
            else if (index == 1) FilterType = ADFilterType.FirstName;
            else FilterType = ADFilterType.UID;
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

        private void AccountList_SelectedCellsChanged(object sender, SelectedCellsChangedEventArgs e)
        {
            SelectedAccount.Value = (sender as DataGrid).SelectedItem as DirectoryApi.Account;
            if (SelectedAccount.Value != null)
            {
                SelectedTitle.Value = SelectedAccount.Value.FullName;
            }
            else
            {
                SelectedTitle.Value = "Geen actieve selectie";
            }
        }
    }
}

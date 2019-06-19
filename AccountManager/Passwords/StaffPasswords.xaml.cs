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

namespace AccountManager.Passwords
{
    enum ADFilterType
    {
        Name,
        FirstName,
        UID,
        None,
    }
    /// <summary>
    /// Interaction logic for StaffPasswords.xaml
    /// </summary>
    public partial class StaffPasswords : UserControl
    {
        public Prop<string> AccountCount { get; set; } = new Prop<string> { Value = "0" };
        public Data Data { get => Data.Instance; }

        public ObservableCollection<AccountApi.Directory.Account> accounts = new ObservableCollection<AccountApi.Directory.Account>();
        public Prop<AccountApi.Directory.Account> SelectedAccount { get; set; } = new Prop<AccountApi.Directory.Account> { Value = null };
        public Prop<string> SelectedTitle { get; set; } = new Prop<string> { Value = "Geen actieve selectie" };

        private ADFilterType FilterType { get; set; } = ADFilterType.Name;
        private string Filter { get; set; } = String.Empty;

        public StaffPasswords()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            CreateSelection();
            AccountList.ItemsSource = accounts;
        }

        private void CreateSelection()
        {
            accounts.Clear();
            var selectedFilter = Filter.Length == 0 ? ADFilterType.None : FilterType;

            foreach (var account in AccountApi.Directory.AccountManager.Staff)
            {
                switch (selectedFilter)
                {
                    case ADFilterType.None: accounts.Add(account); break;
                    case ADFilterType.FirstName: if (account.FirstName.Contains(Filter)) accounts.Add(account); break;
                    case ADFilterType.Name: if (account.LastName.Contains(Filter)) accounts.Add(account); break;
                    case ADFilterType.UID: if (account.UID.Contains(Filter)) accounts.Add(account); break;
                }
            }
            AccountCount.Value = accounts.Count.ToString();
        }

        private void AccountList_SelectedCellsChanged(object sender, SelectedCellsChangedEventArgs e)
        {

        }

        private void FilterText_TextChanged(object sender, TextChangedEventArgs e)
        {

        }

        private void AddAccountButton_Click(object sender, RoutedEventArgs e)
        {

        }

        private void FilterCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {

        }
    }
}

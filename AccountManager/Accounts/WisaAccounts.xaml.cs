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
using WisaApi;
using static Utils.ObservableProperties;

namespace AccountManager.Accounts
{
    enum FilterType
    {
        Name,
        FirstName,
        ClassGroup,
        None,
    }
    /// <summary>
    /// Interaction logic for WisaAccounts.xaml
    /// </summary>
    public partial class WisaAccounts : UserControl
    {
        public Prop<bool> ShowAccountsReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<string> AccountCount { get; set; } = new Prop<string> { Value = "0" };
        public Data Data { get => Data.Instance; }

        public ObservableCollection<Student> accounts = new ObservableCollection<Student>();
        public Prop<Student> SelectedStudent { get; set; } = new Prop<Student> { Value = null };
        public Prop<string> SelectedTitle { get; set; } = new Prop<string> { Value = "Geen actieve selectie" };

        private FilterType FilterType { get; set; } = FilterType.Name;
        private string Filter { get; set; } = String.Empty;

        public WisaAccounts()
        {
            InitializeComponent();
            DataContext = this;
            CreateSelection();
            AccountList.ItemsSource = accounts;
        }

        private void CreateSelection()
        {
            accounts.Clear();
            var selectedFilter = Filter.Length == 0 ? FilterType.None : FilterType;
            foreach (var account in WisaApi.Students.All)
            {
                switch(selectedFilter)
                {
                    case FilterType.None: accounts.Add(account); break;
                    case FilterType.Name: if (account.Name.Contains(Filter)) accounts.Add(account); break;
                    case FilterType.FirstName: if (account.FirstName.Contains(Filter)) accounts.Add(account); break;
                    case FilterType.ClassGroup: if (account.ClassGroup.Contains(Filter)) accounts.Add(account); break;
                }
            }
            AccountCount.Value = accounts.Count.ToString();
        }

        private void FilterCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            var index = (sender as ComboBox).SelectedIndex;
            if (index == 0) FilterType = FilterType.Name;
            else if (index == 1) FilterType = FilterType.FirstName;
            else FilterType = FilterType.ClassGroup;
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

        private async void ReloadAccountsButton_Click(object sender, RoutedEventArgs e)
        {
            ShowAccountsReloadButtonIndicator.Value = true;
            Data.Instance.SetWisaCredentials();
            await Data.Instance.ReloadWisaStudents();
            CreateSelection();
            ShowAccountsReloadButtonIndicator.Value = false;
        }

        private void AccountList_SelectedCellsChanged(object sender, SelectedCellsChangedEventArgs e)
        {
            SelectedStudent.Value = (sender as DataGrid).SelectedItem as Student;
            if (SelectedStudent.Value != null)
            {
                SelectedTitle.Value = SelectedStudent.Value.FirstName + " " + SelectedStudent.Value.Name;
            }
            else
            {
                SelectedTitle.Value = "Geen actieve selectie";
            }
        }
    }
}

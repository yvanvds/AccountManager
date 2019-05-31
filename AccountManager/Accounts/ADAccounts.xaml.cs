using System;
using System.Collections.Generic;
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
    /// <summary>
    /// Interaction logic for ADAccounts.xaml
    /// </summary>
    public partial class ADAccounts : UserControl
    {
        public Prop<bool> ShowGroupsReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<string> AccountCount { get; set; } = new Prop<string> { Value = "0" };
        public Prop<DirectoryApi.Account> SelectedAccount { get; set; } = new Prop<DirectoryApi.Account> { Value = null };
        public Data Data { get => Data.Instance; }

        public ADAccounts()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
        }

        private void StudentButton_Click(object sender, RoutedEventArgs e)
        {

        }

        private void StaffButton_Click(object sender, RoutedEventArgs e)
        {

        }

        private async void ReloadAccountButton_Click(object sender, RoutedEventArgs e)
        {
            ShowGroupsReloadButtonIndicator.Value = true;
            Data.Instance.SetADCredentials();
            await Data.Instance.ReloadADAccounts();
            //BuildAccountTree();

            ShowGroupsReloadButtonIndicator.Value = false;
        }
    }
}

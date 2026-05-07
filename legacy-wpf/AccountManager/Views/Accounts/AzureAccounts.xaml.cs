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

namespace AccountManager.Views.Accounts
{
    /// <summary>
    /// Interaction logic for AzureAccounts.xaml
    /// </summary>
    public partial class AzureAccounts : UserControl
    {
        public Prop<string> AccountCount { get; set; } = new Prop<string> { Value = "0" };
        public State.App State { get => AccountManager.State.App.Instance; }

        public ObservableCollection<Microsoft.Graph.User> accounts = new ObservableCollection<Microsoft.Graph.User>();
        public Prop<AccountApi.Smartschool.Account> SelectedAccount { get; set; } = new Prop<AccountApi.Smartschool.Account> { Value = null };
        public Prop<string> SelectedTitle { get; set; } = new Prop<string> { Value = "Geen actieve selectie" };

        public AzureAccounts()
        {
            InitializeComponent();
            DataContext = new ViewModels.Accounts.AzureAccounts();
        }
    }
}

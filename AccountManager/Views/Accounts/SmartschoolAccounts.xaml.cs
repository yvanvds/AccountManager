using AccountApi;
using AccountManager.ViewModels.Accounts;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Views.Accounts
{
    /// <summary>
    /// Interaction logic for SmartschoolAccounts.xaml
    /// </summary>
    public partial class SmartschoolAccounts : UserControl
    {
        ViewModels.Accounts.SmartschoolAccounts model;

        public SmartschoolAccounts()
        {
            InitializeComponent();
            model = new ViewModels.Accounts.SmartschoolAccounts();
            DataContext = model;
        }



        private void SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
        {
            model.SelectedAccount = e.NewValue is TreeAccount ? (e.NewValue as TreeAccount) : null;
        }
    }


}
